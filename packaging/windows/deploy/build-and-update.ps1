#requires -Version 7.2
<# Build one pinned source revision and update the two existing Windows stations.
   Requires the provisioned booth toolchain; never installs SDKs or changes policy. #>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
param(
    [string]$Repository = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path,
    [string]$SourceRef = 'origin/main',
    [string]$WorkRoot = 'C:\wt\station-updates',
    [ValidateSet('Booth','Office')][string[]]$Targets = @('Booth','Office'),
    [switch]$BuildOnly,
    [string]$ExpectedBoothHost = 'WT-SM-VNUTRI-01',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]*$')][string]$OfficeAddress = '192.168.1.5',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]*$')][string]$ExpectedOfficeHost = 'WT-OFFICE-01',
    [PSCredential]$OfficeCredential,
    [string]$QtRoot = 'C:\wt\Qt\6.12.0\msvc2022_64',
    [string]$GStreamerRoot = 'C:\wt\gst\PFiles64\gstreamer\1.0\msvc_x86_64',
    [string]$PkgConfig = 'C:\wt\shim\pkg-config.cmd',
    [string]$PythonPath = (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
    [string]$WatchdogTask = 'wt-warden-guard',
    [string]$WatchdogPath = 'C:\wt\wall-watchdog.ps1',
    [string]$OfficeWardenTask = 'wt-warden',
    [string]$BoothFlightRecorderPath = '',
    [string]$OfficeFlightRecorderPath = '',
    [ValidateRange(1,4)][int]$BuildJobs = 4,
    [ValidateRange(120,3600)][int]$JobTimeoutSeconds = 1200,
    [ValidateSet('Yes','No')][string]$UpdateSource='Yes',
    [ValidateSet('Ask','Yes','No')][string]$Rebuild='Ask'
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run this script on the Windows Security Booth.' }
if ($WhatIfPreference) {
    Write-Output 'Would fetch and pin source, build, test startup, back up and update the selected stations. No changes made.'
    return
}
if (-not $PSCmdlet.ShouldProcess(($Targets -join ', '),'Build, verify and update existing Watchtower installations')) { return }
Import-Module (Join-Path $PSScriptRoot 'StationDeployment.psm1') -Force
$runId = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
$Repository = [IO.Path]::GetFullPath($Repository)
if ($WorkRoot.TrimEnd('\').Equals($Repository.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase) -or $WorkRoot.StartsWith($Repository.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'WorkRoot must be outside the repository.' }
$run = Join-Path $WorkRoot $runId
New-Item -ItemType Directory -Path $run | Out-Null
$summary = [ordered]@{RunId=$runId;StartedUTC=[DateTime]::UtcNow.ToString('o');Status='Preparing';SourceRef=$SourceRef;Commit=$null;AppVersion=$null;WardenVersion=$null;Booth=$null;Office=$null;RunDirectory=$run;Error=$null}
$entryLock=$null
$source = Join-Path $run 'source'
$officeShare = '\\'+$OfficeAddress+'\C$'
$officeLocal = 'C:\Users\Public\Downloads\WatchtowerDeploy\'+$runId
$officeRemote = Join-Path $officeShare ('Users\Public\Downloads\WatchtowerDeploy\'+$runId)

function Save-Json($Object,[string]$Path) {
    [IO.File]::WriteAllText($Path,($Object|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}
function Read-Json([string]$Path) {
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    do {
        try {
            $raw=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){return ($raw|ConvertFrom-Json -DateKind String)}
            return ($raw|ConvertFrom-Json)
        } catch { if([DateTime]::UtcNow-ge $deadline){throw};Start-Sleep -Milliseconds 100 }
    } while($true)
}
function File-Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Need([string]$Path) { if (-not (Test-Path -LiteralPath $Path)) { throw ('Required file or directory is missing: '+$Path) } }
function Native([string]$File,[string[]]$Arguments,[string]$Label,[int]$Timeout=1800,[int[]]$AllowedExitCodes=@(0)) {
    $resolved = (Get-Command $File -ErrorAction Stop).Source
    $psi = [Diagnostics.ProcessStartInfo]::new($resolved)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = (Get-Location).Path
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    # Warden and the watchdog remain alive after their updater exits. They can
    # inherit its output handles, so EOF is not an update-completion signal.
    # The deployment helper's bounded exit and verified JSON result are used.
    $captureOutput=$Label -ne 'booth-update'
    $psi.RedirectStandardOutput=$captureOutput; $psi.RedirectStandardError=$captureOutput
    $p=[Diagnostics.Process]::new(); $p.StartInfo=$psi
    try {
        $null=$p.Start()
        if($captureOutput){$out=$p.StandardOutput.ReadToEndAsync(); $err=$p.StandardError.ReadToEndAsync()}
        $deadline=[DateTime]::UtcNow.AddSeconds($Timeout)
        while (-not $p.WaitForExit(1000)) {
            if ([DateTime]::UtcNow -ge $deadline) {
                if($Label -eq 'booth-update'){throw 'Booth update completion is unknown; recovery was left running. Inspect the station result before retrying.'}
                $p.Kill($true); throw ($Label+' timed out; its owned process tree was stopped.')
            }
        }
        if ($captureOutput -and (-not $out.Wait(10000) -or -not $err.Wait(10000))) { throw ($Label+' output timed out.') }
        # These tools receive no credentials. Product-probe output is handled separately.
        if($captureOutput){[IO.File]::WriteAllText((Join-Path $run ($Label+'.log')),($out.Result+"`n"+$err.Result),[Text.UTF8Encoding]::new($false))}
        if ($p.ExitCode -notin $AllowedExitCodes) { throw ($Label+' failed (exit '+$p.ExitCode+'). See the retained run log.') }
        if($captureOutput){return $out.Result.Trim()}
    } finally { $p.Dispose() }
}
function Safe-Quote([string]$Value) { return '"'+(($Value -replace '(\\*)"','$1$1\"') -replace '(\\+)$','$1$1')+'"' }
function Office-Connect {
    if (Test-Path -LiteralPath $officeShare) { return }
    if (-not $OfficeCredential) { throw 'Office administrator access is unavailable. Establish C$ access or pass -OfficeCredential (Get-Credential).' }
    if (-not ('WatchtowerNetwork' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class WatchtowerNetwork {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct RESOURCE { public uint scope,type,displayType,usage; public string local,remote,comment,provider; }
 [DllImport("mpr.dll",CharSet=CharSet.Unicode)] public static extern uint WNetAddConnection2(ref RESOURCE r,string password,string user,uint flags);
}
'@
    }
    $resource=[WatchtowerNetwork+RESOURCE]::new(); $resource.type=1; $resource.remote=$officeShare
    $secret=$OfficeCredential.GetNetworkCredential().Password
    try { $code=[WatchtowerNetwork]::WNetAddConnection2([ref]$resource,$secret,$OfficeCredential.UserName,4) }
    finally { $secret=$null }
    if ($code -ne 0) { throw ('Office authentication failed (Windows code '+$code+'). Existing connections were not disconnected.') }
}
function Office-Job([string]$Mode,[string]$ManifestLocal='') {
    $label=$Mode.ToLowerInvariant()
    $resultOffice=$officeLocal+'\'+$label+'-result.json'
    $resultShare=Join-Path $officeRemote ($label+'-result.json')
    if (Test-Path -LiteralPath $resultShare) { throw 'A result already exists. Inspect the prior run before retrying.' }
    # The helper creates its own unique job directory. Do not duplicate the run
    # ID in runtime paths: Windows PowerShell hardlinks have a 260-character cap.
    $parameters=' -Mode '+$Mode+' -ExpectedHost '+(Safe-Quote $ExpectedOfficeHost)+' -TaskName '+(Safe-Quote $OfficeWardenTask)+' -ResultPath '+(Safe-Quote $resultOffice)+' -WorkRoot '+(Safe-Quote 'C:\ProgramData\CilexWatchtower\CodexDeploy')
    if ($ManifestLocal) { $parameters+=' -ManifestPath '+(Safe-Quote $ManifestLocal) }
    $command='@echo off'+"`r`n"+'start "" /b C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '+(Safe-Quote ($officeLocal+'\tools\office\station-office.ps1'))+$parameters+' > '+(Safe-Quote ($officeLocal+'\'+$label+'.log'))+' 2>&1'+"`r`nexit /b 0`r`n"
    [IO.File]::WriteAllText((Join-Path $officeRemote ($label+'.cmd')),$command,[Text.Encoding]::ASCII)
    $service='wt-deploy-'+$runId+'-'+$label
    $created=$false; $dispatched=$false; $cleanupFailed=$false; $dispatchAt=[DateTime]::UtcNow
    try {
        $null=& sc.exe ('\\'+$OfficeAddress) create $service binPath= ('C:\Windows\System32\cmd.exe /c '+(Safe-Quote ($officeLocal+'\'+$label+'.cmd'))) start= demand 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Office job registration failed. Check the established administrator connection.' }
        $created=$true
        $null=& sc.exe ('\\'+$OfficeAddress) start $service 2>&1
        if ($LASTEXITCODE -notin @(0,1053,1067)) { throw 'Office job submission failed. Inspect this run before retrying.' }
        $dispatched=$true
    } finally {
        if ($created) { $null=& sc.exe ('\\'+$OfficeAddress) delete $service 2>&1; $cleanupFailed=($LASTEXITCODE -ne 0) }
    }
    $deadline=[DateTime]::UtcNow.AddSeconds($JobTimeoutSeconds)
    while (-not (Test-Path -LiteralPath $resultShare)) {
        if ([DateTime]::UtcNow -ge $deadline) { throw ('Office job completion is unknown. Do not retry or restore files blindly. Inspect '+$officeLocal+'; service '+$service+'.') }
        Start-Sleep -Seconds 2
    }
    $r=Read-Json $resultShare
    Copy-Item -LiteralPath $resultShare -Destination (Join-Path $run ('office-'+$label+'-result.json'))
    if ($r.host -ne $ExpectedOfficeHost -or ([DateTimeOffset]::Parse($r.startedAt)).UtcDateTime -lt $dispatchAt.AddSeconds(-10) -or $r.mode -ne $Mode) { throw 'Office result does not match the dispatched job.' }
    if ($cleanupFailed) { throw ('Office result received, but temporary service cleanup failed: '+$service+'. Do not blindly retry.') }
    if ($r.exitCode -ne 0 -or $r.outcome -notin @('inspected','success','admitted')) { throw ('Office '+$r.outcome+': '+$r.reason+'. Original state/recovery information is retained.') }
    return $r
}
function Process-Record($p,[string]$Role,[string]$ScriptPath='') {
    $sid=Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid
    if ($sid.ReturnValue -ne 0) { throw 'A station process owner cannot be verified.' }
    return [pscustomobject]@{Role=$Role;PID=[int]$p.ProcessId;ParentPID=[int]$p.ParentProcessId;Name=$p.Name;Path=$p.ExecutablePath;ScriptPath=$ScriptPath;OwnerSID=$sid.Sid;Session=[int]$p.SessionId;CreatedUTC=$p.CreationDate.ToUniversalTime().ToString('o');Priority=[string](Get-Process -Id $p.ProcessId).PriorityClass}
}
function Booth-Snapshot {
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $session=(Get-Process -Id $PID).SessionId
    $walls=@(Get-CimInstance Win32_Process -Filter "Name='watchtower.exe'"|Where-Object SessionId -eq $session)
    if ($walls.Count -ne 1) { throw 'Expected one camera wall in the current booth session.' }
    $wall=$walls[0]; $parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$wall.ParentProcessId)
    if ($parent.Name -notin @('python.exe','pythonw.exe')) { throw 'This booth adapter requires the existing Python Warden.' }
    $install=Split-Path -Path $wall.ExecutablePath -Parent
    $warden=Join-Path $install 'warden\warden.py'; $fallback=Join-Path $install 'warden\warden.exe'
    if (-not ([string]$parent.CommandLine).Contains($warden)) { throw 'The wall parent is not its installed Warden.' }
    $dog=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object { $_.SessionId -eq $session -and ([string]$_.CommandLine).Contains($WatchdogPath) })
    if ($dog.Count -ne 1) { throw 'Expected one existing booth watchdog.' }
    $task=Get-ScheduledTask -TaskName $WatchdogTask -TaskPath '\'
    $actions=@($task.Actions)
    if ($actions.Count -ne 1 -or ([string]$actions[0].Arguments) -notmatch ('(?i)-File\s+"?'+[regex]::Escape($WatchdogPath)+'"?(?:\s|$)') -or ([string]$actions[0].Arguments) -match '(?i)token|password|credential|secret|bearer') { throw 'Unsupported watchdog action; it will not be copied into a record.' }
    $hold=Join-Path $env:LOCALAPPDATA 'watchtower-labs\control.json'; Need $hold
    $all=@(Get-CimInstance Win32_Process)
    $workers=@($all|Where-Object { $_.Name -like 'python*' -and $_.CommandLine -match '(?i)run_worker\.py.*--loop' })
    $guards=@($all|Where-Object { $_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -match '(?i)-File\s+.*guard[23]\.ps1' })
    $labsTasks=@(Get-ScheduledTask|Where-Object { $_.TaskName -match '(?i)labs' -or @($_.Actions|Where-Object { ($_.Execute+' '+$_.Arguments) -match '(?i)guard[23]\.ps1|run_worker\.py|start-labs' }).Count -gt 0 })
    if ($workers.Count -or $guards.Count -or $labsTasks.Count) { throw 'Booth Labs must be stopped with no Labs startup task before this adapter is used.' }
    $records=@((Process-Record $wall 'Watchtower'),(Process-Record $parent 'WardenPython' $warden),(Process-Record $dog[0] 'WallWatchdog' $WatchdogPath))
    if (@($records|Where-Object { $_.OwnerSID -ne $sid -or $_.Session -ne $session }).Count) { throw 'Booth process owners or sessions do not match the current guard.' }
    return [pscustomobject]@{CapturedUTC=[DateTime]::UtcNow.ToString('o');Host=$env:COMPUTERNAME;IdentitySID=$sid;Session=$session;Processes=$records;Tasks=@([pscustomobject]@{Name='\'+$WatchdogTask;ObservedEnabled=[bool]$task.Settings.Enabled;Actions=@($actions|Select-Object Execute,Arguments,WorkingDirectory)});Installed=[pscustomobject]@{WatchtowerPath=$wall.ExecutablePath;WatchtowerSHA256=(File-Hash $wall.ExecutablePath);WardenPythonPath=$warden;WardenSourceSHA256=(File-Hash $warden);WardenPackagedPath=$fallback;WardenPackagedSHA256=(File-Hash $fallback);WatchdogPath=$WatchdogPath;WatchdogSHA256=(File-Hash $WatchdogPath)};Labs=[pscustomobject]@{GuardCount=0;WorkerCount=0;TaskCount=0;ControlPath=$hold;ControlSHA256=(File-Hash $hold)}}
}
function Prepare-Runtime([string]$Install,[string]$Destination,[string]$Exe,[string]$Pdb) {
    New-Item -ItemType Directory -Path $Destination | Out-Null
    foreach ($f in Get-ChildItem -LiteralPath $Install -Recurse -File) {
        if ($f.Name -in @('watchtower.exe','watchtower.pdb','qoffscreen.dll') -or $f.Extension -in @('.bak','.lock') -or $f.FullName.StartsWith((Join-Path $Install 'warden')+'\',[StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative=$f.FullName.Substring($Install.Length).TrimStart('\'); $dst=Join-Path $Destination $relative
        New-Item -ItemType Directory -Path (Split-Path $dst) -Force|Out-Null
        New-Item -ItemType HardLink -Path $dst -Target $f.FullName|Out-Null
    }
    New-Item -ItemType Directory -Path (Join-Path $Destination 'platforms') -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $QtRoot 'plugins\platforms\qoffscreen.dll') -Destination (Join-Path $Destination 'platforms\qoffscreen.dll') -Force
    Copy-Item -LiteralPath $Exe -Destination (Join-Path $Destination 'watchtower.exe')
    Copy-Item -LiteralPath $Pdb -Destination (Join-Path $Destination 'watchtower.pdb')
}
function Status-Probe([string]$Exe,[string[]]$Arguments,[string]$Version) {
    $probeHome=Join-Path $run ('status-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $probeHome|Out-Null
    $psi=[Diagnostics.ProcessStartInfo]::new($Exe);foreach($a in $Arguments){$psi.ArgumentList.Add($a)}
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($key in @($psi.Environment.Keys)){if($key -match '(?i)^WT_|TOKEN|PASSWORD|SECRET|CREDENTIAL|AUTHORIZATION|BEARER|API.?KEY'){$psi.Environment.Remove($key)|Out-Null}}
    foreach($key in @('USERPROFILE','HOME','APPDATA','LOCALAPPDATA')){$psi.Environment[$key]=$probeHome}
    $psi.Environment['WT_WARDEN_WARDEN_DIR']=$probeHome;$psi.Environment['WT_WARDEN_DATA_DIR']=$probeHome;$psi.Environment['WT_WARDEN_BACKEND_URL']='';$psi.Environment['PYTHONIOENCODING']='utf-8';$psi.Environment['PYTHONUTF8']='1'
    $p=[Diagnostics.Process]::new();$p.StartInfo=$psi
    try{$null=$p.Start();$o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync();if(-not $p.WaitForExit(45000)){$p.Kill($true);throw 'Warden status check timed out.'};if(-not $o.Wait(5000)-or -not $e.Wait(5000)){throw 'Warden status output timed out.'};if($p.ExitCode-ne 0-or $o.Result-notmatch ('(?m)^warden '+[regex]::Escape($Version)+'\s')){throw 'Staged Warden failed its status/version check.'};return $true}finally{$p.Dispose()}
}

try {
    [Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'
    if($env:COMPUTERNAME -ne $ExpectedBoothHost){throw 'This is not the expected build/booth host.'}
    foreach($p in @($Repository,$QtRoot,$GStreamerRoot,$PkgConfig,$PythonPath)){Need $p}
    $install=Join-Path $env:LOCALAPPDATA 'Programs\Cilex Watchtower';Need $install
    $lockRoot=Join-Path $env:LOCALAPPDATA 'watchtower-station\deployment'
    New-Item -ItemType Directory -Path $lockRoot -Force|Out-Null
    try{$entryLock=[IO.File]::Open((Join-Path $lockRoot 'build-and-update.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'Another station build/update is running. Inspect that run before retrying.'}
    $testFile=Join-Path $PSScriptRoot 'tests\test-station-deployment.ps1';Need $testFile
    $null=Native (Get-Command pwsh.exe).Source @('-NoProfile','-NonInteractive','-File',$testFile,'-PythonPath',$PythonPath) 'transaction-tests'
    $null=Native (Get-Command pwsh.exe).Source @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'tests\test-video-health.ps1')) 'video-health-tests'
    $monitorTests=Join-Path $PSScriptRoot 'tests\test-startup-monitor.py';Need $monitorTests
    $null=Native $PythonPath @('-B',$monitorTests) 'startup-monitor-tests'
    $env:PATH=(Join-Path $QtRoot 'bin')+';C:\wt\tools\cmake\bin;C:\wt\tools\bin;'+(Split-Path $PythonPath)+';'+$env:PATH
    $env:QT_ROOT_DIR=$QtRoot;$env:GSTREAMER_ROOT=$GStreamerRoot;$env:PKG_CONFIG_PATH=Join-Path $GStreamerRoot 'lib\pkgconfig'
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe';Need $vswhere
    $vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if($LASTEXITCODE-ne 0-or -not $vs){throw 'MSVC build tools are unavailable.'}
    $vcvars=Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat';Need $vcvars
    $environment=& $env:ComSpec /d /c ('"'+$vcvars+'" >nul 2>&1 && set')
    if($LASTEXITCODE-ne 0){throw 'MSVC environment setup failed.'}
    foreach($line in $environment){if($line-match '^([^=]+)=(.*)$'){[Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process')}};$environment=$null
    Import-Module (Join-Path $PSScriptRoot '../BuildState.psm1')
    $buildPlan=Start-CilexBuild -Repository $Repository -BuildProfile 'windows-station' -Revision $SourceRef -Update $UpdateSource -Rebuild $Rebuild -Python $PythonPath -Snapshot No -Settings @{QtRoot=$QtRoot;GStreamerRoot=$GStreamerRoot;Configuration='RelWithDebInfo'}
    $commit=$buildPlan.commit;$summary.Commit=$commit
    $null=Native git @('-C',$Repository,'worktree','add','--detach',$source,$commit) 'source-worktree'
    if(Native git @('-C',$source,'status','--porcelain') 'source-clean'){throw 'Build source is not clean.'}
    $startupSource=Get-Content -LiteralPath (Join-Path $source 'src\main.cpp') -Raw -Encoding UTF8
    $hookOffset=$startupSource.IndexOf('const QString testSettingsDir = qEnvironmentVariable("WT_SETTINGS_DIR")')
    $authOffset=$startupSource.IndexOf('auth->restoreSession()')
    if($hookOffset-lt 0 -or $authOffset-lt $hookOffset -or -not $startupSource.Contains('QSettings::setDefaultFormat(QSettings::IniFormat)') -or -not $startupSource.Contains('/.startup-settings.json')){throw 'Selected source lacks private startup settings. Use a source revision with the verified startup test hook; older apps will not be probed.'}
    $version=[regex]::Match((Get-Content -LiteralPath (Join-Path $source 'CMakeLists.txt') -Raw),'VERSION\s+(\d+\.\d+\.\d+)').Groups[1].Value
    $wardenVersion=[regex]::Match((Get-Content -LiteralPath (Join-Path $source 'warden\warden.py') -Raw),'(?m)^WARDEN_VERSION\s*=\s*"([^"]+)"').Groups[1].Value
    if(-not $version-or -not $wardenVersion){throw 'Source version is missing.'};$summary.AppVersion=$version;$summary.WardenVersion=$wardenVersion
    Write-Output ('Selected Watchtower version '+$version+' (committed source).')
    if($buildPlan.build){
    Push-Location $source
    try{$null=Native cmake @('--preset','windows',('-DPKG_CONFIG_EXECUTABLE='+$PkgConfig.Replace('\','/'))) 'configure';$null=Native cmake @('--build','build-windows','--parallel',[string]$BuildJobs) 'build'}finally{Pop-Location}
    $exe=Join-Path $source 'build-windows\watchtower.exe';$pdb=Join-Path $source 'build-windows\watchtower.pdb';Need $exe;Need $pdb
    if((Get-Item -LiteralPath $exe).VersionInfo.FileVersion-ne ($version+'.0')){throw 'Built version differs from pinned source.'}
    $wardenSource=Join-Path $source 'warden\warden.py';$candidate=Join-Path $install 'warden\warden.exe'
    $proof=Native $PythonPath @('-B',(Join-Path $PSScriptRoot 'verify-warden.py'),'--exe',$candidate,'--source',$wardenSource) 'warden-match' -AllowedExitCodes @(0,1,2)|ConvertFrom-Json
    if(-not $proof.matches){
        Push-Location $source
        try{$null=Native $PythonPath @('-m','PyInstaller','--onefile','--noconfirm','--clean','--log-level','WARN','--name','warden','--distpath',(Join-Path $run 'warden'),'--workpath',(Join-Path $run 'pyi'),'--specpath',(Join-Path $run 'pyi'),$wardenSource) 'build-warden'}finally{Pop-Location}
        $candidate=Join-Path $run 'warden\warden.exe'
        $proof=Native $PythonPath @('-B',(Join-Path $PSScriptRoot 'verify-warden.py'),'--exe',$candidate,'--source',$wardenSource) 'warden-built-match'|ConvertFrom-Json
        if(-not $proof.matches){throw 'Built Warden does not match pinned source.'}
    }
    }else{
        $exe=$buildPlan.existing.metadata.exe;$pdb=$buildPlan.existing.metadata.pdb
        $candidate=$buildPlan.existing.metadata.warden
        $wardenSource=Join-Path $source 'warden\warden.py'
        $proof=Native $PythonPath @('-B',(Join-Path $PSScriptRoot 'verify-warden.py'),'--exe',$candidate,'--source',$wardenSource) 'warden-cached-match'|ConvertFrom-Json
        if(-not $proof.matches){throw 'Cached Warden does not match committed source.'}
    }
    $compiledCommit=if($buildPlan.build){$commit}else{$buildPlan.existing.commit}
    # Import comparisons refuse a runtime-library upgrade this app-only transaction cannot cover.
    $importScript=Join-Path $run 'check-imports.py'
    $python=@'
import json, pathlib, sys, pefile
def names(p):
    with pefile.PE(str(p)) as pe: return sorted(x.dll.decode('ascii') for x in pe.DIRECTORY_ENTRY_IMPORT)
new, installed=map(pathlib.Path,sys.argv[1:3]); added=sorted(set(names(new))-set(names(installed)))
print(json.dumps({'added':added}));sys.exit(bool(added))
'@
    [IO.File]::WriteAllText($importScript,$python,[Text.Encoding]::ASCII)
    $null=Native $PythonPath @('-B',$importScript,$exe,(Join-Path $install 'watchtower.exe')) 'booth-imports'
    $obstruction=Join-Path $source 'tools\tests\camera-obstruction'
    if(Test-Path -LiteralPath (Join-Path $obstruction 'CMakeLists.txt')){
        $testBuild=Join-Path $run 'obstruction-tests'
        $null=Native cmake @('-S',$obstruction,'-B',$testBuild,'-G','Ninja',('-DCMAKE_PREFIX_PATH='+$QtRoot),'-DCMAKE_BUILD_TYPE=Release') 'obstruction-configure'
        $null=Native cmake @('--build',$testBuild,'--parallel','2') 'obstruction-build'
        $null=Native (Join-Path $testBuild 'camera-obstruction-test.exe') @('-o',((Join-Path $run 'obstruction-contract-results.txt')+',txt')) 'obstruction-contract'
        $qmlImport=Join-Path $run 'qml-import\Watchtower';New-Item -ItemType Directory -Path $qmlImport -Force|Out-Null
        foreach($f in @('Theme.qml','Icon.qml','CameraObstructionButton.qml','CameraObstructionAlert.qml','CameraObstructionReview.qml')){Copy-Item -LiteralPath (Join-Path $source ('qml\'+$f)) -Destination (Join-Path $qmlImport $f)}
        $qmldir="module Watchtower`nsingleton Theme 1.0 Theme.qml`nIcon 1.0 Icon.qml`nCameraObstructionButton 1.0 CameraObstructionButton.qml`nCameraObstructionAlert 1.0 CameraObstructionAlert.qml`nCameraObstructionReview 1.0 CameraObstructionReview.qml`n"
        [IO.File]::WriteAllText((Join-Path $qmlImport 'qmldir'),$qmldir,[Text.Encoding]::ASCII)
        # Keep all assertions; only Linux's hardcoded screenshot output directory changes.
        $qmlTest=Join-Path $run 'obstruction-ui.qml'
        $screenshotRoot=Join-Path $run 'test-screenshots';New-Item -ItemType Directory -Path $screenshotRoot|Out-Null
        $qmlText=Get-Content -LiteralPath (Join-Path $obstruction 'tst_ui.qml') -Raw -Encoding UTF8
        $qmlText=[regex]::Replace($qmlText,'"(/tmp/[^"\r\n]+)"',{param($m) ConvertTo-Json ((Join-Path $screenshotRoot ([IO.Path]::GetFileName($m.Groups[1].Value))).Replace('\','/')) -Compress})
        [IO.File]::WriteAllText($qmlTest,$qmlText,[Text.UTF8Encoding]::new($false))
        $testEnvNames=@('QT_QPA_PLATFORM','QT_QUICK_BACKEND','QT_QUICK_CONTROLS_STYLE','QT_PLUGIN_PATH','QML2_IMPORT_PATH','QT_ASSUME_STDERR_HAS_CONSOLE','QT_FORCE_STDERR_LOGGING')
        $testEnvBefore=@{};foreach($name in $testEnvNames){$testEnvBefore[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
        $env:QT_QPA_PLATFORM='offscreen';$env:QT_QUICK_BACKEND='software';$env:QT_QUICK_CONTROLS_STYLE='Fusion';$env:QT_PLUGIN_PATH=Join-Path $QtRoot 'plugins';$env:QML2_IMPORT_PATH=Join-Path $QtRoot 'qml';$env:QT_ASSUME_STDERR_HAS_CONSOLE='1';$env:QT_FORCE_STDERR_LOGGING='1'
        try{$null=Native (Join-Path $QtRoot 'bin\qmltestrunner.exe') @('-input',$qmlTest,'-import',(Split-Path $qmlImport),'-o',((Join-Path $run 'obstruction-ui-results.txt')+',txt')) 'obstruction-ui'}finally{foreach($name in $testEnvNames){[Environment]::SetEnvironmentVariable($name,$testEnvBefore[$name],'Process')}}
    }
    $runtime=Join-Path $run 'preflight-runtime';Prepare-Runtime $install $runtime $exe $pdb
    $monitorPath=Join-Path $PSScriptRoot 'isolated-startup.py';Need $monitorPath
    $probeHome=Join-Path $run 'startup-home'
    $probeResult=Join-Path $run 'startup-result.json'
    $null=Native $PythonPath @('-B',$monitorPath,'--exe',(Join-Path $runtime 'watchtower.exe'),'--home',$probeHome,'--flightrec',(Join-Path $run 'preflight-flightrec'),'--result',$probeResult,'--seconds','40','--symbols',$runtime) 'isolated-startup' 90
    $startup=Read-Json $probeResult
    if(-not $startup.Passed -or -not $startup.NativeSettingsIsolated -or $startup.SHA256 -ne (File-Hash $exe)){throw 'Native settings isolation or new app startup is unverified; live wall untouched.'}
    $sourceStatus=Status-Probe $PythonPath @('-B',$wardenSource,'status') $wardenVersion
    $exeStatus=Status-Probe $candidate @('status') $wardenVersion
    $preflight=[ordered]@{Passed=$true;NativeSettingsIsolated=$startup.NativeSettingsIsolated;SHA256=(File-Hash $exe);Version=$version+'.0';WardenSourceStatusPassed=$sourceStatus;WardenExeStatusPassed=$exeStatus;WardenVersion=$wardenVersion;WardenSourceSHA256=(File-Hash $wardenSource);WardenExeSHA256=(File-Hash $candidate)}
    $preflightPath=Join-Path $run 'preflight.json';Save-Json $preflight $preflightPath
    $base=[ordered]@{Commit=$compiledCommit;AppVersion=$version+'.0';AppPath=$exe;AppSHA256=(File-Hash $exe);PdbPath=$pdb;PdbSHA256=(File-Hash $pdb);WardenSourcePath=$wardenSource;WardenSourceSHA256=(File-Hash $wardenSource);WardenExePath=$candidate;WardenExeSHA256=(File-Hash $candidate);WardenVersion=$wardenVersion;WardenSourceMatchRecord=$proof;PreflightPath=$preflightPath;StartupMonitorPath=$monitorPath;StartupMonitorSHA256=(File-Hash $monitorPath)}
    Save-Json $base (Join-Path $run 'build-manifest.json')
    if(Native git @('-C',$source,'status','--porcelain') 'source-final-clean'){throw 'Build unexpectedly modified source.'}
    if($buildPlan.build){
        Complete-CilexBuild -Plan $buildPlan -Outputs @{binary=$exe;symbols=$pdb;warden=$candidate} -Metadata @{exe=$exe;pdb=$pdb;warden=$candidate}
    }else{[IO.File]::Delete($buildPlan.PlanPath)}
    Write-Output ('Binary: '+[IO.Path]::GetFullPath($exe))
    if($BuildOnly){$summary.Status='BuildVerified';Write-Output ('Build and checks passed: Watchtower '+$version+'. No installed files changed.');return}
    Write-Output 'Build and startup checks passed. Preparing station backups and updates.'
    if('Office'-in $Targets){
        Office-Connect;New-Item -ItemType Directory -Path (Join-Path $officeRemote 'tools\office') -Force|Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'StationDeployment.psm1') -Destination (Join-Path $officeRemote 'tools\StationDeployment.psm1')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'StationVideoHealth.psm1') -Destination (Join-Path $officeRemote 'tools\StationVideoHealth.psm1')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'office\station-office.ps1') -Destination (Join-Path $officeRemote 'tools\office\station-office.ps1')
        Copy-Item -LiteralPath $monitorPath -Destination (Join-Path $officeRemote 'tools\office\isolated-startup.py')
        $inspection=(Office-Job 'Inspect').inspection
        if(-not $inspection){throw 'Office inspection returned no data.'}
        $officeInstall=[string]$inspection.installPath
        $officeInstalledUNC=Join-Path $officeShare $officeInstall.Substring(3)
        $null=Native $PythonPath @('-B',$importScript,$exe,(Join-Path $officeInstalledUNC 'watchtower.exe')) 'office-imports'
        $officeProof=Native $PythonPath @('-B',(Join-Path $PSScriptRoot 'verify-warden.py'),'--exe',(Join-Path $officeInstalledUNC 'warden\warden.exe'),'--source',$wardenSource) 'office-warden-match' -AllowedExitCodes @(0,1,2)|ConvertFrom-Json
        $release=Join-Path $officeRemote 'release';New-Item -ItemType Directory -Path (Join-Path $release 'platforms') -Force|Out-Null
        $officeExe=if($officeProof.matches){Join-Path $officeInstalledUNC 'warden\warden.exe'}else{$candidate}
        foreach($pair in @(@($exe,'watchtower.exe'),@($pdb,'watchtower.pdb'),@($wardenSource,'warden.py'),@($officeExe,'warden.exe'),@((Join-Path $QtRoot 'plugins\platforms\qoffscreen.dll'),'platforms\qoffscreen.dll'))){Copy-Item -LiteralPath $pair[0] -Destination (Join-Path $release $pair[1]);if((File-Hash $pair[0])-ne(File-Hash (Join-Path $release $pair[1]))){throw 'Office staged copy differs from source.'}}
        $officeManifest=[ordered]@{};foreach($k in $base.Keys){$officeManifest[$k]=$base[$k]}
        $officeManifest.AppPath=$officeLocal+'\release\watchtower.exe';$officeManifest.PdbPath=$officeLocal+'\release\watchtower.pdb';$officeManifest.WardenSourcePath=$officeLocal+'\release\warden.py';$officeManifest.WardenExePath=$officeLocal+'\release\warden.exe';$officeManifest.WardenExeSHA256=File-Hash $officeExe
        if($officeProof.matches){$officeManifest.WardenExePath=Join-Path $officeInstall 'warden\warden.exe'}
        $officeManifest.PythonPath=if($inspection.pythonPath){$inspection.pythonPath}else{Join-Path $inspection.profilePath 'AppData\Local\Programs\Python\Python312\python.exe'};$officeManifest.StartupMonitorPath=$officeLocal+'\tools\office\isolated-startup.py'
        $officeManifest.WardenSourceMatchRecord=if($officeProof.matches){$officeProof}else{$proof};$officeManifest.PreserveInstalledWarden=[bool]$officeProof.matches;$officeManifest.InstallPath=$officeInstall;$officeManifest.ExpectedHost=$ExpectedOfficeHost;$officeManifest.ExpectedSID=$inspection.task.storedOwnerSid
        $officeManifest.FlightRecorderPath=$OfficeFlightRecorderPath
        $officeApps=@($inspection.processes|Where-Object name -eq 'watchtower.exe');if($officeApps.Count-ne 1){throw 'Office must have one running camera wall before deployment.'};$officeManifest.ExpectedSession=[int]$officeApps[0].session;$officeManifest.WardenTask=$OfficeWardenTask;$officeManifest.StagePath=$officeLocal+'\release';$officeManifest.OffscreenPath=$officeLocal+'\release\platforms\qoffscreen.dll';$officeManifest.OffscreenSHA256=File-Hash (Join-Path $release 'platforms\qoffscreen.dll')
        Save-Json $officeManifest (Join-Path $officeRemote 'manifest.json');Save-Json $officeManifest (Join-Path $run 'office-manifest.json')
    }
    if('Booth'-in $Targets){
        $snapshot=Booth-Snapshot;$snapshotPath=Join-Path $run 'booth-runtime.json';Save-Json $snapshot $snapshotPath
        $boothManifest=[ordered]@{};foreach($k in $base.Keys){$boothManifest[$k]=$base[$k]};$boothManifest.InstallPath=$install;$boothManifest.ExpectedHost=$ExpectedBoothHost;$boothManifest.ExpectedSID=$snapshot.IdentitySID;$boothManifest.ExpectedSession=$snapshot.Session;$boothManifest.PythonPath=$PythonPath;$boothManifest.WatchdogPath=$WatchdogPath;$boothManifest.WatchdogTask=$WatchdogTask;$boothManifest.HoldPath=$snapshot.Labs.ControlPath
        $boothManifest.FlightRecorderPath=$BoothFlightRecorderPath
        $manifestPath=Join-Path $run 'booth-manifest.json';Save-Json $boothManifest $manifestPath
        $resultPath=Join-Path $run 'booth-result.json'
        $null=Native (Get-Command pwsh.exe).Source @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'station-booth.ps1'),'-ManifestPath',$manifestPath,'-RuntimePath',$snapshotPath,'-BackupPath',(Join-Path $run 'booth-backup'),'-ResultPath',$resultPath) 'booth-update' $JobTimeoutSeconds
        $summary.Booth=Read-Json $resultPath;if($summary.Booth.status-ne 'Success'){throw 'Booth deployment or recovery requires attention.'};Write-Output 'Security Booth updated and stable.'
    }
    if('Office'-in $Targets){$summary.Office=Office-Job 'Update' ($officeLocal+'\manifest.json');Write-Output 'Office updated and stable.'}
    $summary.Status='Success'
} catch {
    # Never write invocation arguments, environment, credentials or arbitrary application output.
    $summary.Status='Failed';$summary.Error=$_.Exception.Message
    Write-Error $summary.Error -ErrorAction Continue
    throw
} finally {
    $summary['CompletedUTC']=[DateTime]::UtcNow.ToString('o')
    try{Save-Json $summary (Join-Path $run 'result.json')}finally{if($entryLock){$entryLock.Dispose()}}
    Write-Output ('Run record: '+(Join-Path $run 'result.json'))
}
