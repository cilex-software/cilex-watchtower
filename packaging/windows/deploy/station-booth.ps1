[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ManifestPath,
    [Parameter(Mandatory=$true)][string]$RuntimePath,
    [Parameter(Mandatory=$true)][string]$BackupPath,
    [Parameter(Mandatory=$true)][string]$ResultPath
)
$ErrorActionPreference='Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'StationDeployment.psm1') -Force -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'StationVideoHealth.psm1') -Force -DisableNameChecking -ErrorAction Stop
    foreach($path in @($ManifestPath,$RuntimePath,$BackupPath,$ResultPath)) { if($path -notmatch '^[A-Za-z]:[\\/]') { throw 'LOCAL_ABSOLUTE_PATH_REQUIRED' } }
    $manifestRaw=Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $manifest=$manifestRaw|ConvertFrom-Json -DateKind String } else { $manifest=$manifestRaw|ConvertFrom-Json }
    foreach($field in @('Commit','AppVersion','AppPath','AppSHA256','PdbPath','PdbSHA256','WardenSourcePath','WardenSourceSHA256','WardenExePath','WardenExeSHA256','WardenVersion','PythonPath','InstallPath','WatchdogTask','WatchdogPath','ExpectedHost','ExpectedSID','ExpectedSession','PreflightPath','HoldPath')) { if($null -eq $manifest.PSObject.Properties[$field] -or -not [string]$manifest.$field) { throw 'MANIFEST_FIELD_REQUIRED' } }
    foreach($field in @('AppSHA256','PdbSHA256','WardenSourceSHA256','WardenExeSHA256')) { if([string]$manifest.$field -notmatch '^[0-9A-Fa-f]{64}$') { throw 'MANIFEST_SHA256_INVALID' } }
    foreach($field in @('AppPath','PdbPath','WardenSourcePath','WardenExePath','PythonPath','InstallPath','WatchdogPath','PreflightPath','HoldPath')) { if([string]$manifest.$field -notmatch '^[A-Za-z]:[\\/]') { throw 'MANIFEST_PATH_INVALID' } }
    if([string]$manifest.AppVersion -notmatch '^\d+\.\d+\.\d+\.\d+$' -or [string]$manifest.WardenVersion -notmatch '^\d+\.\d+\.\d+$' -or [string]$manifest.Commit -notmatch '^(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$' -or [string]$manifest.ExpectedSID -notmatch '^S-1-5-21-[0-9-]+$' -or [int]$manifest.ExpectedSession -lt 1) { throw 'MANIFEST_IDENTITY_OR_VERSION_INVALID' }
} catch { Write-Output 'Station update refused before preparation: invalid manifest or local module.'; exit 4 }
# Updates a Python-Warden station in its verified interactive user session. No probes run here.
$ErrorActionPreference = 'Stop'
$expectedVersion = [string]$manifest.AppVersion
$expectedCommit = [string]$manifest.Commit
$expectedAppSHA = [string]$manifest.AppSHA256
$expectedWardenSHA = [string]$manifest.WardenExeSHA256
$expectedSourceSHA = [string]$manifest.WardenSourceSHA256
$expectedSID = [string]$manifest.ExpectedSID
$expectedHost = [string]$manifest.ExpectedHost
$expectedSession = [int]$manifest.ExpectedSession
$expectedWardenVersion = [string]$manifest.WardenVersion
$expectedPdbSHA = [string]$manifest.PdbSHA256
$watchdogPath = [string]$manifest.WatchdogPath
$watchdogTask = [string]$manifest.WatchdogTask
if (-not $watchdogTask.StartsWith('\')) { $watchdogTask='\'+$watchdogTask }
$taskSplit=$watchdogTask.LastIndexOf('\')
$taskPath=$watchdogTask.Substring(0,$taskSplit+1)
$taskName=$watchdogTask.Substring($taskSplit+1)
$install = [string]$manifest.InstallPath
$appPath = Join-Path $install 'watchtower.exe'
$pdbPath = Join-Path $install 'watchtower.pdb'
$wardenSource = Join-Path $install 'warden\warden.py'
$wardenExe = Join-Path $install 'warden\warden.exe'
$pythonPath = [string]$manifest.PythonPath
$powershellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$spool = Join-Path $env:LOCALAPPDATA 'watchtower-warden'
$holdPath = [string]$manifest.HoldPath
$session = (Get-Process -Id $PID).SessionId
$runtime = $null
$components=@(
    [pscustomobject]@{Name='watchtower.exe';Source=[string]$manifest.AppPath;Destination=$appPath;SHA256=$expectedAppSHA},
    [pscustomobject]@{Name='warden.py';Source=[string]$manifest.WardenSourcePath;Destination=$wardenSource;SHA256=$expectedSourceSHA},
    [pscustomobject]@{Name='warden.exe';Source=[string]$manifest.WardenExePath;Destination=$wardenExe;SHA256=$expectedWardenSHA},
    [pscustomobject]@{Name='watchtower.pdb';Source=[string]$manifest.PdbPath;Destination=$pdbPath;SHA256=$expectedPdbSHA}
)
$before = $null
$guardBefore = $null
$guardCaptured = $false
$pauseAttempted = $false
$liveTouched = $false
$backupVerified = $false
$newWarden = $null
$newApp = $null
$status = 'NotStarted'
$exitCode = 4
$failure = $null
$rollbackError = $null
$taskRestoreError = $null
$stableSeconds = 0
$videoBaseline = $null
$videoHealth = $null
$videoLogPath = Join-Path $env:APPDATA 'Cilex Vision\Watchtower\flightrec\watchtower.log'
if($manifest.PSObject.Properties['FlightRecorderPath'] -and [string]$manifest.FlightRecorderPath){$videoLogPath=[string]$manifest.FlightRecorderPath}
$outcome = [ordered]@{}
$guardEnabledAfter = $null
$watchdogAfter = $null
$stationLock = $null
$saveResult = -not (Test-Path -LiteralPath $ResultPath)

function Read-Json([string]$path) {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return ($raw | ConvertFrom-Json -DateKind String) }
    return ($raw | ConvertFrom-Json)
}
function Utc($value) {
    if ($value -is [DateTime]) {
        if ($value.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($value,[DateTimeKind]::Utc) }
        return $value.ToUniversalTime()
    }
    return [DateTime]::Parse([string]$value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
function Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
function Safe-Hash([string]$path) { try { if(Test-Path -LiteralPath $path -PathType Leaf) { return (Hash $path) } } catch { }; return $null }
function Same-Path([string]$a,[string]$b) { return [string]::Equals($a,$b,[StringComparison]::OrdinalIgnoreCase) }
function Safe-Reason($errorRecord) {
    $message=[string]$errorRecord.Exception.Message
    if($message -match '^[A-Z0-9_]{3,100}$') { return $message }
    return $errorRecord.Exception.GetType().Name
}
function No-Reparse([string]$path) {
    $full=[IO.Path]::GetFullPath($path)
    while($full) {
        if(Test-Path -LiteralPath $full) { if((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'REPARSE_PATH_REFUSED' } }
        $parent=Split-Path -Path $full -Parent
        if(-not $parent -or $parent -eq $full) { break }
        $full=$parent
    }
}
function Validate-Staged {
    foreach($component in $components) { No-Reparse $component.Source; if((Hash $component.Source) -ne $component.SHA256) { throw 'STAGED_COMPONENT_HASH_MISMATCH' } }
    if((Get-Item -LiteralPath $manifest.AppPath).VersionInfo.FileVersion -ne $expectedVersion) { throw 'STAGED_APP_VERSION_MISMATCH' }
    $sourceVersion=Select-String -LiteralPath $manifest.WardenSourcePath -Pattern '^WARDEN_VERSION\s*=\s*["'']([^"'']+)["'']'|Select-Object -First 1
    if($null -eq $sourceVersion -or $sourceVersion.Matches[0].Groups[1].Value -ne $expectedWardenVersion) { throw 'STAGED_WARDEN_SOURCE_VERSION_MISMATCH' }
}
function Get-Proc([int]$processId) { return (Get-CimInstance Win32_Process -Filter ('ProcessId=' + $processId) | Select-Object -First 1) }
function Owner-SID($process) {
    $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
    if ($owner.ReturnValue -ne 0) { throw 'Cannot verify process owner' }
    return $owner.Sid
}
function Snapshot($process,[string]$role,[string]$scriptPath = '') {
    return [pscustomobject]@{Role=$role; PID=[int]$process.ProcessId; ParentPID=[int]$process.ParentProcessId; Name=[string]$process.Name; Path=[string]$process.ExecutablePath; ScriptPath=$scriptPath; OwnerSID=(Owner-SID $process); Session=[int]$process.SessionId; CreatedUTC=$process.CreationDate.ToUniversalTime().ToString('o'); Priority=[string](Get-Process -Id $process.ProcessId).PriorityClass}
}
function Script-Argument([string]$command,[string]$path,[switch]$PowerShell) {
    $escaped = [regex]::Escape($path)
    $token = '(?:"' + $escaped + '"|' + $escaped + ')(?=\s|$)'
    if ($PowerShell) { return ($command -match ('(?i)(?:^|\s)-File\s+' + $token)) }
    return ($command -match ('(?i)(?:^|\s)' + $token) -and $command -match '(?:^|\s)run(?:\s|$)')
}
function Assert-Record($record,[switch]$AllowAbsent) {
    if ($null -eq $record -or [int]$record.PID -le 0) { throw 'Missing process identity record' }
    $process = Get-Proc ([int]$record.PID)
    if ($null -eq $process) { if ($AllowAbsent) { return $null }; throw 'Expected process exited before update' }
    if ($process.Name -ne $record.Name -or -not (Same-Path $process.ExecutablePath $record.Path) -or [int]$process.SessionId -ne [int]$record.Session -or [int]$process.SessionId -ne $session -or $record.OwnerSID -ne $expectedSID -or (Owner-SID $process) -ne $expectedSID -or [Math]::Abs($process.CreationDate.ToUniversalTime().Ticks - (Utc $record.CreatedUTC).Ticks) -gt 10) { throw 'Process SID, session, path or creation time changed' }
    if ($record.Role -eq 'WardenPython' -and (-not (Same-Path $process.ExecutablePath $pythonPath) -or -not (Script-Argument $process.CommandLine $wardenSource))) { throw 'Exact Python Warden script no longer matches' }
    if ($record.Role -eq 'WallWatchdog' -and (-not (Same-Path $process.ExecutablePath $powershellPath) -or -not (Script-Argument $process.CommandLine $watchdogPath -PowerShell))) { throw 'Exact watchdog script no longer matches' }
    if ($record.Role -eq 'Watchtower' -and -not (Same-Path $process.ExecutablePath $appPath)) { throw 'Installed camera-wall path changed' }
    return $process
}
function Stop-Record($record) {
    if ($record.Role -notin @('WardenPython','Watchtower','WallWatchdog') -or [int]$record.PID -eq $PID) { throw 'Process is outside the permitted stop scope' }
    $process = Assert-Record $record -AllowAbsent
    if ($null -eq $process) { return }
    $handle = [Diagnostics.Process]::GetProcessById([int]$record.PID)
    try {
        $null = $handle.Handle
        # CIM rounds to microseconds; the stable process handle uses 100 ns ticks.
        if ([Math]::Abs($handle.StartTime.ToUniversalTime().Ticks - (Utc $record.CreatedUTC).Ticks) -gt 10) { throw 'Process ID was reused before stop' }
        $handle.Kill()
        if (-not $handle.WaitForExit(10000)) { throw 'Verified process did not exit' }
    } finally { $handle.Dispose() }
}
function Live-Apps {
    return @(Get-CimInstance Win32_Process -Filter "Name='watchtower.exe'" | Where-Object { $_.SessionId -eq $session -and (Same-Path $_.ExecutablePath $appPath) })
}
function Live-Supervisors {
    return @(Get-CimInstance Win32_Process | Where-Object { $_.SessionId -eq $session -and ((Same-Path $_.ExecutablePath $wardenExe) -or ($_.Name -in @('python.exe','pythonw.exe') -and (Script-Argument ([string]$_.CommandLine) $wardenSource))) })
}
function Live-Watchdogs {
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.SessionId -eq $session -and (Script-Argument ([string]$_.CommandLine) $watchdogPath -PowerShell) })
}
function Assert-Labs-And-Hold {
    if($runtime.Labs.ControlPath -and -not (Same-Path $holdPath $runtime.Labs.ControlPath)) { throw 'LABS_CONTROL_PATH_CHANGED' }
    if ((Hash $holdPath) -ne $runtime.Labs.ControlSHA256) { throw 'Operator Labs control changed; it will not be edited' }
    $labs = @(Get-CimInstance Win32_Process | Where-Object {
        ($_.Name -in @('python.exe','pythonw.exe') -and $_.CommandLine -match '(?i)(?:^|\s)(?:"[^"\r\n]*run_worker\.py"|[^\s"\r\n]*run_worker\.py)(?=\s|$)' -and $_.CommandLine -match '(?:^|\s)--loop(?:\s|$)') -or
        ($_.Name -in @('powershell.exe','pwsh.exe') -and $_.ProcessId -ne $PID -and $_.CommandLine -match '(?i)(?:^|\s)-File\s+(?:"[^"\r\n]*guard[23]\.ps1"|[^\s"\r\n]*guard[23]\.ps1)(?=\s|$)')
    })
    if ($labs.Count) { throw 'Labs worker or guard appeared; update is refused' }
    $labsTasks = @(Get-ScheduledTask | Where-Object { $_.TaskName -match '(?i)labs' -or @($_.Actions | Where-Object { ([string]$_.Execute+' '+[string]$_.Arguments) -match '(?i)(guard[23]\.ps1|run_worker\.py|start-labs)' }).Count -gt 0 })
    if ($labsTasks.Count) { throw 'A Labs startup task appeared; review it before updating' }
}
function Assert-Guard-Definition {
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    [xml]$xml = Export-ScheduledTask -InputObject $task
    $namespaces = New-Object Xml.XmlNamespaceManager $xml.NameTable
    $namespaces.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    $principals = @($xml.SelectNodes('/t:Task/t:Principals/t:Principal',$namespaces))
    if ($principals.Count -ne 1) { throw 'Watchdog task principal is ambiguous' }
    $levels = @($principals[0].SelectNodes('t:RunLevel',$namespaces))
    $allLevels = @($principals[0].SelectNodes('*[local-name()="RunLevel"]'))
    $apiLevel = if ($task.Principal -and $task.Principal.PSObject.Properties['RunLevel']) { $task.Principal.RunLevel } else { $null }
    $limited = $null -ne $apiLevel -and $apiLevel.GetType().IsEnum -and
        $apiLevel.GetType().FullName -ceq 'Microsoft.PowerShell.Cmdletization.GeneratedTypes.ScheduledTask.RunLevelEnum' -and
        [Enum]::IsDefined($apiLevel.GetType(),$apiLevel) -and [string]$apiLevel -ceq 'Limited' -and [int]$apiLevel -eq 0
    # Windows omits its schema-default LeastPrivilege on export (observed on
    # this station 2026-11-10). The independently typed task API must agree.
    $xmlLimited = $levels.Count -eq 0 -or ($levels.Count -eq 1 -and
        $levels[0].Attributes.Count -eq 0 -and $levels[0].SelectNodes('*').Count -eq 0 -and
        $levels[0].InnerText -ceq 'LeastPrivilege')
    $runLevelValid = $limited -and $xmlLimited -and $allLevels.Count -eq $levels.Count
    $user = [string]$xml.Task.Principals.Principal.UserId
    $sid = if ($user -match '^S-1-') { $user } else { ([Security.Principal.NTAccount]::new($user)).Translate([Security.Principal.SecurityIdentifier]).Value }
    $actions = @($task.Actions)
    $expectedAction = $guardBefore.Actions[0]
    if ($sid -ne $expectedSID -or [string]$xml.Task.Principals.Principal.LogonType -ne 'InteractiveToken' -or -not $runLevelValid -or $actions.Count -ne 1 -or [string]$actions[0].Execute -ne [string]$expectedAction.Execute -or [string]$actions[0].Arguments -ne [string]$expectedAction.Arguments -or [string]$actions[0].WorkingDirectory -ne [string]$expectedAction.WorkingDirectory -or (Hash $watchdogPath) -ne $runtime.Installed.WatchdogSHA256) { throw 'Watchdog task definition or script changed' }
    return $task
}
function Assert-Quiescent {
    if (@(Live-Watchdogs).Count -or @(Live-Supervisors).Count -or @(Live-Apps).Count -or (Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName).Settings.Enabled) { throw 'Installed supervision or camera wall is not quiescent' }
    Assert-Labs-And-Hold
}
function Stop-Supervised-Scope($supervisor,$initialApp) {
    $children = @(Live-Apps)
    foreach ($child in $children) {
        if ([int]$child.ParentProcessId -ne [int]$supervisor.PID -or $child.CreationDate.ToUniversalTime() -lt (Utc $supervisor.CreatedUTC)) { throw 'Unexpected installed wall cannot be stopped automatically' }
        $null = Assert-Record (Snapshot $child 'Watchtower')
    }
    Stop-Record $supervisor
    # Capture a child started during the final supervisor stop race; ownership is still checked.
    foreach ($child in @(Live-Apps)) {
        if ([int]$child.ParentProcessId -ne [int]$supervisor.PID -or $child.CreationDate.ToUniversalTime() -lt (Utc $supervisor.CreatedUTC)) { throw 'Unexpected installed wall remains; no broad kill is allowed' }
        Stop-Record (Snapshot $child 'Watchtower')
    }
    if ($initialApp) { Stop-Record $initialApp }
    for ($n=0; $n -lt 10; $n++) {
        if (@(Live-Apps).Count -eq 0 -and @(Live-Supervisors).Count -eq 0) { return }
        Start-Sleep -Milliseconds 300
    }
    throw 'Installed wall or supervisor remains running'
}
function Start-Python-Warden {
    if (@(Live-Supervisors).Count -or @(Live-Apps).Count) { throw 'Cannot start another supervisor over a live installed instance' }
    $process = Start-Process -FilePath $pythonPath -ArgumentList @(('"{0}"' -f $wardenSource),'run') -WorkingDirectory (Split-Path $wardenSource) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $spool 'warden-stdout.log') -RedirectStandardError (Join-Path $spool 'warden-stderr.log')
    # Register the child immediately using the retained native process handle.
    # This identity remains known even if new source exits during later CIM checks.
    $null=$process.Handle
    $record=[pscustomobject]@{Role='WardenPython';PID=[int]$process.Id;ParentPID=$PID;Name=[IO.Path]::GetFileName($pythonPath);Path=$pythonPath;ScriptPath=$wardenSource;OwnerSID=$expectedSID;Session=$session;CreatedUTC=$process.StartTime.ToUniversalTime().ToString('o');Priority=[string]$originalWarden.Priority}
    $script:newWarden = $record
    $process.PriorityClass = [enum]::Parse([Diagnostics.ProcessPriorityClass],[string]$originalWarden.Priority)
    $record.Priority=[string]$process.PriorityClass
    $null = Assert-Record $record
    return $record
}
function Wait-Supervised($supervisor,[string]$version,[string]$sha) {
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        $null = Assert-Record $supervisor
        $apps = @(Live-Apps)
        if ($apps.Count -gt 1 -or @(Live-Supervisors).Count -ne 1) { throw 'Duplicate installed instances detected' }
        if ($apps.Count -eq 1) {
            $record = Snapshot $apps[0] 'Watchtower'
            $null = Assert-Record $record
            if ($apps[0].ParentProcessId -ne $supervisor.PID -or (Get-Item -LiteralPath $appPath).VersionInfo.FileVersion -ne $version -or (Hash $appPath) -ne $sha) { throw 'New camera wall is not correctly supervised or installed' }
            if ((Get-Process -Id $record.PID).MainWindowHandle -ne [IntPtr]::Zero) { return $record }
        }
        Assert-Labs-And-Hold
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'No correctly supervised camera-wall window within startup deadline'
}
function Check-Stability($supervisor,$app,[int]$seconds) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $seconds) {
        $null = Assert-Record $supervisor
        $live = Assert-Record $app
        if ($live.ParentProcessId -ne $supervisor.PID -or @(Live-Apps).Count -ne 1 -or @(Live-Supervisors).Count -ne 1) { throw 'Supervised camera wall changed during verification' }
        Assert-Labs-And-Hold
        Start-Sleep -Seconds 3
    }
    $after=Get-StationVideoSnapshot -LogPath $videoLogPath -ProcessId $app.PID -CreatedUTC ([DateTime]::Parse($app.CreatedUTC).ToUniversalTime())
    $script:videoHealth=Assert-StationVideoProgress -Before $videoBaseline -After $after
    return [int]$timer.Elapsed.TotalSeconds
}
function Restore-Watchdog {
    $task=Assert-Guard-Definition
    if (-not [bool]$guardBefore.ObservedEnabled) {
        if ($task.Settings.Enabled) { Disable-ScheduledTask -InputObject $task | Out-Null }
        return $null
    }
    if (-not $task.Settings.Enabled) { Enable-ScheduledTask -InputObject $task | Out-Null }
    $deadline=[DateTime]::UtcNow.AddSeconds(40)
    $startIssued=$false
    do {
        $task=Assert-Guard-Definition
        if (-not $task.Settings.Enabled) { throw 'Restored watchdog task is not enabled' }
        $watchdogs=@(Live-Watchdogs)
        if ($watchdogs.Count -gt 1) { throw 'Duplicate watchdogs appeared; none will be killed automatically' }
        if ($watchdogs.Count -eq 1) {
            $record=Snapshot $watchdogs[0] 'WallWatchdog' $watchdogPath
            $null=Assert-Record $record
            if ($task.State -eq 'Running') { return $record }
        } elseif ($task.State -eq 'Ready' -and -not $startIssued) {
            Start-ScheduledTask -InputObject $task
            $startIssued=$true
        }
        # A killed task action may remain Running briefly. Wait instead of assuming
        # a Running task still contains its watchdog, or stopping an unknown tree.
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Original watchdog task did not restore one verified running watchdog' }
        Start-Sleep -Seconds 1
    } while ($true)
}

try {
    if ($env:COMPUTERNAME -ne $expectedHost -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne $expectedSID -or $session -ne $expectedSession) { throw 'STATION_ACCOUNT_OR_SESSION_MISMATCH' }
    $runtime = Read-Json $RuntimePath
    $preflight = Read-Json ([string]$manifest.PreflightPath)
    if ($runtime.Host -ne $env:COMPUTERNAME -or $runtime.IdentitySID -ne $expectedSID -or [int]$runtime.Session -ne $session -or ([DateTime]::UtcNow - (Utc $runtime.CapturedUTC)).TotalMinutes -gt 45 -or (Utc $runtime.CapturedUTC) -gt [DateTime]::UtcNow.AddSeconds(10)) { throw 'Runtime preflight is stale or belongs to another station' }
    if($preflight.Passed -isnot [bool] -or -not $preflight.Passed -or $preflight.SHA256 -ne $expectedAppSHA -or $preflight.Version -ne $expectedVersion) { throw 'EXACT_APP_ADMISSION_REQUIRED' }
    if($preflight.NativeSettingsIsolated -isnot [bool] -or -not $preflight.NativeSettingsIsolated) { throw 'PRIVATE_NATIVE_SETTINGS_ADMISSION_REQUIRED' }
    if($preflight.WardenSourceStatusPassed -isnot [bool] -or $preflight.WardenExeStatusPassed -isnot [bool] -or -not $preflight.WardenSourceStatusPassed -or -not $preflight.WardenExeStatusPassed -or $preflight.WardenVersion -ne $expectedWardenVersion -or $preflight.WardenSourceSHA256 -ne $expectedSourceSHA -or $preflight.WardenExeSHA256 -ne $expectedWardenSHA) { throw 'EXACT_WARDEN_ADMISSION_REQUIRED' }
    Validate-Staged
    foreach($path in @($install,$pythonPath,$watchdogPath,$holdPath,$BackupPath,$ResultPath)) { No-Reparse $path }
    foreach($component in $components) { No-Reparse $component.Destination }
    if (-not (Same-Path $runtime.Installed.WatchtowerPath $appPath) -or -not (Same-Path $runtime.Installed.WardenPythonPath $wardenSource) -or -not (Same-Path $runtime.Installed.WardenPackagedPath $wardenExe) -or (Hash $wardenSource) -ne $runtime.Installed.WardenSourceSHA256 -or (Hash $wardenExe) -ne $runtime.Installed.WardenPackagedSHA256 -or (Hash $appPath) -ne $runtime.Installed.WatchtowerSHA256) { throw 'INSTALLED_COMPONENTS_CHANGED' }
    # Independent of the caller's run directory: direct helper calls cannot overlap.
    $stationLockPath=Join-Path $install 'station-booth-update.lock'
    No-Reparse $stationLockPath
    try { $stationLock=[IO.File]::Open($stationLockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { throw 'STATION_HELPER_ALREADY_RUNNING_OR_LOCK_UNAVAILABLE' }
    if ($runtime.Labs.GuardCount -ne 0 -or $runtime.Labs.WorkerCount -ne 0 -or $runtime.Labs.TaskCount -ne 0) { throw 'Preflight did not establish stopped Labs' }
    $originalApps = @($runtime.Processes | Where-Object Role -eq 'Watchtower')
    $originalWardens = @($runtime.Processes | Where-Object Role -eq 'WardenPython')
    $originalWatchdogs = @($runtime.Processes | Where-Object Role -eq 'WallWatchdog')
    if ($originalApps.Count -ne 1 -or $originalWardens.Count -ne 1 -or $originalWatchdogs.Count -ne 1 -or @($runtime.Processes | Where-Object Role -eq 'WardenPackaged').Count -ne 0) { throw 'Expected one Python-supervised booth wall and watchdog' }
    $originalApp=$originalApps[0]; $originalWarden=$originalWardens[0]; $originalWatchdog=$originalWatchdogs[0]
    $guardRecords = @($runtime.Tasks | Where-Object Name -eq ($taskPath + $taskName))
    if ($guardRecords.Count -ne 1) { throw 'Missing watchdog task record' }
    $guardBefore=$guardRecords[0]
    $task = Assert-Guard-Definition
    if ([bool]$task.Settings.Enabled -ne [bool]$guardBefore.ObservedEnabled) { throw 'Watchdog enabled state changed after inspection' }
    $guardCaptured=$true
    $liveApp=Assert-Record $originalApp
    $null=Assert-Record $originalWarden
    $null=Assert-Record $originalWatchdog
    if ($liveApp.ParentProcessId -ne $originalWarden.PID -or @(Live-Apps).Count -ne 1 -or @(Live-Supervisors).Count -ne 1 -or @(Live-Watchdogs).Count -ne 1) { throw 'Original process parentage or instance count changed' }
    Assert-Labs-And-Hold
    if (Test-Path -LiteralPath $BackupPath) { throw 'Unique backup directory already exists' }
    if (Test-Path -LiteralPath $ResultPath) { throw 'Result path already exists; use a fresh run path' }
    No-Reparse $videoLogPath
    $videoBaseline=Get-StationVideoSnapshot -LogPath $videoLogPath -ProcessId $originalApp.PID -CreatedUTC ([DateTime]::Parse($originalApp.CreatedUTC).ToUniversalTime())
    $null=Assert-StationVideoBaseline -Snapshot $videoBaseline
    if(-not $videoBaseline.ExpectedVideo){throw 'NO_ACTIVE_CAMERA_VIDEO_BEFORE_UPDATE'}
    $oldSourceVersion=Select-String -LiteralPath $wardenSource -Pattern '^WARDEN_VERSION\s*=\s*["'']([^"'']+)["'']'|Select-Object -First 1
    if($null -eq $oldSourceVersion) { throw 'INSTALLED_WARDEN_VERSION_UNAVAILABLE' }
    $before=[ordered]@{app_version=(Get-Item -LiteralPath $appPath).VersionInfo.FileVersion;warden_version=$oldSourceVersion.Matches[0].Groups[1].Value;app_hash=(Hash $appPath);source_hash=(Hash $wardenSource);fallback_hash=(Hash $wardenExe);pdb_existed=(Test-Path -LiteralPath $pdbPath -PathType Leaf);pdb_hash=if(Test-Path -LiteralPath $pdbPath -PathType Leaf){Hash $pdbPath}else{$null};guard_enabled=[bool]$guardBefore.ObservedEnabled;hold_hash=(Hash $holdPath);original_app=$originalApp;original_warden=$originalWarden;original_watchdog=$originalWatchdog}
    New-Item -ItemType Directory -Path $BackupPath | Out-Null
    foreach ($item in @(@($appPath,'watchtower.exe',$before.app_hash),@($wardenSource,'warden.py',$before.source_hash),@($wardenExe,'warden.exe',$before.fallback_hash))) {
        Copy-Item -LiteralPath $item[0] -Destination (Join-Path $BackupPath $item[1]) -ErrorAction Stop
        if ((Hash (Join-Path $BackupPath $item[1])) -ne $item[2]) { throw 'Backup verification failed; live wall untouched' }
    }
    if ($before.pdb_existed) {
        Copy-Item -LiteralPath $pdbPath -Destination (Join-Path $BackupPath 'watchtower.pdb') -ErrorAction Stop
        if ((Hash (Join-Path $BackupPath 'watchtower.pdb')) -ne $before.pdb_hash) { throw 'Debug-symbol backup verification failed' }
    }
    [IO.File]::WriteAllText((Join-Path $BackupPath 'before.json'),($before|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    $backupVerified=$true
    # Complete all preparation before the short camera-wall stop.
    $null=Assert-Record $originalApp; $null=Assert-Record $originalWarden; $null=Assert-Record $originalWatchdog
    Assert-Labs-And-Hold
    $pauseAttempted=$true
    Validate-Staged
    Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName | Out-Null
    if ((Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName).Settings.Enabled) { throw 'Watchdog task did not disable' }
    $liveTouched=$true
    # Do not Stop-ScheduledTask: only the verified watchdog PID is stopped.
    Stop-Record $originalWatchdog
    if (@(Live-Watchdogs).Count) { throw 'A watchdog remains; file swap is refused' }
    Stop-Supervised-Scope $originalWarden $originalApp
    Assert-Quiescent
    foreach($component in $components) { $null=Install-StationFile -Source $component.Source -Destination $component.Destination -SHA256 $component.SHA256 }
    foreach($component in $components) { if((Hash $component.Destination) -ne $component.SHA256) { throw 'INSTALLED_COMPONENT_HASH_MISMATCH' } }
    $newWarden=Start-Python-Warden
    $newApp=Wait-Supervised $newWarden $expectedVersion $expectedAppSHA
    $stableSeconds=Check-Stability $newWarden $newApp 150
    $status='Success'; $exitCode=0
} catch {
    $failure=Safe-Reason $_
    if ($liveTouched -and $backupVerified) {
        try {
            if ($newWarden) { Stop-Supervised-Scope $newWarden $newApp }
            else { Stop-Supervised-Scope $originalWarden $originalApp }
            Assert-Quiescent
            foreach ($item in @(@('watchtower.exe',$appPath,$before.app_hash,$expectedAppSHA),@('warden.py',$wardenSource,$before.source_hash,$expectedSourceSHA),@('warden.exe',$wardenExe,$before.fallback_hash,$expectedWardenSHA))) {
                $null=Restore-StationFile -Backup (Join-Path $BackupPath $item[0]) -Destination $item[1] -SHA256 $item[2] -Existed $true -InstalledSHA256 $item[3]
                if ((Hash $item[1]) -ne $item[2]) { throw 'ROLLBACK_COMPONENT_HASH_MISMATCH' }
            }
            $null=Restore-StationFile -Backup (Join-Path $BackupPath 'watchtower.pdb') -Destination $pdbPath -SHA256 $before.pdb_hash -Existed ([bool]$before.pdb_existed) -InstalledSHA256 $expectedPdbSHA
            $newWarden=Start-Python-Warden
            $newApp=Wait-Supervised $newWarden $before.app_version $before.app_hash
            $stableSeconds=Check-Stability $newWarden $newApp 150
            $status='RolledBack'; $exitCode=3
        } catch { $status='RollbackFailed'; $rollbackError=Safe-Reason $_; $exitCode=4 }
    } else { $status='FailedBeforeStoppingWall'; $exitCode=4 }
} finally {
    if ($guardCaptured -and $pauseAttempted) {
        try {
            $watchdogAfter=Restore-Watchdog
            if ([bool](Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName).Settings.Enabled -ne [bool]$guardBefore.ObservedEnabled) { throw 'Original watchdog enabled state was not restored' }
        } catch { $taskRestoreError=Safe-Reason $_; $status='RecoveryIncomplete'; $exitCode=4 }
    }
    try { if ($runtime) { Assert-Labs-And-Hold } } catch { $failure='Labs control or stopped state changed during update'; $status='RecoveryIncomplete'; $exitCode=4 }
    try { if ($guardCaptured) { $guardEnabledAfter=[bool](Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName).Settings.Enabled } } catch { $status='RecoveryIncomplete'; $exitCode=4; $taskRestoreError='Could not read restored watchdog task state' }
    $outcome=[ordered]@{status=$status;exit_code=$exitCode;completed_utc=[DateTime]::UtcNow.ToString('o');source_commit=$expectedCommit;watchtower_version=if($status -eq 'Success'){$expectedVersion}elseif($status -eq 'RolledBack'){$before.app_version}else{$null};warden_version=if($status -eq 'Success'){$expectedWardenVersion}elseif($status -eq 'RolledBack'){$before.warden_version}else{$null};backup=$BackupPath;before=$before;app_pid=if($newApp){$newApp.PID}else{$null};warden_pid=if($newWarden){$newWarden.PID}else{$null};stable_seconds=$stableSeconds;video_before=$videoBaseline;video=$videoHealth;error=$failure;rollback_error=$rollbackError;task_restore_error=$taskRestoreError;guard_enabled_after=$guardEnabledAfter;watchdog_after=$watchdogAfter;labs_hold_sha256=(Safe-Hash $holdPath);pdb_sha256=(Safe-Hash $pdbPath);warden_source_sha256=(Safe-Hash $wardenSource);warden_exe_sha256=(Safe-Hash $wardenExe)}
    try { if (-not $saveResult) { throw 'Existing result file will not be overwritten' }; [IO.File]::WriteAllText($ResultPath,($outcome|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false)) }
    catch { $outcome.status='RecoveryIncomplete'; $outcome.exit_code=4; $outcome.error='Could not save update result'; $exitCode=4 }
    # Leave the harmless lock file in place; deleting it after release can race a new owner.
    if($stationLock) { $stationLock.Dispose() }
}
Write-Output ('Booth update: ' + $outcome.status)
exit $exitCode
