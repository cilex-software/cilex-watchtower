# Reusable Office updater. Run as SYSTEM in session 0 on the verified host.
# No credentials are accepted, logged, or read by this script.
[CmdletBinding()]
param(
    [ValidateSet('Inspect','Update')][string]$Mode = 'Inspect',
    [string]$ManifestPath = '',
    [Parameter(Mandatory=$true)][string]$ExpectedHost,
    [Parameter(Mandatory=$true)][string]$ResultPath,
    [string]$WorkRoot = 'C:\ProgramData\CilexWatchtower\CodexDeploy',
    [ValidatePattern('^[A-Za-z0-9_. -]+$')][string]$TaskName = 'wt-warden'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Manifest input contains deployment metadata only; no credentials are accepted.
$Manifest = $null
$TaskNameExplicit = $PSBoundParameters.ContainsKey('TaskName')
$ExpectedUserSid = ''
$ExpectedSessionId = 0
$InstallPath = ''
$TaskPath = '\'
$StagePath = ''
$TargetAppVersion = ''
$TargetAppHash = ''
$TargetWardenVersion = ''
$TargetWardenHash = ''
$TargetSourceHash = ''
$TargetPdbHash = ''
$TargetOffscreenHash = ''
$StartupPython = ''
$StartupMonitor = ''
$StartupMonitorHash = ''
$StartupAdmission = $null
$PreserveInstalledWarden = $false
$AppProbeSeconds = 40
$OutputTimeoutSeconds = 5
$FileActions = @()
$LabsState = $null
$PublicRoot = 'C:\Users\Public\Downloads'
$DataRoot = $null
$BackupRoot = $null
$AllowedDataRoot = 'C:\ProgramData\CilexWatchtower\CodexDeploy'
$Inspection = $null
$JobId = [guid]::NewGuid().ToString('N')
$StartedAt = (Get-Date).ToString('o')
$Phase = 'PRECHECK'
$Outcome = 'failed'
$ExitCode = 4
$Reason = ''
$TaskTouched = $false
$WallTouched = $false
$BackupReady = $false
$OriginalEnabled = $null
$BackupDir = $null
$ProbeDir = $null
$FinalApp = $null
$VideoBaseline = $null
$VideoHealth = $null
$VideoLogPath = ''
$LockHandle = $null
$ExpectedFiles = @()
$BackupFiles = @()
$ProbeProcesses = @()
$CommonModule = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\StationDeployment.psm1'))


function Fail([string]$Code) { throw [InvalidOperationException]::new($Code) }
function Same-Path([string]$A, [string]$B) {
    if (-not $A -or -not $B) { return $false }
    return [string]::Equals([IO.Path]::GetFullPath($A).TrimEnd('\'), [IO.Path]::GetFullPath($B).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}
function Full-Path([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')) { Fail 'PATH_MUST_BE_LOCAL_ABSOLUTE' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) { return $full.TrimEnd('\') }
    return $full
}
function Within([string]$Path, [string]$Root) {
    $p = Full-Path $Path
    $r = (Full-Path $Root) + '\'
    return $p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)
}
function No-Reparse-Parents([string]$Path) {
    $p = Full-Path $Path
    while ($p) {
        if (Test-Path -LiteralPath $p) {
            $item = Get-Item -LiteralPath $p -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail 'REPARSE_PATH_REFUSED' }
        }
        $parent = Split-Path -Path $p -Parent
        if (-not $parent -or (Same-Path $parent $p)) { break }
        $p = $parent
    }
}
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }
function Require-Hash([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail 'REQUIRED_FILE_MISSING' }
    if ((Hash $Path) -ne $Expected) { Fail 'FILE_HASH_MISMATCH' }
}
function App-Version([string]$Path) {
    $v = [version](Get-Item -LiteralPath $Path).VersionInfo.FileVersion
    return ('{0}.{1}.{2}.{3}' -f $v.Major,$v.Minor,[Math]::Max(0,$v.Build),[Math]::Max(0,$v.Revision))
}
function Owner-Sid($Process) {
    $r = Invoke-CimMethod -InputObject $Process -MethodName GetOwnerSid
    if ($r.ReturnValue -ne 0 -or -not $r.Sid) { Fail 'PROCESS_OWNER_UNAVAILABLE' }
    return [string]$r.Sid
}
function All-Wall-Processes {
    return @(Get-CimInstance Win32_Process -Filter "Name='watchtower.exe' OR Name='warden.exe'")
}
function Scoped-Processes([string[]]$Paths, [int]$Session) {
    return @(All-Wall-Processes | Where-Object {
        $p = $_
        $p.SessionId -eq $Session -and @($Paths | Where-Object { Same-Path $_ $p.ExecutablePath }).Count -gt 0
    })
}
function Stop-Scoped([string[]]$Paths, [int]$Session) {
    # Open a verified process handle, so PID reuse cannot redirect the stop.
    $ownerExpected = if ($Session -eq 0) { 'S-1-5-18' } else { $ExpectedUserSid }
    for ($round=0; $round -lt 4; $round++) {
        $rows = @(Scoped-Processes $Paths $Session)
        if ($rows.Count -eq 0) { return }
        $parents = @($rows | ForEach-Object { [int]$_.ParentProcessId })
        $leaves = @($rows | Where-Object { $parents -notcontains [int]$_.ProcessId })
        if ($leaves.Count -eq 0) { Fail 'PROCESS_GRAPH_AMBIGUOUS' }
        foreach ($p in $leaves) {
            $current = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $p.ProcessId) -ErrorAction SilentlyContinue
            if (-not $current) { continue }
            if ($current.SessionId -ne $Session -or $current.Name -ne $p.Name -or -not (Same-Path $current.ExecutablePath $p.ExecutablePath) -or $current.CreationDate -ne $p.CreationDate -or (Owner-Sid $current) -ne $ownerExpected) { Fail 'PROCESS_IDENTITY_CHANGED' }
            $handle = $null
            try {
                $handle = [Diagnostics.Process]::GetProcessById([int]$current.ProcessId)
                $null = $handle.Handle
                if ($handle.HasExited) { continue }
                if ([Math]::Abs($handle.StartTime.ToUniversalTime().Ticks - $current.CreationDate.ToUniversalTime().Ticks) -gt 10) { Fail 'PROCESS_ID_REUSED_BEFORE_STOP' }
                $handle.Kill()
                if (-not $handle.WaitForExit(15000)) { Fail 'VERIFIED_PROCESS_DID_NOT_EXIT' }
            } finally { if ($handle) { $handle.Dispose() } }
        }
        Start-Sleep -Milliseconds 500
    }
    if (@(Scoped-Processes $Paths $Session).Count -gt 0) { Fail 'SCOPED_STOP_INCOMPLETE' }
}
function Validate-Interactive-User {
    if ([CodexOfficeNative]::WTSGetActiveConsoleSessionId() -ne $ExpectedSessionId) { Fail 'EXPECTED_CONSOLE_SESSION_NOT_ACTIVE' }
    $explorers = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.SessionId -eq $ExpectedSessionId })
    if (@($explorers | Where-Object { (Owner-Sid $_) -eq $ExpectedUserSid }).Count -eq 0) { Fail 'EXPECTED_USER_NOT_INTERACTIVE' }
}
function Safe-Reason($ErrorRecord) {
    $m = [string]$ErrorRecord.Exception.Message
    if ($m -match '^[A-Z0-9_]{3,100}$') { return $m }
    return ($Phase + '_' + $ErrorRecord.Exception.GetType().Name)
}
function Run-Isolated([string]$Exe, [string]$Arguments, [int]$Seconds, [bool]$MustExit) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = Split-Path -Path $Exe -Parent
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($name in @($psi.EnvironmentVariables.Keys)) {
        if ([string]$name -match '(?i)^WT_|^QT_|^QML_|^PYTHONHOME$|^PYTHONPATH$|TOKEN|PASSWORD|SECRET|CREDENTIAL|AUTHORIZATION|API.?KEY|BEARER|PASSWD') { $psi.EnvironmentVariables.Remove($name) }
    }
    $psi.EnvironmentVariables['USERPROFILE'] = Join-Path $ProbeDir 'home'
    $psi.EnvironmentVariables['HOME'] = Join-Path $ProbeDir 'home'
    $psi.EnvironmentVariables['APPDATA'] = Join-Path $ProbeDir 'home\AppData\Roaming'
    $psi.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $ProbeDir 'home\AppData\Local'
    $psi.EnvironmentVariables['TEMP'] = Join-Path $ProbeDir 'tmp'
    $psi.EnvironmentVariables['TMP'] = Join-Path $ProbeDir 'tmp'
    $psi.EnvironmentVariables['WT_FLIGHTREC_DIR'] = Join-Path $ProbeDir 'app-data\flightrec'
    $psi.EnvironmentVariables['WT_WARDEN_WARDEN_DIR'] = Join-Path $ProbeDir 'warden-data'
    $psi.EnvironmentVariables['WT_WARDEN_DATA_DIR'] = Join-Path $ProbeDir 'app-data'
    $psi.EnvironmentVariables['WT_WARDEN_BACKEND_URL'] = ''
    $psi.EnvironmentVariables['WT_NO_SCHEME_REG'] = '1'
    $psi.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        if (-not $proc.Start()) { Fail 'PROBE_CREATEPROCESS_FAILED' }
        $script:ProbeProcesses += [pscustomobject]@{Path=$Exe;Pid=$proc.Id}
        $outRead = $proc.StandardOutput.ReadToEndAsync()
        $errRead = $proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit($Seconds * 1000)
        if (-not $exited) {
            Stop-Scoped @($Exe) 0
            if (-not $proc.WaitForExit(5000)) { Fail 'PROBE_PROCESS_DID_NOT_EXIT' }
            if ($MustExit) { Fail 'WARDEN_STATUS_PROBE_TIMEOUT' }
        }
        if (-not $outRead.Wait($OutputTimeoutSeconds * 1000) -or -not $errRead.Wait($OutputTimeoutSeconds * 1000)) { Fail 'PROBE_OUTPUT_TIMEOUT' }
        return [pscustomobject]@{ExitCode=$proc.ExitCode;Output=$outRead.Result;ExitedEarly=$exited}
    } finally { $proc.Dispose() }
}
function Validate-Staged {
    foreach ($entry in $ExpectedFiles) { Require-Hash $entry.Staged $entry.TargetHash }
    if ((App-Version $ExpectedFiles[0].Staged) -ne $TargetAppVersion) { Fail 'STAGED_APP_VERSION_MISMATCH' }
}
function Windows-Quote([string]$Value) {
    return ('"' + (($Value -replace '(\\*)"','$1$1\"') -replace '(\\+)$','$1$1') + '"')
}
function Validate-Startup-Record($Record) {
    foreach ($name in @('Passed','NativeSettingsIsolated','Alive','SecondChanceFaults','ProcessStartError','SHA256')) {
        if ($null -eq $Record.PSObject.Properties[$name]) { Fail 'STARTUP_MONITOR_RESULT_FIELD_MISSING' }
    }
    if ($Record.Passed -isnot [bool] -or -not $Record.Passed -or $Record.NativeSettingsIsolated -isnot [bool] -or -not $Record.NativeSettingsIsolated -or $Record.Alive -isnot [bool] -or -not $Record.Alive -or [int]$Record.SecondChanceFaults -ne 0 -or $Record.ProcessStartError -or [string]$Record.SHA256 -ne $TargetAppHash) { Fail 'STARTUP_MONITOR_DID_NOT_PROVE_ISOLATED_STARTUP' }
    return [pscustomobject]@{Passed=$true;NativeSettingsIsolated=$true;Alive=$true;SecondChanceFaults=0;ProcessStartError=$null;SHA256=[string]$Record.SHA256}
}
function Run-Startup-Monitor([string]$Exe) {
    Require-Hash $StartupMonitor $StartupMonitorHash
    Require-Hash $Exe $TargetAppHash
    $recordPath = Join-Path $ProbeDir 'startup-result.json'
    if (Test-Path -LiteralPath $recordPath) { Fail 'STARTUP_MONITOR_RESULT_ALREADY_EXISTS' }
    $probeHome = Join-Path $ProbeDir 'app-startup-home'
    $flightrec = Join-Path $ProbeDir 'app-startup-flightrec'
    $pythonHome = Join-Path $ProbeDir 'home'
    $arguments = @('-B','-X','utf8',$StartupMonitor,'--exe',$Exe,'--home',$probeHome,'--flightrec',$flightrec,'--result',$recordPath,'--seconds','40')
    if ($TargetPdbHash) { $arguments += @('--symbols',(Split-Path $Exe -Parent)) }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $StartupPython
    $psi.Arguments = (($arguments | ForEach-Object { Windows-Quote ([string]$_) }) -join ' ')
    $psi.WorkingDirectory = $ProbeDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($name in @($psi.EnvironmentVariables.Keys)) {
        if ([string]$name -match '(?i)^WT_|^QT_|^QML_|^PYTHONHOME$|^PYTHONPATH$|TOKEN|PASSWORD|SECRET|CREDENTIAL|AUTHORIZATION|API.?KEY|BEARER|PASSWD') { $psi.EnvironmentVariables.Remove($name) }
    }
    $psi.EnvironmentVariables['USERPROFILE'] = $pythonHome
    $psi.EnvironmentVariables['HOME'] = $pythonHome
    $psi.EnvironmentVariables['APPDATA'] = Join-Path $pythonHome 'AppData\Roaming'
    $psi.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $pythonHome 'AppData\Local'
    $psi.EnvironmentVariables['TEMP'] = Join-Path $ProbeDir 'tmp'
    $psi.EnvironmentVariables['TMP'] = Join-Path $ProbeDir 'tmp'
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    # Cleanup is bounded to this invocation's private probe path in session zero.
    $script:ProbeProcesses += [pscustomobject]@{Path=$Exe;Pid=$null}
    try {
        if (-not $proc.Start()) { Fail 'STARTUP_MONITOR_CREATEPROCESS_FAILED' }
        $outRead = $proc.StandardOutput.ReadToEndAsync()
        $errRead = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(65000)) {
            Stop-Scoped @($Exe) 0
            if (-not $proc.HasExited) { $proc.Kill(); $null=$proc.WaitForExit(5000) }
            Fail 'STARTUP_MONITOR_TIMEOUT'
        }
        if (-not $outRead.Wait(5000) -or -not $errRead.Wait(5000)) { Fail 'STARTUP_MONITOR_OUTPUT_TIMEOUT' }
        # Arbitrary stdout/stderr are discarded; only the owned result is parsed.
        if ($proc.ExitCode -ne 0) { Fail 'STARTUP_MONITOR_REFUSED_APP' }
        Require-Hash $Exe $TargetAppHash
        Require-Hash $StartupMonitor $StartupMonitorHash
        $record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return (Validate-Startup-Record $record)
    } finally { $proc.Dispose() }
}
function Candidate([string]$AppHashExpected) {
    $rows = @(All-Wall-Processes)
    $apps = @($rows | Where-Object { $_.Name -eq 'watchtower.exe' -and $_.SessionId -eq $ExpectedSessionId })
    if ($apps.Count -gt 1) { Fail 'MULTIPLE_INTERACTIVE_WALLS' }
    if ($apps.Count -eq 0) { return $null }
    $app = $apps[0]
    if (-not (Same-Path $app.ExecutablePath $ExpectedFiles[0].Installed) -or (Owner-Sid $app) -ne $ExpectedUserSid) { Fail 'APP_IDENTITY_MISMATCH' }
    $wardens = @($rows | Where-Object { $_.Name -eq 'warden.exe' -and $_.SessionId -eq $ExpectedSessionId })
    if (@($wardens | Where-Object { -not (Same-Path $_.ExecutablePath $ExpectedFiles[1].Installed) }).Count -gt 0) { Fail 'UNEXPECTED_INTERACTIVE_WARDEN' }
    $supervisor = @($wardens | Where-Object { $_.ProcessId -eq $app.ParentProcessId })
    if ($supervisor.Count -ne 1) { Fail 'APP_NOT_PARENTED_BY_EXPECTED_WARDEN' }
    if ($wardens.Count -lt 1 -or $wardens.Count -gt 2) { Fail 'WARDEN_PROCESS_COUNT_MISMATCH' }
    if ($wardens.Count -eq 2) {
        $other = @($wardens | Where-Object { $_.ProcessId -ne $supervisor[0].ProcessId })[0]
        if ($supervisor[0].ParentProcessId -ne $other.ProcessId) { Fail 'WARDEN_BOOTLOADER_GRAPH_MISMATCH' }
    }
    foreach ($w in $wardens) { if ((Owner-Sid $w) -ne $ExpectedUserSid) { Fail 'WARDEN_OWNER_MISMATCH' } }
    Require-Hash $ExpectedFiles[0].Installed $AppHashExpected
    return [pscustomobject]@{Pid=[int]$app.ProcessId;ParentPid=[int]$app.ParentProcessId;Created=$app.CreationDate;WardenProcessCount=$wardens.Count}
}
function Wait-Stable([string]$AppHashExpected) {
    $first = $null
    for ($i=0; $i -lt 9; $i++) {
        Start-Sleep -Seconds 5
        Validate-Interactive-User
        $first = Candidate $AppHashExpected
        if ($first) { break }
    }
    if (-not $first) { Fail 'NO_SUPERVISED_APP_WITHIN_45_SECONDS' }
    for ($i=0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 5
        Validate-Interactive-User
        $current = Candidate $AppHashExpected
        if (-not $current -or $current.Pid -ne $first.Pid -or $current.ParentPid -ne $first.ParentPid -or $current.Created -ne $first.Created) { Fail 'APP_OR_SUPERVISOR_CHANGED_DURING_150_SECONDS' }
    }
    $after=Get-StationVideoSnapshot -LogPath $VideoLogPath -ProcessId $first.Pid -CreatedUTC $first.Created.ToUniversalTime()
    $script:VideoHealth=Assert-StationVideoProgress -Before $VideoBaseline -After $after
    return $first
}
function Start-User-Task {
    Validate-Interactive-User
    Enable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath | Out-Null
    Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
}
function Restore-Backups {
    foreach ($entry in $BackupFiles) {
        $action = Restore-StationFile -Backup $entry.Backup -Destination $entry.Installed -SHA256 $entry.OldHash -Existed ([bool]$entry.Existed) -InstalledSHA256 $entry.InstalledSHA256
        $script:FileActions += $action
    }
}
function Stored-Task-Sid($Task) {
    $xml = [xml](Export-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath)
    $ids = @($xml.Task.Principals.Principal | ForEach-Object { [string]$_.UserId })
    if ($ids.Count -ne 1 -or -not $ids[0]) { Fail 'TASK_PRINCIPAL_XML_AMBIGUOUS' }
    if ($ids[0] -match '^S-1-') { return $ids[0] }
    return ([Security.Principal.NTAccount]::new($ids[0])).Translate([Security.Principal.SecurityIdentifier]).Value
}
function Get-Labs-State([string]$Profile, [string]$OwnerSid, [int]$Session) {
    $root = Join-Path $Profile 'AppData\Local\watchtower-labs'
    $workers = @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" | Where-Object {
        $_.SessionId -eq $Session -and $_.CommandLine -match '(?i)(?:^|\s)(?:"(?:[^"\r\n]*[\\/])?run_worker\.py"|(?:[^\s"\r\n]*[\\/])?run_worker\.py)(?=\s|$)' -and $_.CommandLine -match '(?:^|\s)--loop(?:\s|$)'
    })
    $guards = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" | Where-Object {
        $_.SessionId -eq $Session -and $_.CommandLine -match '(?i)(?:^|\s)-File\s+(?:"(?:[^"\r\n]*[\\/])?guard3\.ps1"|(?:[^\s"\r\n]*[\\/])?guard3\.ps1)(?=\s|$)' -and $_.CommandLine -match '(?i)(?:^|\s)-StartWorker(?=:|\s|$)'
    })
    $startupTasks = @()
    foreach ($task in @(Get-ScheduledTask -TaskPath '\')) {
        if (-not $task.Settings.Enabled) { continue }
        $startsLabs = $task.TaskName -match '(?i)^wt-labs'
        foreach ($action in @($task.Actions)) {
            if ([string]$action.Execute -match '(?i)(?:^|[\\/])(?:guard3|start-labs[^\\/]*)\.(?:ps1|vbs|cmd)$' -or [string]$action.Arguments -match '(?i)(?:^|[\\/])(?:guard3|start-labs[^\\/\s"]*)\.(?:ps1|vbs|cmd)(?=["\s]|$)') { $startsLabs=$true }
        }
        if ($startsLabs -and (Stored-Task-Sid $task) -eq $OwnerSid) { $startupTasks += [string]$task.TaskName }
    }
    $record = [ordered]@{workerCount=$workers.Count;workerPids=@($workers | ForEach-Object { [int]$_.ProcessId });guardPids=@($guards | ForEach-Object { [int]$_.ProcessId });enabledStartupTasks=$startupTasks;statusPath=(Join-Path $root 'status.json');state=$null;serverMode=$null;units=$null;hasCurrentUnit=$null;hasHold=$false;statusAgeSeconds=$null;safeToUpdate=$false;reason='LABS_STATE_UNVERIFIED'}
    $canRespawn = $guards.Count -gt 0 -or $startupTasks.Count -gt 0
    if ($workers.Count -eq 0 -and -not $canRespawn) { $record.safeToUpdate=$true; $record.reason='NO_LABS_WORKER_OR_RESTART_ACTOR'; return [pscustomobject]$record }
    if ($workers.Count -gt 1) { $record.reason='MULTIPLE_LABS_WORKERS'; return [pscustomobject]$record }
    if ($workers.Count -eq 1 -and (Owner-Sid $workers[0]) -ne $OwnerSid) { $record.reason='LABS_WORKER_OWNER_MISMATCH'; return [pscustomobject]$record }
    try {
        $status = Get-Content -LiteralPath $record.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $status.PSObject.Properties['units'] -or $null -eq $status.PSObject.Properties['current']) { Fail 'LABS_STATUS_FIELDS_MISSING' }
        $at = [DateTime]::Parse([string]$status.updated_at,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        if ($at.Kind -eq [DateTimeKind]::Unspecified) { $at=[DateTime]::SpecifyKind($at,[DateTimeKind]::Utc) }
        $age = ([DateTime]::UtcNow - $at.ToUniversalTime()).TotalSeconds
        $record.statusAgeSeconds=[Math]::Round($age,1)
        if ($age -lt -10 -or $age -gt 60 -or ($workers.Count -eq 1 -and [int]$status.pid -ne [int]$workers[0].ProcessId)) { Fail 'LABS_STATUS_STALE_OR_WRONG_PID' }
        $holdCanBeReleasedByGuard = $false
        $control = Join-Path $root 'control.json'
        if (Test-Path -LiteralPath $control -PathType Leaf) {
            $doc = Get-Content -LiteralPath $control -Raw -Encoding UTF8 | ConvertFrom-Json
            $holdProperty = $doc.PSObject.Properties['hold']
            if ($holdProperty -and $holdProperty.Value -and $holdProperty.Value.why -is [string] -and $holdProperty.Value.why.Length -gt 0) {
                $record.hasHold=$true
                $holdCanBeReleasedByGuard = $guards.Count -gt 0 -and [string]$holdProperty.Value.by -eq 'wall-guard'
            }
        }
        $record.state=[string]$status.state
        $record.serverMode=[string]$status.server_mode
        $record.units=if ($null -eq $status.units) { 0 } else { @($status.units).Count }
        $record.hasCurrentUnit=($null -ne $status.current)
        $barrier = $record.serverMode -in @('off','stopped','paused') -or ($record.hasHold -and $record.state -eq 'held' -and -not $holdCanBeReleasedByGuard)
        if ($record.units -eq 0 -and -not $record.hasCurrentUnit -and $barrier) { $record.safeToUpdate=$true; $record.reason='LABS_DRAINED_AND_CLAIMS_BLOCKED' }
        else { $record.reason='LABS_ADMIN_PAUSE_AND_DRAIN_REQUIRED' }
    } catch { $record.reason='LABS_STATUS_UNVERIFIED' }
    return [pscustomobject]$record
}
function Assert-Labs-Safe([string]$Profile) {
    $script:LabsState = Get-Labs-State $Profile $ExpectedUserSid $ExpectedSessionId
    if (-not $script:LabsState.safeToUpdate) { Fail 'LABS_ADMIN_PAUSE_AND_DRAIN_REQUIRED' }
}
function Inspect-State {
    # This branch reads live state only. It writes only the requested result record.
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
    $sid = Stored-Task-Sid $task
    $profiles = @(Get-CimInstance Win32_UserProfile -Filter ("SID='{0}'" -f $sid))
    if ($profiles.Count -ne 1 -or -not $profiles[0].LocalPath) { Fail 'TASK_USER_PROFILE_UNAVAILABLE' }
    $profile = [string]$profiles[0].LocalPath
    $installed = if ($InstallPath) { Full-Path $InstallPath } else { Join-Path $profile 'AppData\Local\Programs\Cilex Watchtower' }
    $installedPython = Join-Path $profile 'AppData\Local\Programs\Python\Python312\python.exe'
    $actions = @($task.Actions | ForEach-Object {
        $argument = [string]$_.Arguments
        [pscustomobject]@{execute=$_.Execute;arguments=if (-not $argument -or $argument.Trim() -eq 'run') { $argument } else { '[omitted]' };workingDirectory=$_.WorkingDirectory}
    })
    $processes = @()
    $pythonPath = Join-Path $installed 'warden\warden.py'
    $rows = @(Get-CimInstance Win32_Process -Filter "Name='watchtower.exe' OR Name='warden.exe' OR Name='python.exe' OR Name='pythonw.exe'")
    foreach ($p in $rows) {
        if ($p.Name -in @('python.exe','pythonw.exe') -and -not ([string]$p.CommandLine).Contains($pythonPath)) { continue }
        $owner = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid
        $processes += [pscustomobject]@{pid=[int]$p.ProcessId;parentPid=[int]$p.ParentProcessId;name=$p.Name;path=$p.ExecutablePath;session=[int]$p.SessionId;ownerSid=if ($owner.ReturnValue -eq 0) { $owner.Sid } else { $null };ownerResult=$owner.ReturnValue;createdUtc=$p.CreationDate.ToUniversalTime().ToString('o')}
    }
    $files = @()
    foreach ($relative in @('watchtower.exe','warden\warden.exe','warden\warden.py')) {
        $path = Join-Path $installed $relative
        $present = Test-Path -LiteralPath $path -PathType Leaf
        $files += [pscustomobject]@{path=$path;present=$present;sha256=if ($present) { Hash $path } else { $null };version=if ($present -and $relative -eq 'watchtower.exe') { App-Version $path } else { $null }}
    }
    $ownedWalls = @($processes | Where-Object { $_.name -eq 'watchtower.exe' -and $_.ownerSid -eq $sid -and $_.session -gt 0 })
    $labs = if ($ownedWalls.Count -eq 1) { Get-Labs-State $profile $sid $ownedWalls[0].session } else { [pscustomobject]@{safeToUpdate=$false;reason='DESKTOP_SESSION_UNVERIFIED'} }
    return [pscustomobject]@{capturedUtc=[DateTime]::UtcNow.ToString('o');host=$env:COMPUTERNAME;profilePath=$profile;installPath=$installed;pythonPath=$installedPython;pythonPresent=(Test-Path -LiteralPath $installedPython -PathType Leaf);task=[pscustomobject]@{name=$task.TaskName;path=$task.TaskPath;state=[string]$task.State;enabled=[bool]$task.Settings.Enabled;storedOwnerSid=$sid;logonType=[string]$task.Principal.LogonType;runLevel=[string]$task.Principal.RunLevel;actions=$actions};processes=$processes;files=$files;labs=$labs;liveStateChanged=$false}
}

function Read-Deployment-Manifest {
    if (-not $ManifestPath) { Fail 'UPDATE_REQUIRES_MANIFEST' }
    $path = Full-Path $ManifestPath
    if (-not (Within $path $PublicRoot)) { Fail 'MANIFEST_OUTSIDE_PUBLIC_DOWNLOADS' }
    No-Reparse-Parents $path
    $doc = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($name in @('Commit','AppVersion','AppPath','AppSHA256','PdbPath','PdbSHA256','WardenSourcePath','WardenSourceSHA256','WardenExePath','WardenExeSHA256','WardenVersion','InstallPath','ExpectedHost','ExpectedSID','ExpectedSession','WardenTask','StagePath','OffscreenPath','OffscreenSHA256','PreserveInstalledWarden','WardenSourceMatchRecord','PythonPath','StartupMonitorPath','StartupMonitorSHA256')) {
        if ($null -eq $doc.PSObject.Properties[$name]) { Fail 'MANIFEST_FIELD_MISSING' }
    }
    if ([string]$doc.ExpectedHost -ne $ExpectedHost -or [string]$doc.ExpectedSID -notmatch '^S-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+$' -or ($doc.ExpectedSession -isnot [int] -and $doc.ExpectedSession -isnot [long]) -or [int]$doc.ExpectedSession -lt 1 -or [int]$doc.ExpectedSession -gt 65535) { Fail 'MANIFEST_IDENTITY_INVALID' }
    if ([string]$doc.AppVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' -or [string]$doc.WardenVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { Fail 'MANIFEST_VERSION_INVALID' }
    foreach ($name in @('AppSHA256','WardenSourceSHA256','WardenExeSHA256','OffscreenSHA256','StartupMonitorSHA256')) {
        if ([string]$doc.$name -notmatch '^[0-9A-Fa-f]{64}$') { Fail 'MANIFEST_HASH_INVALID' }
    }
    if ([string]$doc.WardenTask -notmatch '^[A-Za-z0-9_. -]+$' -or $doc.PreserveInstalledWarden -isnot [bool]) { Fail 'MANIFEST_TASK_OR_PRESERVATION_FLAG_INVALID' }
    if ($TaskNameExplicit -and $TaskName -ne [string]$doc.WardenTask) { Fail 'MANIFEST_TASK_NAME_MISMATCH' }
    if ([string]$doc.PdbPath) {
        if ([string]$doc.PdbSHA256 -notmatch '^[0-9A-Fa-f]{64}$') { Fail 'MANIFEST_PDB_HASH_INVALID' }
    } elseif ([string]$doc.PdbSHA256) { Fail 'PDB_HASH_WITHOUT_FILE' }
    $stage = Full-Path ([string]$doc.StagePath)
    if (-not (Within $stage $PublicRoot)) { Fail 'MANIFEST_STAGE_BOUNDARY_INVALID' }
    No-Reparse-Parents $stage
    foreach ($entry in @(@('AppPath','watchtower.exe'),@('WardenSourcePath','warden.py'),@('OffscreenPath','qoffscreen.dll'))) {
        $file = Full-Path ([string]$doc.($entry[0]))
        if (-not (Within $file $stage) -or [IO.Path]::GetFileName($file) -ne $entry[1]) { Fail 'MANIFEST_ARTIFACT_PATH_INVALID' }
        No-Reparse-Parents $file
    }
    if ([string]$doc.PdbPath) {
        $file = Full-Path ([string]$doc.PdbPath)
        if (-not (Within $file $stage) -or [IO.Path]::GetFileName($file) -ne 'watchtower.pdb') { Fail 'MANIFEST_PDB_PATH_INVALID' }
        No-Reparse-Parents $file
    }
    $exe = Full-Path ([string]$doc.WardenExePath)
    if ([IO.Path]::GetFileName($exe) -ne 'warden.exe') { Fail 'MANIFEST_WARDEN_PATH_INVALID' }
    No-Reparse-Parents $exe
    if ($doc.PreserveInstalledWarden) {
        $proof = $doc.WardenSourceMatchRecord
        if ($null -eq $proof -or $proof.matches -isnot [bool] -or -not $proof.matches -or [string]$proof.warden_version -ne [string]$doc.WardenVersion -or [string]$proof.exe_sha256 -ne [string]$doc.WardenExeSHA256 -or [string]$proof.source_sha256 -ne [string]$doc.WardenSourceSHA256) { Fail 'PRESERVED_WARDEN_PROOF_NOT_BOUND_TO_ARTIFACTS' }
        if (-not (Same-Path $exe (Join-Path ([string]$doc.InstallPath) 'warden\warden.exe'))) { Fail 'PRESERVED_WARDEN_PATH_NOT_INSTALLED_EXECUTABLE' }
    } elseif (-not (Within $exe $stage)) { Fail 'MANIFEST_WARDEN_STAGE_BOUNDARY_INVALID' }
    $monitor = Full-Path ([string]$doc.StartupMonitorPath)
    if (-not (Same-Path $monitor (Join-Path $PSScriptRoot 'isolated-startup.py'))) { Fail 'STARTUP_MONITOR_NOT_BESIDE_OFFICE_HELPER' }
    No-Reparse-Parents $monitor
    $python = Full-Path ([string]$doc.PythonPath)
    if ([IO.Path]::GetFileName($python) -ne 'python.exe') { Fail 'STARTUP_PYTHON_PATH_INVALID' }
    No-Reparse-Parents $python
    return $doc
}

try {
    if ($env:COMPUTERNAME -ne $ExpectedHost) { Fail 'HOST_BINDING_MISMATCH' }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { Fail 'SYSTEM_IDENTITY_REQUIRED' }
    if ((Get-Process -Id $PID).SessionId -ne 0) { Fail 'SESSION_ZERO_REQUIRED' }
    if ($Mode -eq 'Update') {
        Import-Module -Name $CommonModule -DisableNameChecking -ErrorAction Stop
        Import-Module (Join-Path (Split-Path $CommonModule) 'StationVideoHealth.psm1') -DisableNameChecking -ErrorAction Stop
    }
    if ($Mode -eq 'Inspect') {
        $Phase = 'INSPECT'
        $Inspection = Inspect-State
        $Outcome = 'inspected'
        $Reason = 'LIVE_STATE_RECORDED_WITHOUT_APP_OR_TASK_CHANGES'
        $ExitCode = 0
    } else {
    $Manifest = Read-Deployment-Manifest
    $ExpectedUserSid = [string]$Manifest.ExpectedSID
    $ExpectedSessionId = [int]$Manifest.ExpectedSession
    $InstallPath = Full-Path ([string]$Manifest.InstallPath)
    $TaskName = [string]$Manifest.WardenTask
    $StagePath = [string]$Manifest.StagePath
    $TargetAppVersion = [string]$Manifest.AppVersion
    $TargetAppHash = [string]$Manifest.AppSHA256
    $TargetWardenVersion = [string]$Manifest.WardenVersion
    $TargetWardenHash = [string]$Manifest.WardenExeSHA256
    $TargetSourceHash = [string]$Manifest.WardenSourceSHA256
    $TargetPdbHash = [string]$Manifest.PdbSHA256
    $TargetOffscreenHash = [string]$Manifest.OffscreenSHA256
    $PreserveInstalledWarden = [bool]$Manifest.PreserveInstalledWarden
    $StartupPython = Full-Path ([string]$Manifest.PythonPath)
    $StartupMonitor = Full-Path ([string]$Manifest.StartupMonitorPath)
    $StartupMonitorHash = [string]$Manifest.StartupMonitorSHA256
    $StagePath = Full-Path $StagePath
    $ResultPath = Full-Path $ResultPath
    if (-not (Within $StagePath $PublicRoot) -or -not (Within $ResultPath $PublicRoot)) { Fail 'PUBLIC_DOWNLOADS_BOUNDARY_REQUIRED' }
    No-Reparse-Parents $StagePath
    No-Reparse-Parents $ResultPath
    if (-not (Test-Path -LiteralPath $StagePath -PathType Container)) { Fail 'STAGE_DIRECTORY_MISSING' }
    $WorkRoot = Full-Path $WorkRoot
    if (-not (Same-Path $WorkRoot $AllowedDataRoot) -and -not (Within $WorkRoot $AllowedDataRoot)) { Fail 'DEPLOY_WORK_BOUNDARY_REQUIRED' }
    No-Reparse-Parents $WorkRoot
    New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    $DataRoot = Join-Path $WorkRoot ('job-' + $JobId)
    $BackupRoot = Join-Path $DataRoot 'backups'
    No-Reparse-Parents $DataRoot
    No-Reparse-Parents $BackupRoot
    New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    No-Reparse-Parents $DataRoot
    No-Reparse-Parents (Join-Path $AllowedDataRoot 'office-update.lock')
    try { $LockHandle = [IO.File]::Open((Join-Path $AllowedDataRoot 'office-update.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } catch { Fail 'ANOTHER_OFFICE_DEPLOYMENT_RUNNING' }
    Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class CodexOfficeNative { [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId(); }'
    Validate-Interactive-User
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
    $OriginalEnabled = [bool]$task.Settings.Enabled
    if ([string]$task.Principal.LogonType -ne 'Interactive') { Fail 'TASK_MUST_USE_INTERACTIVE_LOGON' }
    # Export supplies the stored principal SID even when the display name still
    # contains the machine's historical hostname. Never rewrite the task.
    $taskSid = Stored-Task-Sid $task
    if ($taskSid -ne $ExpectedUserSid) { Fail 'TASK_PRINCIPAL_MISMATCH' }
    if (-not $task.Settings.AllowDemandStart) { Fail 'TASK_DEMAND_START_DISABLED' }
    $profiles = @(Get-CimInstance Win32_UserProfile -Filter ("SID='{0}'" -f $ExpectedUserSid))
    if ($profiles.Count -ne 1 -or -not $profiles[0].LocalPath) { Fail 'EXPECTED_USER_PROFILE_UNAVAILABLE' }
    if (-not (Same-Path $StartupPython (Join-Path $profiles[0].LocalPath 'AppData\Local\Programs\Python\Python312\python.exe')) -or -not (Test-Path -LiteralPath $StartupPython -PathType Leaf)) { Fail 'STARTUP_PYTHON_NOT_IN_EXPECTED_PROFILE' }
    Require-Hash $StartupMonitor $StartupMonitorHash
    $profileInstall = Join-Path $profiles[0].LocalPath 'AppData\Local\Programs\Cilex Watchtower'
    $runningApps = @(All-Wall-Processes | Where-Object { $_.Name -eq 'watchtower.exe' -and $_.SessionId -ne 0 })
    if ($runningApps.Count -gt 1) { Fail 'INITIAL_APP_DISCOVERY_AMBIGUOUS' }
    if ($runningApps.Count -eq 1) {
        $app = $runningApps[0]
        if ($app.SessionId -ne $ExpectedSessionId -or (Owner-Sid $app) -ne $ExpectedUserSid) { Fail 'INITIAL_APP_USER_SESSION_MISMATCH' }
        $discoveredInstall = Split-Path -Path $app.ExecutablePath -Parent
    } else {
        $installs = @(Get-ChildItem -LiteralPath 'C:\Users' -Directory | ForEach-Object { Join-Path $_.FullName 'AppData\Local\Programs\Cilex Watchtower' } | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'watchtower.exe') -PathType Leaf })
        if ($installs.Count -ne 1) { Fail 'INSTALL_DISCOVERY_AMBIGUOUS' }
        $discoveredInstall = $installs[0]
    }
    if ($InstallPath -and -not (Same-Path $InstallPath $discoveredInstall)) { Fail 'EXPLICIT_INSTALL_BINDING_MISMATCH' }
    $InstallPath = Full-Path $discoveredInstall
    if (-not (Same-Path $InstallPath $profileInstall)) { Fail 'INSTALL_NOT_IN_TASK_PRINCIPAL_PROFILE' }
    No-Reparse-Parents $InstallPath
    $appPath = Join-Path $InstallPath 'watchtower.exe'
    $wardenPath = Join-Path $InstallPath 'warden\warden.exe'
    $sourcePath = Join-Path $InstallPath 'warden\warden.py'
    $actions = @($task.Actions)
    if ($actions.Count -ne 1 -or -not (Same-Path ([string]$actions[0].Execute).Trim('"') $wardenPath)) { Fail 'TASK_ACTION_NOT_EXACT_PACKAGED_WARDEN' }
    if ([string]$actions[0].Arguments -and ([string]$actions[0].Arguments).Trim() -ne 'run') { Fail 'TASK_ARGUMENTS_NOT_SIMPLE_WARDEN_RUN' }
    $ExpectedFiles = @(
        [pscustomobject]@{Name='watchtower.exe';Installed=$appPath;Staged=(Full-Path ([string]$Manifest.AppPath));TargetHash=$TargetAppHash},
        [pscustomobject]@{Name='warden.exe';Installed=$wardenPath;Staged=(Full-Path ([string]$Manifest.WardenExePath));TargetHash=$TargetWardenHash},
        [pscustomobject]@{Name='warden.py';Installed=$sourcePath;Staged=(Full-Path ([string]$Manifest.WardenSourcePath));TargetHash=$TargetSourceHash}
    )
    foreach ($entry in $ExpectedFiles) { No-Reparse-Parents $entry.Installed; No-Reparse-Parents $entry.Staged }
    $pdbStage = if ([string]$Manifest.PdbPath) { Full-Path ([string]$Manifest.PdbPath) } else { '' }
    if ($pdbStage -and (Test-Path -LiteralPath $pdbStage -PathType Leaf)) {
        if (-not $TargetPdbHash) { Fail 'STAGED_PDB_REQUIRES_EXPLICIT_HASH' }
        $ExpectedFiles += [pscustomobject]@{Name='watchtower.pdb';Installed=(Join-Path $InstallPath 'watchtower.pdb');Staged=$pdbStage;TargetHash=$TargetPdbHash}
        No-Reparse-Parents $pdbStage
        No-Reparse-Parents (Join-Path $InstallPath 'watchtower.pdb')
    } elseif ($TargetPdbHash) { Fail 'EXPECTED_PDB_NOT_STAGED' }
    $offscreenStage = Full-Path ([string]$Manifest.OffscreenPath)
    No-Reparse-Parents $offscreenStage
    Require-Hash $offscreenStage $TargetOffscreenHash
    Validate-Staged
    $oldAppVersion = App-Version $appPath
    $initialWardens = @(All-Wall-Processes | Where-Object { $_.Name -eq 'warden.exe' -and $_.SessionId -eq $ExpectedSessionId })
    if (@($initialWardens | Where-Object { -not (Same-Path $_.ExecutablePath $wardenPath) -or (Owner-Sid $_) -ne $ExpectedUserSid }).Count -gt 0) { Fail 'UNEXPECTED_INTERACTIVE_WARDEN' }
    $pythonWardens = @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" | Where-Object { $_.SessionId -eq $ExpectedSessionId -and $_.CommandLine -match '(?i)warden\.py' })
    if ($pythonWardens.Count -gt 0) { Fail 'PYTHON_WARDEN_REQUIRES_SEPARATE_REVIEW' }
    Assert-Labs-Safe $profiles[0].LocalPath

    $Phase = 'PROBE'
    if ($runningApps.Count -ne 1) { Fail 'VIDEO_BASELINE_REQUIRES_RUNNING_APP' }
    $VideoLogPath=Join-Path $profiles[0].LocalPath 'AppData\Roaming\Cilex Vision\Watchtower\flightrec\watchtower.log'
    if($Manifest.PSObject.Properties['FlightRecorderPath'] -and [string]$Manifest.FlightRecorderPath){$VideoLogPath=Full-Path ([string]$Manifest.FlightRecorderPath)}
    No-Reparse-Parents $VideoLogPath
    $VideoBaseline=Get-StationVideoSnapshot -LogPath $VideoLogPath -ProcessId $runningApps[0].ProcessId -CreatedUTC $runningApps[0].CreationDate.ToUniversalTime()
    $null=Assert-StationVideoBaseline -Snapshot $VideoBaseline
    if(-not $VideoBaseline.ExpectedVideo){Fail 'NO_ACTIVE_CAMERA_VIDEO_BEFORE_UPDATE'}
    $ProbeDir = Join-Path $DataRoot 'probe'
    New-Item -ItemType Directory -Path $ProbeDir | Out-Null
    foreach ($p in @('home','home\AppData\Local','home\AppData\Roaming','tmp','app-data','warden-data','runtime','warden')) { New-Item -ItemType Directory -Path (Join-Path $ProbeDir $p) -Force | Out-Null }
    $probeApp = Join-Path $ProbeDir 'runtime\watchtower.exe'
    $runtimeExtensions = @('.dll','.rcc','.qm','.pak','.bin','.dat','.qsb','.qml','.js','.qmltypes','.metainfo','.ttf','.otf','.woff','.woff2','.png','.jpg','.jpeg','.svg','.ico','.frag','.vert')
    foreach ($file in @(Get-ChildItem -LiteralPath $InstallPath -Recurse -File)) {
        if ($file.FullName.StartsWith((Join-Path $InstallPath 'warden')+'\',[StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($file.Name -ieq 'qoffscreen.dll') { continue }
        if ($runtimeExtensions -notcontains $file.Extension.ToLowerInvariant() -and $file.Name -ne 'qmldir') { continue }
        No-Reparse-Parents $file.FullName
        $relative = $file.FullName.Substring($InstallPath.Length).TrimStart('\')
        $dest = Join-Path (Join-Path $ProbeDir 'runtime') $relative
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        if ($dest.Length -ge 260) { Fail 'PROBE_RUNTIME_PATH_TOO_LONG' }
        New-Item -ItemType HardLink -Path $dest -Target $file.FullName -ErrorAction Stop | Out-Null
    }
    $probeOffscreen = Join-Path $ProbeDir 'runtime\platforms\qoffscreen.dll'
    New-Item -ItemType Directory -Path (Split-Path $probeOffscreen -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $offscreenStage -Destination $probeOffscreen
    Require-Hash $probeOffscreen $TargetOffscreenHash
    Copy-Item -LiteralPath $ExpectedFiles[0].Staged -Destination $probeApp -Force
    Require-Hash $probeApp $TargetAppHash
    if ($TargetPdbHash) {
        $probePdb = Join-Path $ProbeDir 'runtime\watchtower.pdb'
        Copy-Item -LiteralPath $pdbStage -Destination $probePdb
        Require-Hash $probePdb $TargetPdbHash
    }
    $StartupAdmission = Run-Startup-Monitor $probeApp
    $probeWarden = Join-Path $ProbeDir 'warden\warden.exe'
    Copy-Item -LiteralPath $ExpectedFiles[1].Staged -Destination $probeWarden -Force
    Require-Hash $probeWarden $TargetWardenHash
    $wardenProbe = Run-Isolated $probeWarden 'status' 45 $true
    if ($wardenProbe.ExitCode -ne 0 -or $wardenProbe.Output -notmatch ('(?m)^warden '+[regex]::Escape($TargetWardenVersion)+'\s')) { Fail 'WARDEN_STATUS_VERSION_PROBE_FAILED' }
    Stop-Scoped @($probeApp,$probeWarden) 0

    $Phase = 'BACKUP'
    Validate-Interactive-User
    Validate-Staged
    Assert-Labs-Safe $profiles[0].LocalPath
    $BackupDir = Join-Path $BackupRoot ('backup-' + $JobId)
    New-Item -ItemType Directory -Path $BackupDir | Out-Null
    foreach ($entry in $ExpectedFiles) {
        $existed = Test-Path -LiteralPath $entry.Installed -PathType Leaf
        if (-not $existed -and $entry.Name -notin @('warden.py','watchtower.pdb')) { Fail 'INSTALLED_BINARY_MISSING' }
        $oldHash = if ($existed) { Hash $entry.Installed } else { $null }
        $backup = Join-Path $BackupDir $entry.Name
        if ($existed) { Copy-Item -LiteralPath $entry.Installed -Destination $backup -Force; Require-Hash $backup $oldHash }
        $BackupFiles += [pscustomobject]@{Installed=$entry.Installed;Backup=$backup;Existed=$existed;OldHash=$oldHash;InstalledSHA256=$entry.TargetHash}
    }
    [IO.File]::WriteAllText((Join-Path $BackupDir 'backup-manifest.json'),($BackupFiles | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $BackupReady = $true

    $Phase = 'STOP_AND_SWAP'
    Assert-Labs-Safe $profiles[0].LocalPath
    $latestVideo=Get-StationVideoSnapshot -LogPath $VideoLogPath -ProcessId $runningApps[0].ProcessId -CreatedUTC $runningApps[0].CreationDate.ToUniversalTime()
    $null=Assert-StationVideoBaseline -Snapshot $latestVideo
    if($VideoBaseline.ExpectedVideo -and -not $latestVideo.ExpectedVideo){Fail 'VIDEO_BASELINE_CHANGED_BEFORE_STOP'}
    $TaskTouched = $true
    Disable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath | Out-Null
    $WallTouched = $true
    Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
    Stop-Scoped @($wardenPath) $ExpectedSessionId
    Stop-Scoped @($appPath) $ExpectedSessionId
    Validate-Staged
    foreach ($entry in $ExpectedFiles) {
        $FileActions += (Install-StationFile -Source $entry.Staged -Destination $entry.Installed -SHA256 $entry.TargetHash)
        Require-Hash $entry.Installed $entry.TargetHash
    }
    if ((App-Version $appPath) -ne $TargetAppVersion) { Fail 'INSTALLED_APP_VERSION_MISMATCH' }
    $Phase = 'START_AND_VERIFY'
    Start-User-Task
    $FinalApp = Wait-Stable $TargetAppHash
    foreach ($entry in $ExpectedFiles) { Require-Hash $entry.Installed $entry.TargetHash }
    $Outcome = 'success'
    $Reason = 'EXPECTED_BINARIES_SUPERVISED_STABLE_90_SECONDS'
    $ExitCode = 0
    } # Update
} catch {
    $Reason = Safe-Reason $_
    if ($WallTouched -and $BackupReady) {
        $Phase = 'ROLLBACK'
        try {
            Disable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath | Out-Null
            Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
            Stop-Scoped @($wardenPath) $ExpectedSessionId
            Stop-Scoped @($appPath) $ExpectedSessionId
            Restore-Backups
            Start-User-Task
            $FinalApp = Wait-Stable $BackupFiles[0].OldHash
            foreach ($entry in $BackupFiles) { if ($entry.Existed) { Require-Hash $entry.Installed $entry.OldHash } }
            $Outcome = 'rolledback'
            $ExitCode = 3
        } catch {
            $Reason += ';ROLLBACK_' + (Safe-Reason $_)
            $Outcome = 'failed'
            $ExitCode = 4
        }
    }
} finally {
    if ($ProbeProcesses.Count -gt 0) {
        try { Stop-Scoped @($ProbeProcesses | ForEach-Object { $_.Path } | Select-Object -Unique) 0 } catch { $Reason += ';PROBE_CLEANUP_' + (Safe-Reason $_); $Outcome='failed'; $ExitCode=4 }
    }
    if ($TaskTouched -and $null -ne $OriginalEnabled) {
        try {
            if ($OriginalEnabled) { Enable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath | Out-Null } else { Disable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath | Out-Null }
            $restoredTask = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
            if ([bool]$restoredTask.Settings.Enabled -ne $OriginalEnabled) { Fail 'TASK_ENABLED_STATE_NOT_RESTORED' }
        } catch { $Reason += ';TASK_RESTORE_' + (Safe-Reason $_); $Outcome='failed'; $ExitCode=4 }
    }
    if ($LockHandle) { $LockHandle.Dispose() }
    $result = [ordered]@{manifestPath=$ManifestPath;commit=if ($Manifest) { $Manifest.Commit } else { $null };fileActions=$FileActions;labs=$LabsState;startupAdmission=$StartupAdmission;mode=$Mode;inspection=$Inspection;preservedInstalledWarden=[bool]$PreserveInstalledWarden;jobId=$JobId;host=$env:COMPUTERNAME;startedAt=$StartedAt;finishedAt=(Get-Date).ToString('o');outcome=$Outcome;exitCode=$ExitCode;phase=$Phase;reason=$Reason;installPath=$InstallPath;stagePath=$StagePath;expectedUserSid=$ExpectedUserSid;expectedSessionId=$ExpectedSessionId;task=($TaskPath+$TaskName);taskEnabledOriginal=$OriginalEnabled;targetAppVersion=$TargetAppVersion;targetWardenVersion=$TargetWardenVersion;appSha256=$TargetAppHash;wardenSha256=$TargetWardenHash;sourceSha256=$TargetSourceHash;app=$FinalApp;videoBefore=$VideoBaseline;video=$VideoHealth;backupDirectory=$BackupDir;probeDirectoryRetained=$ProbeDir;wallTouched=$WallTouched}
    # Probe files and backups are intentionally retained. No recursive cleanup.
    try {
        $safeResult = Full-Path $ResultPath
        if (Within $safeResult $PublicRoot) {
            No-Reparse-Parents $safeResult
            $json = $result | ConvertTo-Json -Depth 9
            [IO.File]::WriteAllText($safeResult,$json,(New-Object Text.UTF8Encoding($false)))
        } else { throw [InvalidOperationException]::new('RESULT_BOUNDARY_REFUSED') }
    } catch { $ExitCode=4; $result.outcome='failed'; $result.exitCode=4; $result.reason += ';RESULT_WRITE_FAILED' }
    [pscustomobject]$result | ConvertTo-Json -Depth 9
}
exit $ExitCode
