param([string]$PythonPath = (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$modulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\StationDeployment.psm1'))
$module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
$testBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $testBase ('wt-station-module-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$passed = 0
$failed = 0
$skipped = 0
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++ }
    catch { $script:failed++; Write-Output ('FAIL: ' + $Name) }
    finally { & $module { $script:StationCopyOverride = $null; $script:StationVerifyOverride = $null } }
}
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Write-File([string]$Name, [string]$Content) {
    $path = Join-Path $testRoot $Name
    [IO.File]::WriteAllText($path, $Content, [Text.UTF8Encoding]::new($false))
    return $path
}
function Must-Fail([scriptblock]$Body) {
    $rejected = $false
    try { $null = & $Body } catch { $rejected = $true }
    Assert-True $rejected 'Operation unexpectedly succeeded.'
}
function Assert-NoResidue {
    Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Force -Filter '*.wt-*.tmp').Count -eq 0) 'Temporary residue remains.'
}
function Invoke-TestScript([string]$Executable,[string]$Script,[string[]]$Arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $all = @('-NoProfile','-NonInteractive','-File',$Script) + $Arguments
    $quoted = @($all | ForEach-Object { '"' + ($_ -replace '"','\"') + '"' })
    $psi.Arguments = $quoted -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Safe refusal/preview test timed out.' }
        if (-not $stdout.Wait(3000) -or -not $stderr.Wait(3000)) { throw 'Safe test output timed out.' }
        return [pscustomobject]@{ExitCode=$process.ExitCode;Output=$stdout.Result;Error=$stderr.Result}
    } finally { $process.Dispose() }
}
try {
    Test-Case 'wrong source hash preserves existing destination' {
        $source = Write-File 'wrong-source.bin' 'new'
        $destination = Write-File 'wrong-destination.bin' 'old'
        $old = Hash $destination
        Must-Fail { Install-StationFile -Source $source -Destination $destination -SHA256 ('0' * 64) }
        Assert-True ((Hash $destination) -eq $old) 'Existing destination changed.'
        Assert-NoResidue
    }
    Test-Case 'corrupted staging copy preserves destination' {
        $source = Write-File 'copy-source.bin' 'new'
        $destination = Write-File 'copy-destination.bin' 'old'
        $old = Hash $destination
        & $module { $script:StationCopyOverride = { param($Source,$TemporaryPath) [IO.File]::WriteAllText($TemporaryPath,'corrupt') } }
        Must-Fail { Install-StationFile -Source $source -Destination $destination -SHA256 (Hash $source) }
        Assert-True ((Hash $destination) -eq $old) 'Existing destination changed.'
        Assert-NoResidue
    }
    Test-Case 'partial copy exception introduces no new destination' {
        $source = Write-File 'partial-source.bin' 'complete'
        $destination = Join-Path $testRoot 'partial-destination.bin'
        & $module { $script:StationCopyOverride = { param($Source,$TemporaryPath) [IO.File]::WriteAllText($TemporaryPath,'partial'); throw 'Injected copy failure' } }
        Must-Fail { Install-StationFile -Source $source -Destination $destination -SHA256 (Hash $source) }
        Assert-True (-not [IO.File]::Exists($destination)) 'A partial destination appeared.'
        Assert-NoResidue
    }
    Test-Case 'successful replacement and same-file skip' {
        $source = Write-File 'success-source.bin' 'version2'
        $destination = Write-File 'success-destination.bin' 'version1'
        $hash = Hash $source
        $result = Install-StationFile -Source $source -Destination $destination -SHA256 $hash
        Assert-True ($result.Action -eq 'Installed' -and $result.ExistedBefore) 'Replacement record is wrong.'
        Assert-True ((Hash $destination) -eq $hash) 'Replacement content differs.'
        $again = Install-StationFile -Source $source -Destination $destination -SHA256 $hash
        Assert-True ($again.Action -eq 'Unchanged') 'Already matching file was replaced.'
        Assert-NoResidue
    }
    Test-Case 'post-replacement verification failure restores original file' {
        $source = Write-File 'post-source.bin' 'new-version'
        $destination = Write-File 'post-destination.bin' 'old-version'
        $old = Hash $destination; $new = Hash $source
        & $module {
            param($Target,$Expected)
            $script:FailureDestination = $Target
            $script:FailureHash = $Expected
            $script:StationVerifyOverride = {
                param($Path,$SHA256)
                if ($Path -eq $script:FailureDestination -and $SHA256 -eq $script:FailureHash) {
                    $script:StationVerifyOverride = $null
                    throw 'Injected post-replacement verification failure'
                }
            }
        } $destination $new
        Must-Fail { Install-StationFile -Source $source -Destination $destination -SHA256 $new }
        Assert-True ((Hash $destination) -eq $old) 'Original file was lost after verification failure.'
        Assert-NoResidue
    }
    Test-Case 'existing file restores original backup' {
        $backup = Write-File 'restore-backup.bin' 'original'
        $destination = Write-File 'restore-destination.bin' 'installed'
        $oldHash = Hash $backup; $installedHash = Hash $destination
        $result = Restore-StationFile -Backup $backup -Destination $destination -SHA256 $oldHash -Existed $true -InstalledSHA256 $installedHash
        Assert-True ($result.Action -eq 'Restored' -and (Hash $destination) -eq $oldHash) 'Backup restoration failed.'
        $again = Restore-StationFile -Backup $null -Destination $destination -SHA256 $oldHash -Existed $true
        Assert-True ($again.Action -eq 'Unchanged') 'Already restored file was not skipped.'
        Assert-NoResidue
    }
    Test-Case 'missing original destination restores backup' {
        $backup = Write-File 'missing-backup.bin' 'original'
        $destination = Join-Path $testRoot 'missing-destination.bin'
        $result = Restore-StationFile -Backup $backup -Destination $destination -SHA256 (Hash $backup) -Existed $true
        Assert-True ($result.Action -eq 'Restored' -and [IO.File]::Exists($destination)) 'Missing file was not restored.'
        Assert-NoResidue
    }
    Test-Case 'originally absent file removes only installed content' {
        $destination = Write-File 'absent-original.bin' 'owned-installed'
        $result = Restore-StationFile -Backup $null -Destination $destination -SHA256 $null -Existed $false -InstalledSHA256 (Hash $destination)
        Assert-True ($result.Action -eq 'Removed' -and -not [IO.File]::Exists($destination)) 'Owned file was not removed.'
        $again = Restore-StationFile -Backup $null -Destination $destination -SHA256 $null -Existed $false
        Assert-True ($again.Action -eq 'Absent') 'Already absent file was not skipped.'
    }
    Test-Case 'unknown file is never removed' {
        $destination = Write-File 'unknown.bin' 'unrelated-user-file'
        $old = Hash $destination
        Must-Fail { Restore-StationFile -Backup $null -Destination $destination -SHA256 $null -Existed $false -InstalledSHA256 ('0' * 64) }
        Assert-True ((Hash $destination) -eq $old) 'Unknown file changed.'
        Must-Fail { Restore-StationFile -Backup $null -Destination $destination -SHA256 $null -Existed $false }
        Assert-True ((Hash $destination) -eq $old) 'File without ownership hash changed.'
    }
    Test-Case 'relative path and directory targets are refused' {
        $source = Write-File 'path-source.bin' 'valid'
        Must-Fail { Install-StationFile -Source $source -Destination 'relative.bin' -SHA256 (Hash $source) }
        Must-Fail { Install-StationFile -Source $source -Destination 'C:drive-relative.bin' -SHA256 (Hash $source) }
        Must-Fail { Install-StationFile -Source $source -Destination $testRoot -SHA256 (Hash $source) }
    }
    Test-Case 'bad backup preserves installed destination' {
        $backup = Write-File 'bad-backup.bin' 'damaged'
        $destination = Write-File 'bad-restore.bin' 'installed'
        $installed = Hash $destination
        Must-Fail { Restore-StationFile -Backup $backup -Destination $destination -SHA256 ('0' * 64) -Existed $true -InstalledSHA256 $installed }
        Assert-True ((Hash $destination) -eq $installed) 'Bad backup changed destination.'
    }
    Test-Case 'unknown current file refuses existing-file restoration' {
        $backup = Write-File 'foreign-backup.bin' 'original'
        $destination = Write-File 'foreign-current.bin' 'user-changed'
        $unknown = Hash $destination
        Must-Fail { Restore-StationFile -Backup $backup -Destination $destination -SHA256 (Hash $backup) -Existed $true -InstalledSHA256 ('0' * 64) }
        Assert-True ((Hash $destination) -eq $unknown) 'Unknown current file changed.'
    }
    Test-Case 'unknown file captured during removal is restored and never deleted' {
        $destination = Write-File 'removal-race.bin' 'installed'
        $installed = Hash $destination
        & $module {
            $script:StationVerifyOverride = {
                param($Path,$SHA256)
                if ($Path -like '*.wt-remove.*.tmp') {
                    $script:StationVerifyOverride = $null
                    [IO.File]::WriteAllText($Path,'unexpected-current-content')
                }
            }
        }
        Must-Fail { Restore-StationFile -Backup $null -Destination $destination -SHA256 $null -Existed $false -InstalledSHA256 $installed }
        Assert-True ([IO.File]::Exists($destination)) 'Unexpected captured file was deleted.'
        Assert-True ([IO.File]::ReadAllText($destination) -eq 'unexpected-current-content') 'Unknown captured contents were not restored.'
        Assert-NoResidue
    }
    Test-Case 'locked destination fails in bounded time without changing it' {
        $source = Write-File 'locked-source.bin' 'new'
        $destination = Write-File 'locked-destination.bin' 'old'
        $hash = Hash $source
        $handle = [IO.File]::Open($destination,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        try { Must-Fail { Install-StationFile -Source $source -Destination $destination -SHA256 $hash } }
        finally { $handle.Dispose() }
        Assert-True ($timer.ElapsedMilliseconds -lt 5000) 'File lock retries were unbounded.'
        Assert-True ([IO.File]::ReadAllText($destination) -eq 'old') 'Locked file changed.'
        Assert-NoResidue
    }
    Test-Case 'introduced PDB is removed after a later component failure' {
        $appSource = Write-File 'bundle-new-app.bin' 'new-app'
        $appDestination = Write-File 'bundle-app.bin' 'old-app'
        $appBackup = Join-Path $testRoot 'bundle-app-backup.bin'
        [IO.File]::Copy($appDestination,$appBackup)
        $oldAppHash = Hash $appBackup
        $pdbSource = Write-File 'bundle-new-pdb.bin' 'new-symbols'
        $pdbDestination = Join-Path $testRoot 'bundle-introduced.pdb'
        $badSource = Write-File 'bundle-bad-source.bin' 'invalid-later-component'
        $null = Install-StationFile -Source $appSource -Destination $appDestination -SHA256 (Hash $appSource)
        $null = Install-StationFile -Source $pdbSource -Destination $pdbDestination -SHA256 (Hash $pdbSource)
        Must-Fail { Install-StationFile -Source $badSource -Destination (Join-Path $testRoot 'bundle-last.bin') -SHA256 ('0' * 64) }
        $null = Restore-StationFile -Backup $null -Destination $pdbDestination -SHA256 $null -Existed $false -InstalledSHA256 (Hash $pdbSource)
        $null = Restore-StationFile -Backup $appBackup -Destination $appDestination -SHA256 $oldAppHash -Existed $true -InstalledSHA256 (Hash $appSource)
        Assert-True ((Hash $appDestination) -eq $oldAppHash) 'Original app was not restored.'
        Assert-True (-not [IO.File]::Exists($pdbDestination)) 'Introduced PDB survived rollback.'
        Assert-NoResidue
    }
    Test-Case 'new script and module files parse without automatic HOME assignments' {
        $entry = Join-Path $PSScriptRoot '..\build-and-update.ps1'
        $scripts = @($modulePath,$entry,(Join-Path $PSScriptRoot '..\station-booth.ps1'),(Join-Path $PSScriptRoot '..\office\station-office.ps1'))
        foreach ($script in $scripts) {
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($script,[ref]$tokens,[ref]$errors)
            Assert-True ($errors.Count -eq 0) 'A new helper cannot be parsed.'
            $bad = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ieq 'HOME'},$true))
            Assert-True ($bad.Count -eq 0) 'A helper overwrites automatic HOME.'
        }
    }
    $pwsh = if ($PSVersionTable.PSVersion.Major -ge 7) { [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } else {
        $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($command) { $command.Source } elseif ([IO.File]::Exists('C:\wt\tools\pwsh7\pwsh.exe')) { 'C:\wt\tools\pwsh7\pwsh.exe' } else { $null }
    }
    if ($pwsh) {
        Test-Case 'WhatIf returns without work directories or tool requirements' {
            $entry = Join-Path $PSScriptRoot '..\build-and-update.ps1'
            $repository = Join-Path $testRoot 'preview-repository'
            $output = Join-Path $testRoot 'preview-output'
            New-Item -ItemType Directory -Path $repository | Out-Null
            $previewArguments = @('-Repository',$repository,'-WorkRoot',$output,'-QtRoot',(Join-Path $testRoot 'missing-qt'),'-GStreamerRoot',(Join-Path $testRoot 'missing-gst'),'-PkgConfig',(Join-Path $testRoot 'missing-pkg'),'-PythonPath',(Join-Path $testRoot 'missing-python'),'-WhatIf')
            $result = Invoke-TestScript $pwsh $entry $previewArguments
            Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'No changes made') 'Preview failed.'
            Assert-True (-not [IO.Directory]::Exists($output)) 'Preview created its work directory.'
        }
        Test-Case 'invalid target is refused before work or network' {
            $entry = Join-Path $PSScriptRoot '..\build-and-update.ps1'
            $output = Join-Path $testRoot 'invalid-target-output'
            $result = Invoke-TestScript $pwsh $entry @('-WorkRoot',$output,'-Targets','UnknownStation','-WhatIf')
            Assert-True ($result.ExitCode -ne 0) 'Invalid target was accepted.'
            Assert-True (-not [IO.Directory]::Exists($output)) 'Refused target created work directory.'
        }
        Test-Case 'invalid office address is refused before work or network' {
            $entry = Join-Path $PSScriptRoot '..\build-and-update.ps1'
            $output = Join-Path $testRoot 'invalid-address-output'
            $result = Invoke-TestScript $pwsh $entry @('-WorkRoot',$output,'-OfficeAddress','../unsafe','-WhatIf')
            Assert-True ($result.ExitCode -ne 0) 'Invalid address was accepted.'
            Assert-True (-not [IO.Directory]::Exists($output)) 'Refused address created work directory.'
        }
        Test-Case 'repository itself cannot be the work directory' {
            $entry = Join-Path $PSScriptRoot '..\build-and-update.ps1'
            $repository = Join-Path $testRoot 'equal-work-repository'
            New-Item -ItemType Directory -Path $repository | Out-Null
            # Wrong host and missing tools prevent reaching fetch even if this
            # directory-boundary refusal regresses. All writes stay disposable.
            $previewArguments = @('-Repository',$repository,'-WorkRoot',$repository,'-ExpectedBoothHost','INTENTIONALLY-WRONG-HOST','-QtRoot',(Join-Path $testRoot 'missing-qt'),'-GStreamerRoot',(Join-Path $testRoot 'missing-gst'),'-PkgConfig',(Join-Path $testRoot 'missing-pkg'),'-PythonPath',(Join-Path $testRoot 'missing-python'),'-BuildOnly')
            $result = Invoke-TestScript $pwsh $entry $previewArguments
            Assert-True ($result.ExitCode -ne 0) 'Repository work directory was accepted.'
            Assert-True (@(Get-ChildItem -LiteralPath $repository -Force).Count -eq 0) 'Refusal created run files inside repository.'
        }
        Test-Case 'booth completion does not wait for inherited descendant output pipes' {
            $fixture = Join-Path $testRoot 'inherited-pipe-fixture'
            New-Item -ItemType Directory -Path $fixture | Out-Null
            $python = $PythonPath
            Assert-True ([IO.File]::Exists($python)) 'Provisioned fixture Python is missing.'
            $parentFile = Join-Path $fixture 'parent.py'
            $parentSource = @'
import ctypes, json, os, pathlib, subprocess, sys, time
from ctypes import wintypes as W
root=pathlib.Path(sys.argv[1])
child_source="import pathlib,sys,time; p=pathlib.Path(sys.argv[1]); (p/'child-ready').write_text('ready'); end=time.monotonic()+6; exec(\"while time.monotonic()<end and not (p/'release').exists():\\n time.sleep(0.05)\")"
child=subprocess.Popen([sys.executable,'-B','-c',child_source,str(root)],close_fds=False)
class FT(ctypes.Structure): _fields_=[('low',W.DWORD),('high',W.DWORD)]
k=ctypes.WinDLL('kernel32',use_last_error=True)
k.GetProcessTimes.argtypes=[W.HANDLE]+[ctypes.POINTER(FT)]*4
k.GetProcessTimes.restype=W.BOOL
values=[FT() for _ in range(4)]
if not k.GetProcessTimes(int(child._handle),*[ctypes.byref(v) for v in values]): raise RuntimeError('owned fixture time unavailable')
record={'PID':child.pid,'FileTime':(values[0].high<<32)|values[0].low,'Path':sys.executable}
(root/'child.json').write_text(json.dumps(record),encoding='utf-8')
deadline=time.monotonic()+2
while not (root/'child-ready').exists() and time.monotonic()<deadline: time.sleep(0.02)
if not (root/'child-ready').exists(): raise RuntimeError('fixture child not ready')
print('owned fixture parent completed',flush=True)
'@
            [IO.File]::WriteAllText($parentFile,$parentSource,[Text.UTF8Encoding]::new($false))
            $checkFile = Join-Path $fixture 'check-native.ps1'
            $checkSource = @'
param([string]$Entry,[string]$Fixture,[string]$Python)
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Entry,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Entry syntax invalid'}
$definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Native'},$true)
if(-not $definition){throw 'Native helper not found'}
. ([scriptblock]::Create($definition.Extent.Text))
$run=$Fixture
$owned=$null
try {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $null=Native $Python @('-B',(Join-Path $Fixture 'parent.py'),$Fixture) 'booth-update' 4
    $elapsed=$timer.ElapsedMilliseconds
    $record=Get-Content -LiteralPath (Join-Path $Fixture 'child.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $owned=[Diagnostics.Process]::GetProcessById([int]$record.PID)
    if($owned.StartTime.ToUniversalTime().ToFileTimeUtc()-ne [long]$record.FileTime -or -not [string]::Equals($owned.MainModule.FileName,[string]$record.Path,[StringComparison]::OrdinalIgnoreCase)){throw 'Owned child identity mismatch'}
    if($elapsed-ge 2000){throw 'Native completion waited for descendant output'}
    if($owned.HasExited -or -not(Test-Path -LiteralPath (Join-Path $Fixture 'child-ready'))){throw 'Healthy fixture descendant was stopped'}
    [IO.File]::WriteAllText((Join-Path $Fixture 'result.json'),(@{Passed=$true;ElapsedMilliseconds=$elapsed;ChildAlive=$true}|ConvertTo-Json))
} finally {
    [IO.File]::WriteAllText((Join-Path $Fixture 'release'),'done')
    if(-not $owned -and (Test-Path -LiteralPath (Join-Path $Fixture 'child.json'))){
        $record=Get-Content -LiteralPath (Join-Path $Fixture 'child.json') -Raw -Encoding UTF8|ConvertFrom-Json
        try{
            $candidate=[Diagnostics.Process]::GetProcessById([int]$record.PID)
            if($candidate.StartTime.ToUniversalTime().ToFileTimeUtc()-eq [long]$record.FileTime -and [string]::Equals($candidate.MainModule.FileName,[string]$record.Path,[StringComparison]::OrdinalIgnoreCase)){$owned=$candidate}else{$candidate.Dispose()}
        }catch{}
    }
    if($owned){if(-not $owned.WaitForExit(1000)){$owned.Kill();$null=$owned.WaitForExit(1000)};$owned.Dispose()}
}
'@
            [IO.File]::WriteAllText($checkFile,$checkSource,[Text.UTF8Encoding]::new($false))
            $entry = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\build-and-update.ps1'))
            $result = Invoke-TestScript $pwsh $checkFile @('-Entry',$entry,'-Fixture',$fixture,'-Python',$python)
            Assert-True ($result.ExitCode -eq 0) 'Owned pipe fixture regression failed.'
            $record = Get-Content -LiteralPath (Join-Path $fixture 'result.json') -Raw | ConvertFrom-Json
            Assert-True ($record.Passed -and $record.ChildAlive -and $record.ElapsedMilliseconds -lt 2000) 'Completion waited for pipe EOF or killed descendant.'
        }
    } else { $skipped += 5 }
    Test-Case 'booth helper refuses incomplete manifest before preparation' {
        $script = Join-Path $PSScriptRoot '..\station-booth.ps1'
        $manifest = Write-File 'refused-manifest.json' '{}'
        $resultPath = Join-Path $testRoot 'refused-booth-result.json'
        $backupPath = Join-Path $testRoot 'refused-booth-backup'
        $result = Invoke-TestScript (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') $script @('-ManifestPath',$manifest,'-RuntimePath',(Join-Path $testRoot 'absent-runtime.json'),'-BackupPath',$backupPath,'-ResultPath',$resultPath)
        Assert-True ($result.ExitCode -eq 4 -and $result.Output -match 'refused before preparation') 'Incomplete manifest was not safely refused.'
        Assert-True (-not [IO.Directory]::Exists($backupPath) -and -not [IO.File]::Exists($resultPath)) 'Early refusal wrote preparation files.'
    }
    Test-Case 'office helper refuses invalid mode during parameter binding' {
        $script = Join-Path $PSScriptRoot '..\office\station-office.ps1'
        $output = Join-Path $testRoot 'refused-office-result.json'
        $result = Invoke-TestScript (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') $script @('-Mode','UnknownMode','-ExpectedHost','INTENTIONALLY-WRONG-HOST','-ResultPath',$output)
        Assert-True ($result.ExitCode -ne 0 -and -not [IO.File]::Exists($output)) 'Invalid Office mode was not refused.'
    }
    Test-Case 'office helper refuses wrong host before inspection or preparation' {
        $script = Join-Path $PSScriptRoot '..\office\station-office.ps1'
        $output = Join-Path $testRoot 'wrong-host-office-result.json'
        $work = Join-Path $testRoot 'wrong-host-office-work'
        $result = Invoke-TestScript (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') $script @('-Mode','Inspect','-ExpectedHost','INTENTIONALLY-WRONG-HOST','-ResultPath',$output,'-WorkRoot',$work)
        Assert-True ($result.ExitCode -eq 4) 'Wrong Office host was not refused.'
        Assert-True (-not [IO.Directory]::Exists($work)) 'Wrong-host refusal created work directories.'
    }
} finally {
    & $module { $script:StationCopyOverride = $null; $script:StationVerifyOverride = $null }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $prefix = $testBase.TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '\Awt-station-module-test-[0-9a-f]{32}\z') {
        throw 'Disposable test cleanup target is unsafe.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output ('Deployment tests: ' + $passed + ' passed, ' + $failed + ' failed, ' + $skipped + ' skipped.')
if ($failed) { exit 1 }
