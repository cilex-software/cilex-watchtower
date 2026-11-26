#requires -Version 5.1
<#
.SYNOPSIS
Update the existing Office installation from a verified, extracted package.
.DESCRIPTION
Run on Office as its signed-in administrator. This uses the generic installer's
backup, startup/video verification and automatic rollback. -WhatIf is read-only.
No account, firewall, script-execution policy, automatic sign-in or Labs hold
is changed. A verified idle Office Labs startup entry may be temporarily disabled
and restored without starting it. Only Watchtower/Warden files are updated.
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
param(
    [Parameter(Mandatory=$true)][string]$PackagePath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ManifestSha256,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$')][string]$ExpectedHost='WT-OFFICE-01',
    [string]$InstallDir,
    [string]$ResultPath
)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'

function Write-OfficeUpdateProgress([string]$Stage,[string]$Language) {
    $languageIndex = [int]($Language -eq 'ru')
    if($Stage -eq 'RestoringPreviousVersion'){
        Write-Host (@('Restoring the previous version and checking it...', 'Восстанавливаем предыдущую версию и проверяем её...')[$languageIndex])
        return
    }
    $steps = [ordered]@{
        CheckingPackage       = @('Checking the update package', 'Проверка пакета обновления')
        CheckingOffice        = @('Checking the Office installation', 'Проверка текущей установки')
        CheckingRequirements  = @('Checking Windows requirements', 'Проверка требований Windows')
        CheckingVideo         = @('Checking the current camera feeds', 'Проверка текущего видео с камер')
        StagingFiles          = @('Preparing and checking the new files', 'Подготовка и проверка новых файлов')
        ReplacingFiles        = @('Updating the files. The camera wall will close briefly.', 'Обновление файлов. Окно с камерами ненадолго закроется.')
        StartingWatchtower    = @('Starting Watchtower', 'Запуск Watchtower')
        VerifyingVideo        = @('Checking startup and video. Keep this window open for a few minutes.', 'Проверка запуска и видео. Оставьте это окно открытым на несколько минут.')
        Finishing             = @('Finishing the update and saving the result', 'Завершение обновления и сохранение результата')
    }
    if($Stage -eq 'Complete'){
        Write-Host ('[{0}] {1}' -f ('#' * $steps.Count), @('Update complete', 'Обновление завершено')[$languageIndex])
        return
    }
    $index = [array]::IndexOf([object[]]@($steps.Keys), $Stage)
    if($index -ge 0){
        $bar = ('#' * $index) + '>' + ('-' * ($steps.Count - $index - 1))
        Write-Host ('[{0}] {1}' -f $bar, $steps[$Stage][$languageIndex])
    }
}

function Test-OfficePackageTrust([string]$Directory,[string]$TrustedHash) {
    if(-not [IO.Path]::IsPathRooted($Directory) -or $Directory.StartsWith('\\')){throw 'OFFICE_PACKAGE_LOCAL_DIRECTORY_REQUIRED'}
    $root=[IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $parent=$root
    while($parent){
        if((Test-Path -LiteralPath $parent) -and ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'OFFICE_PACKAGE_LINK_FORBIDDEN'}
        $next=Split-Path -Parent $parent;if($next -eq $parent){break};$parent=$next
    }
    $manifestPath=Join-Path $root 'manifest.json'
    if((Get-Item -LiteralPath $manifestPath).Length -gt 8MB -or (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $TrustedHash){throw 'OFFICE_PACKAGE_MANIFEST_HASH_MISMATCH'}
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    if($manifest.schemaVersion -ne 1 -or $manifest.product -ne 'CilexWatchtower' -or $manifest.architecture -ne 'x64'){throw 'OFFICE_PACKAGE_UNSUPPORTED'}
    $seen=@{}
    foreach($helper in @($manifest.helpers)){
        $relative=[string]$helper.path
        if(-not $relative -or $relative -notmatch '^[A-Za-z0-9_.-]+$' -or $relative -in @('.','..') -or $seen.ContainsKey($relative)){throw 'OFFICE_PACKAGE_HELPER_PATH_INVALID'}
        $seen[$relative]=$true
        $path=Join-Path (Join-Path $root 'helpers') $relative
        $item=Get-Item -LiteralPath $path -Force
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.PSIsContainer -or $item.Length -ne [long]$helper.size -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $helper.sha256){throw 'OFFICE_PACKAGE_HELPER_HASH_MISMATCH'}
    }
    foreach($name in @('Common.psm1','Install.psm1','Requirements.psm1','requirements.json','StationVideoHealth.psm1')){
        if(-not $seen.ContainsKey($name)){throw 'OFFICE_PACKAGE_REQUIRED_HELPER_MISSING'}
    }
    return [pscustomobject]@{Root=$root;Manifest=$manifest}
}

function Get-OfficeTaskSid($Task) {
    $user=[string]$Task.Principal.UserId
    if($user -match '^S-1-'){return $user}
    return (New-Object Security.Principal.NTAccount $user).Translate([Security.Principal.SecurityIdentifier]).Value
}

function Test-OfficeInertLegacyTask($Task,$Plan) {
    # Managed adoption deliberately retains this disabled legacy task for recovery.
    # Accept only that exact inert form; an unknown or active alternative still blocks.
    if($Task.TaskName -cne 'wt-warden' -or $Task.TaskPath -ne '\'){return $false}
    foreach($name in @('Settings','State','Principal')){if(-not $Task.PSObject.Properties[$name] -or $null -eq $Task.$name){return $false}}
    if(-not $Task.Settings.PSObject.Properties['Enabled'] -or $Task.Settings.Enabled -isnot [bool] -or $Task.Settings.Enabled -or [string]$Task.State -cne 'Disabled'){return $false}
    foreach($name in @('UserId','LogonType','RunLevel')){if(-not $Task.Principal.PSObject.Properties[$name]){return $false}}
    if([string]$Task.Principal.LogonType -cne 'Interactive' -or [string]$Task.Principal.RunLevel -cne 'Limited'){return $false}
    $actions=@($Task.Actions)
    if($actions.Count -ne 1){return $false}
    $action=$actions[0]
    foreach($name in @('Execute','Arguments','WorkingDirectory')){if(-not $action.PSObject.Properties[$name]){return $false}}
    if([string]$action.Execute -ne (Join-Path $Plan.Directory 'warden\warden.exe') -or [string]$action.Arguments -cne 'run'){return $false}
    if([string]$action.WorkingDirectory -and [string]$action.WorkingDirectory -ne $Plan.Directory){return $false}
    return (Get-OfficeTaskSid $Task) -eq $Plan.Identity.Sid
}

function Get-OfficeStartupSelection($Plan,$Marker,[object[]]$Tasks) {
    $expected=Join-Path $Plan.Directory $(if($Marker){'warden\warden-launcher.exe'}else{'warden\warden.exe'})
    $candidates=@()
    $inertLegacyCount=0
    foreach($task in $Tasks){
        if($Marker -and (Test-OfficeInertLegacyTask $task $Plan)){
            $inertLegacyCount++
            if($inertLegacyCount -gt 1){throw 'OFFICE_STARTUP_OWNERSHIP_AMBIGUOUS'}
            continue
        }
        $actions=@($task.Actions)
        foreach($action in $actions){
            $execute=if($action.PSObject.Properties['Execute']){[string]$action.Execute}else{''}
            $arguments=if($action.PSObject.Properties['Arguments']){[string]$action.Arguments}else{''}
            $referencesInstall=($execute -and $execute.IndexOf($Plan.Directory,[StringComparison]::OrdinalIgnoreCase) -ge 0) -or ($arguments -and $arguments.IndexOf($Plan.Directory,[StringComparison]::OrdinalIgnoreCase) -ge 0)
            if(-not $referencesInstall){continue}
            if($execute -ne $expected -or $arguments.Trim() -ne 'run' -or $actions.Count -ne 1 -or $task.TaskPath -ne '\' -or (Get-OfficeTaskSid $task) -ne $Plan.Identity.Sid){throw 'OFFICE_STARTUP_OWNERSHIP_AMBIGUOUS'}
            $candidates+=,$task
        }
    }
    if($candidates.Count -ne 1 -or ($Marker -and $candidates[0].TaskName -cne $Plan.TaskName)){throw 'OFFICE_STARTUP_OWNERSHIP_AMBIGUOUS'}
    if(-not $candidates[0].Settings.Enabled){throw 'OFFICE_STARTUP_DISABLED_REVIEW_REQUIRED'}
    return [pscustomobject]@{TaskName=$candidates[0].TaskName;AdoptExisting=($null -eq $Marker)}
}

function Test-OfficeLabsBarrier($Status,$Control,[int]$Workers,[bool]$CanRespawn,[int]$WorkerPid,[DateTime]$Now) {
    if($Workers -eq 0 -and -not $CanRespawn){return $true}
    if($Workers -gt 1 -or -not $Status){return $false}
    foreach($name in @('updated_at','units','current','state','server_mode')){if(-not $Status.PSObject.Properties[$name]){return $false}}
    $at=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParse([string]$Status.updated_at,[ref]$at)){return $false}
    $age=($Now.ToUniversalTime()-$at.UtcDateTime).TotalSeconds
    if($age -lt -10 -or $age -gt 60){return $false}
    if($Workers -eq 1 -and (-not $Status.PSObject.Properties['pid'] -or [int]$Status.pid -ne $WorkerPid)){return $false}
    $hold=$null
    if($Control -and $Control.PSObject.Properties['hold']){$hold=$Control.hold}
    $operatorHold=$hold -and $hold.PSObject.Properties['why'] -and [string]$hold.why -and $hold.PSObject.Properties['by'] -and [string]$hold.by -ne 'wall-guard'
    $barrier=[string]$Status.server_mode -in @('off','stopped','paused') -or ($operatorHold -and [string]$Status.state -eq 'held')
    $unitCount=if($null -eq $Status.units){0}else{@($Status.units).Count}
    return $unitCount -eq 0 -and $null -eq $Status.current -and $barrier
}

function Assert-OfficeLabsSafe($Identity,[int]$Session,[object[]]$Tasks) {
    $workers=@(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction Stop|Where-Object{
        $_.SessionId -eq $Session -and $_.CommandLine -match '(?i)(?:^|\s)(?:"(?:[^"\r\n]*[\\/])?run_worker\.py"|(?:[^\s"\r\n]*[\\/])?run_worker\.py)(?=\s|$)' -and $_.CommandLine -match '(?:^|\s)--loop(?:\s|$)'
    })
    foreach($worker in $workers){$owner=Invoke-CimMethod -InputObject $worker -MethodName GetOwnerSid -ErrorAction Stop;if($owner.ReturnValue -ne 0 -or $owner.Sid -ne $Identity.Sid){throw 'OFFICE_LABS_OWNER_UNVERIFIED'}}
    $guards=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop|Where-Object{
        $_.SessionId -eq $Session -and $_.CommandLine -match '(?i)(?:^|\s)-File\s+(?:"(?:[^"\r\n]*[\\/])?guard3\.ps1"|(?:[^\s"\r\n]*[\\/])?guard3\.ps1)(?=\s|$)' -and $_.CommandLine -match '(?i)(?:^|\s)-StartWorker(?=:|\s|$)'
    })
    $canRespawn=$guards.Count -gt 0
    foreach($task in $Tasks){
        if(-not $task.Settings.Enabled){continue}
        $startsLabs=$task.TaskName -match '(?i)^wt-labs'
        foreach($action in @($task.Actions)){
            $execute=if($action.PSObject.Properties['Execute']){[string]$action.Execute}else{''}
            $arguments=if($action.PSObject.Properties['Arguments']){[string]$action.Arguments}else{''}
            if($execute -match '(?i)(?:^|[\\/])(?:guard3|start-labs[^\\/]*)\.(?:ps1|vbs|cmd)$' -or $arguments -match '(?i)(?:^|[\\/])(?:guard3|start-labs[^\\/\s"]*)\.(?:ps1|vbs|cmd)(?=["\s]|$)'){$startsLabs=$true}
        }
        if($startsLabs -and (Get-OfficeTaskSid $task) -eq $Identity.Sid){$canRespawn=$true}
    }
    $status=$null;$control=$null
    if($workers.Count -or $canRespawn){
        $root=Join-Path $Identity.LocalAppData 'watchtower-labs'
        try{
            $statusPath=Join-Path $root 'status.json'
            if((Get-Item -LiteralPath $statusPath).Length -gt 1MB){throw 'OFFICE_LABS_STATUS_UNVERIFIED'}
            $status=Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8|ConvertFrom-Json
            $controlPath=Join-Path $root 'control.json'
            if(Test-Path -LiteralPath $controlPath){if((Get-Item -LiteralPath $controlPath).Length -gt 1MB){throw 'OFFICE_LABS_STATUS_UNVERIFIED'};$control=Get-Content -LiteralPath $controlPath -Raw -Encoding UTF8|ConvertFrom-Json}
        }catch{throw 'OFFICE_LABS_STATUS_UNVERIFIED'}
    }
    $workerPid=if($workers.Count -eq 1){[int]$workers[0].ProcessId}else{0}
    if(-not (Test-OfficeLabsBarrier $status $control $workers.Count $canRespawn $workerPid ([DateTime]::UtcNow))){throw 'OFFICE_LABS_PAUSE_AND_DRAIN_REQUIRED'}
}

function Get-OfficeLabsExecutionContext {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal $identity
    return [pscustomobject]@{Computer=$env:COMPUTERNAME;CurrentSid=$identity.User.Value;Session=[Diagnostics.Process]::GetCurrentProcess().SessionId;Administrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
}

function Get-OfficeLabsTasks { return @(Get-ScheduledTask -ErrorAction Stop) }

function Get-OfficeLabsTaskSnapshot {
    $tasks=@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop|Where-Object{$_.TaskName -ceq 'wt-labs-start'})
    if($tasks.Count -ne 1){throw 'OFFICE_LABS_TASK_UNVERIFIED'}
    return [pscustomobject]@{Task=$tasks[0];Xml=[string](Export-ScheduledTask -TaskName 'wt-labs-start' -TaskPath '\' -ErrorAction Stop)}
}

function Get-OfficeLabsTaskInstances {
    $service=$null;$folder=$null;$task=$null;$instances=$null
    try{
        $service=New-Object -ComObject Schedule.Service
        $service.Connect()
        $folder=$service.GetFolder('\')
        $task=$folder.GetTask('wt-labs-start')
        $instances=$task.GetInstances(0)
        return [int]$instances.Count
    }catch{throw 'OFFICE_LABS_INSTANCES_UNVERIFIED'}
    finally{
        foreach($item in @($instances,$task,$folder,$service)){
            if($null -ne $item -and [Runtime.InteropServices.Marshal]::IsComObject($item)){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($item)}
        }
    }
}

function Test-OfficeLabsProcessPlausible([string]$Name,[string]$Path,[string]$CommandLine) {
    return $Name -match '(?i)^(?:wscript|cscript|cmd|powershell|pwsh|python[^\\/\s]*|ffmpeg)(?:\.exe)?$' -or $Name -match '(?i)(?:labs|run_worker|unit_proc)' -or ($Path+' '+$CommandLine) -match '(?i)(?:[\\/]wt-labs(?:[\\/\s"]|$)|[\\/]watchtower-labs(?:[\\/\s"]|$)|guard[23]\.ps1|start-labs[^\s"]*\.(?:vbs|ps1|cmd)|run_worker\.py|unit_proc\.py|--multiprocessing-fork|multiprocessing\.spawn)'
}

function Get-OfficeLabsProcessRows {
    $rows=@()
    foreach($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)){
        $name=[string]$process.Name;$path=[string]$process.ExecutablePath;$command=[string]$process.CommandLine
        if(-not (Test-OfficeLabsProcessPlausible $name $path $command)){continue}
        $known=$false;$sid=$null
        try{$owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop;if($owner.ReturnValue -eq 0 -and $owner.Sid){$known=$true;$sid=[string]$owner.Sid}}catch{}
        $rows+=,[pscustomobject]@{Name=$name;Path=$path;CommandLine=$command;OwnerSid=$sid;OwnerKnown=$known;Session=[int]$process.SessionId;ProcessId=[int]$process.ProcessId;ParentId=[int]$process.ParentProcessId}
    }
    return $rows
}

function Assert-OfficeLabsLocalFile([string]$Path) {
    if($Path -notmatch '^[A-Za-z]:[\\/]'){throw 'OFFICE_LABS_FILE_UNVERIFIED'}
    $parent=[IO.Path]::GetFullPath($Path)
    while($parent){
        if((Test-Path -LiteralPath $parent) -and ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'OFFICE_LABS_FILE_UNVERIFIED'}
        $next=Split-Path -Parent $parent;if($next -eq $parent){break};$parent=$next
    }
}

function Get-OfficeLabsFilePins {
    foreach($path in @('C:\wt-labs\start-labs.vbs','C:\wt-labs\guard3.ps1')){
        Assert-OfficeLabsLocalFile $path
        if(-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -gt 1MB){throw 'OFFICE_LABS_FILE_UNVERIFIED'}
    }
    return [pscustomobject]@{LauncherPath='C:\wt-labs\start-labs.vbs';LauncherSha256=(Get-FileHash -LiteralPath 'C:\wt-labs\start-labs.vbs' -Algorithm SHA256).Hash;GuardPath='C:\wt-labs\guard3.ps1';GuardSha256=(Get-FileHash -LiteralPath 'C:\wt-labs\guard3.ps1' -Algorithm SHA256).Hash}
}

function Get-OfficeLabsControlSnapshot($Identity) {
    $path=Join-Path $Identity.LocalAppData 'watchtower-labs\control.json'
    Assert-OfficeLabsLocalFile $path
    $exists=Test-Path -LiteralPath $path
    $hash=$null
    if($exists){
        $item=Get-Item -LiteralPath $path -Force
        if($item.PSIsContainer -or $item.Length -gt 1MB){throw 'OFFICE_LABS_CONTROL_UNVERIFIED'}
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    return [pscustomobject]@{Path=$path;Exists=[bool]$exists;Sha256=$hash}
}

function ConvertTo-OfficeLabsXmlSignature([string]$Xml,[switch]$IgnoreEnabled) {
    $doc=New-Object Xml.XmlDocument
    $doc.XmlResolver=$null;$doc.PreserveWhitespace=$false
    try{$doc.LoadXml($Xml)}catch{throw 'OFFICE_LABS_TASK_UNVERIFIED'}
    if($doc.DocumentType){throw 'OFFICE_LABS_TASK_UNVERIFIED'}
    if($IgnoreEnabled){
        $ns=New-Object Xml.XmlNamespaceManager $doc.NameTable;$ns.AddNamespace('t',$doc.DocumentElement.NamespaceURI)
        foreach($node in @($doc.SelectNodes('/t:Task/t:Settings/t:Enabled',$ns))){[void]$node.ParentNode.RemoveChild($node)}
    }
    return $doc.OuterXml
}

function Assert-OfficeLabsTaskDefinition($Snapshot,$Identity) {
    $task=$Snapshot.Task
    if(-not $task.PSObject.Properties['Triggers']){throw 'OFFICE_LABS_TASK_UNVERIFIED'}
    $triggerCount=if($null -eq $task.Triggers){0}else{@($task.Triggers).Count}
    if($task.TaskName -cne 'wt-labs-start' -or $task.TaskPath -ne '\' -or @($task.Actions).Count -ne 1 -or $triggerCount -ne 0){throw 'OFFICE_LABS_TASK_UNVERIFIED'}
    if(-not $task.Settings.PSObject.Properties['Enabled'] -or $task.Settings.Enabled -isnot [bool]){throw 'OFFICE_LABS_TASK_UNVERIFIED'}
    $sid=Get-OfficeTaskSid $task
    if($sid -ne $Identity.Sid -or [string]$task.Principal.LogonType -cne 'Interactive' -or [string]$task.Principal.RunLevel -cne 'Limited'){throw 'OFFICE_LABS_TASK_UNVERIFIED'}
    $action=$task.Actions[0]
    $systemWscript=Join-Path $env:SystemRoot 'System32\wscript.exe'
    if([string]$action.Execute -notin @('wscript.exe',$systemWscript) -or [string]$action.Arguments -cne '//B //NoLogo C:\wt-labs\start-labs.vbs' -or [string]$action.WorkingDirectory){throw 'OFFICE_LABS_TASK_UNVERIFIED'}
    $doc=New-Object Xml.XmlDocument;$doc.XmlResolver=$null
    try{$doc.LoadXml([string]$Snapshot.Xml)}catch{throw 'OFFICE_LABS_TASK_UNVERIFIED'}
    if($doc.DocumentType -or $doc.DocumentElement.LocalName -ne 'Task' -or $doc.DocumentElement.NamespaceURI -ne 'http://schemas.microsoft.com/windows/2004/02/mit/task'){throw 'OFFICE_LABS_TASK_UNVERIFIED'}
    $ns=New-Object Xml.XmlNamespaceManager $doc.NameTable;$ns.AddNamespace('t',$doc.DocumentElement.NamespaceURI)
    $principals=@($doc.SelectNodes('/t:Task/t:Principals/t:Principal',$ns));$actions=@($doc.SelectNodes('/t:Task/t:Actions/*',$ns));$triggers=@($doc.SelectNodes('/t:Task/t:Triggers/*',$ns))
    if($principals.Count -ne 1 -or $actions.Count -ne 1 -or $actions[0].LocalName -ne 'Exec' -or $triggers.Count -ne 0){throw 'OFFICE_LABS_TASK_UNVERIFIED'}
    $user=$doc.SelectSingleNode('/t:Task/t:Principals/t:Principal/t:UserId',$ns)
    $logon=$doc.SelectSingleNode('/t:Task/t:Principals/t:Principal/t:LogonType',$ns)
    $level=$doc.SelectSingleNode('/t:Task/t:Principals/t:Principal/t:RunLevel',$ns)
    $command=$doc.SelectSingleNode('/t:Task/t:Actions/t:Exec/t:Command',$ns)
    $arguments=$doc.SelectSingleNode('/t:Task/t:Actions/t:Exec/t:Arguments',$ns)
    $working=$doc.SelectSingleNode('/t:Task/t:Actions/t:Exec/t:WorkingDirectory',$ns)
    $enabledNodes=@($doc.SelectNodes('/t:Task/t:Settings/t:Enabled',$ns))
    if(-not $user -or -not $logon -or -not $command -or -not $arguments -or $enabledNodes.Count -gt 1){throw 'OFFICE_LABS_TASK_UNVERIFIED'}
    $xmlSid=$user.InnerText
    if($xmlSid -notmatch '^S-1-'){$xmlSid=(New-Object Security.Principal.NTAccount $xmlSid).Translate([Security.Principal.SecurityIdentifier]).Value}
    if($enabledNodes.Count -eq 0){
        # Task Scheduler may omit this schema default; confirm it independently.
        if(-not $task.Settings.Enabled){throw 'OFFICE_LABS_TASK_UNVERIFIED'}
        $xmlEnabled=$true
    }else{
        if($enabledNodes[0].SelectNodes('*').Count -ne 0){throw 'OFFICE_LABS_TASK_UNVERIFIED'}
        try{$xmlEnabled=[Xml.XmlConvert]::ToBoolean($enabledNodes[0].InnerText.Trim([char[]]" `t`r`n"))}
        catch{throw 'OFFICE_LABS_TASK_UNVERIFIED'}
    }
    if($xmlSid -ne $Identity.Sid -or $logon.InnerText -cne 'InteractiveToken' -or ($level -and $level.InnerText -cne 'LeastPrivilege') -or $command.InnerText -ne [string]$action.Execute -or $arguments.InnerText -cne [string]$action.Arguments -or ($working -and $working.InnerText) -or $xmlEnabled -ne $task.Settings.Enabled){throw 'OFFICE_LABS_TASK_UNVERIFIED'}
    return [pscustomobject]@{Enabled=$xmlEnabled;Definition=(ConvertTo-OfficeLabsXmlSignature $Snapshot.Xml -IgnoreEnabled);Full=(ConvertTo-OfficeLabsXmlSignature $Snapshot.Xml)}
}

function Assert-OfficeLabsNoActors([object[]]$Rows) {
    foreach($row in $Rows){
        $name=[string]$row.Name;$path=[string]$row.Path;$command=[string]$row.CommandLine
        if(-not (Test-OfficeLabsProcessPlausible $name $path $command)){continue}
        if(-not $path -or -not $command -or $row.OwnerKnown -isnot [bool] -or -not $row.OwnerKnown -or -not $row.OwnerSid){throw 'OFFICE_LABS_ACTOR_UNVERIFIED'}
        if($name -match '(?i)^(?:ffmpeg)(?:\.exe)?$' -or $name -match '(?i)(?:labs|run_worker|unit_proc)' -or ($path+' '+$command) -match '(?i)(?:[\\/]wt-labs(?:[\\/\s"]|$)|[\\/]watchtower-labs(?:[\\/\s"]|$)|guard[23]\.ps1|start-labs[^\s"]*\.(?:vbs|ps1|cmd)|run_worker\.py|unit_proc\.py|--multiprocessing-fork|multiprocessing\.spawn)'){throw 'OFFICE_LABS_ACTOR_PRESENT'}
    }
}

function Assert-OfficeLabsNoOtherStartup([object[]]$Tasks) {
    $knownCount=0
    foreach($task in $Tasks){
        if($task.TaskName -ceq 'wt-labs-start' -and $task.TaskPath -eq '\'){$knownCount++;continue}
        $relevant=[string]$task.TaskName -match '(?i)labs'
        foreach($action in @($task.Actions)){
            $exe=if($action.PSObject.Properties['Execute']){[string]$action.Execute}else{''}
            $arguments=if($action.PSObject.Properties['Arguments']){[string]$action.Arguments}else{''}
            if(($exe+' '+$arguments) -match '(?i)(?:[\\/]wt-labs(?:[\\/\s"]|$)|[\\/]watchtower-labs(?:[\\/\s"]|$)|guard[23]\.ps1|start-labs[^\s"]*\.(?:vbs|ps1|cmd)|run_worker\.py|unit_proc\.py)'){$relevant=$true}
        }
        if(-not $relevant){continue}
        if(-not $task.PSObject.Properties['Settings'] -or -not $task.Settings -or -not $task.Settings.PSObject.Properties['Enabled'] -or $task.Settings.Enabled -isnot [bool]){throw 'OFFICE_LABS_STARTUP_UNVERIFIED'}
        if($task.Settings.Enabled){throw 'OFFICE_LABS_OTHER_STARTUP_PRESENT'}
    }
    if($knownCount -ne 1){throw 'OFFICE_LABS_TASK_UNVERIFIED'}
}

function Assert-OfficeLabsIdentity($Identity,[switch]$Administrator) {
    $context=Get-OfficeLabsExecutionContext
    if($context.Computer -cne 'WT-OFFICE-01' -or $Identity.Sid -ne 'S-1-5-21-463139321-2945944505-4245986892-1001' -or $context.CurrentSid -ne $Identity.Sid -or $context.Session -le 0){throw 'OFFICE_LABS_IDENTITY_UNVERIFIED'}
    if($Administrator -and -not $context.Administrator){throw 'OFFICE_ELEVATED_ADMINISTRATOR_REQUIRED'}
}

function Assert-OfficeLabsPins($Pins) {
    if($Pins.LauncherPath -ne 'C:\wt-labs\start-labs.vbs' -or $Pins.LauncherSha256 -ine 'D0CCA421F08A48563A5D05885C8C6776E43E85F410AE46F229D6E3B909014CD0' -or $Pins.GuardPath -ne 'C:\wt-labs\guard3.ps1' -or $Pins.GuardSha256 -ine '0422A323ECBE5EB010551B155FB1AF90B915EA8C980DF4D5DD768050C52B4502'){throw 'OFFICE_LABS_FILE_UNVERIFIED'}
}

function Get-OfficeIdleLabsPlan($Identity,[object[]]$Tasks) {
    Assert-OfficeLabsIdentity $Identity
    $snapshot=Get-OfficeLabsTaskSnapshot
    $checked=Assert-OfficeLabsTaskDefinition $snapshot $Identity
    $expectedState=if($checked.Enabled){'Ready'}else{'Disabled'}
    if([string]$snapshot.Task.State -cne $expectedState -or (Get-OfficeLabsTaskInstances) -ne 0){throw 'OFFICE_LABS_TASK_NOT_IDLE'}
    Assert-OfficeLabsNoOtherStartup $Tasks
    Assert-OfficeLabsNoActors @(Get-OfficeLabsProcessRows)
    $pins=Get-OfficeLabsFilePins;Assert-OfficeLabsPins $pins
    $control=Get-OfficeLabsControlSnapshot $Identity
    return [pscustomobject]@{Identity=$Identity;TaskName='wt-labs-start';TaskPath='\';OriginalXml=[string]$snapshot.Xml;OriginalDefinition=$checked.Definition;OriginalFullXml=$checked.Full;OriginalEnabled=[bool]$checked.Enabled;Control=$control;Pins=$pins;RestoreNeeded=$false;Entered=$false;Restored=$false;RecoveryRequired=$false;Phase='Inspected'}
}

function Assert-OfficeLabsControlUnchanged($State) {
    $current=Get-OfficeLabsControlSnapshot $State.Identity
    if($current.Path -ne $State.Control.Path -or $current.Exists -isnot [bool] -or $current.Exists -ne $State.Control.Exists -or [string]$current.Sha256 -cne [string]$State.Control.Sha256){throw 'OFFICE_LABS_CONTROL_CHANGED'}
}

function Assert-OfficeIdleLabsState($State,[bool]$Enabled) {
    Assert-OfficeLabsIdentity $State.Identity
    $snapshot=Get-OfficeLabsTaskSnapshot
    $checked=Assert-OfficeLabsTaskDefinition $snapshot $State.Identity
    $expectedState=if($Enabled){'Ready'}else{'Disabled'}
    if($checked.Definition -cne $State.OriginalDefinition -or $checked.Enabled -ne $Enabled -or [string]$snapshot.Task.State -cne $expectedState){throw 'OFFICE_LABS_TASK_CHANGED'}
    if((Get-OfficeLabsTaskInstances) -ne 0){throw 'OFFICE_LABS_TASK_NOT_IDLE'}
    Assert-OfficeLabsNoOtherStartup @(Get-OfficeLabsTasks)
    Assert-OfficeLabsNoActors @(Get-OfficeLabsProcessRows)
    Assert-OfficeLabsPins (Get-OfficeLabsFilePins)
    Assert-OfficeLabsControlUnchanged $State
    return $checked
}

function Get-OfficeLabsRecoveryRecord($State) {
    return [pscustomobject]@{schemaVersion=1;computer='WT-OFFICE-01';targetSid=$State.Identity.Sid;taskName=$State.TaskName;taskPath=$State.TaskPath;originalXml=$State.OriginalXml;originalDefinition=$State.OriginalDefinition;originalEnabled=$State.OriginalEnabled;control=$State.Control;pins=$State.Pins;restoreNeeded=$State.RestoreNeeded;entered=$State.Entered;restored=$State.Restored;recoveryRequired=$State.RecoveryRequired;phase=$State.Phase;updatedUtc=[DateTime]::UtcNow.ToString('o')}
}

function Enter-OfficeIdleLabs($State,[scriptblock]$PersistRecovery,[switch]$WhatIf) {
    $null=Assert-OfficeIdleLabsState $State $State.OriginalEnabled
    if($WhatIf){return}
    Assert-OfficeLabsIdentity $State.Identity -Administrator
    if(-not $PersistRecovery){throw 'OFFICE_LABS_RECOVERY_NOT_SAVED'}
    if(-not $State.OriginalEnabled){$State.Entered=$true;return}
    $State.Phase='RestoreRequired';$State.RestoreNeeded=$true
    try{& $PersistRecovery (Get-OfficeLabsRecoveryRecord $State)|Out-Null}
    catch{$State.RestoreNeeded=$false;$State.Phase='RecoveryWriteFailed';throw}
    # Persistence can take time. Refuse a task or process change before mutation.
    try{$null=Assert-OfficeIdleLabsState $State $State.OriginalEnabled}
    catch{
        $State.RestoreNeeded=$false;$State.Phase='FreezeRejected'
        try{& $PersistRecovery (Get-OfficeLabsRecoveryRecord $State)|Out-Null}catch{}
        throw
    }
    # Record is durable before this call; a partial disable still requires finally restoration.
    Disable-ScheduledTask -TaskName 'wt-labs-start' -TaskPath '\' -ErrorAction Stop|Out-Null
    $null=Assert-OfficeIdleLabsState $State $false
    $State.Entered=$true;$State.Phase='Frozen'
    & $PersistRecovery (Get-OfficeLabsRecoveryRecord $State)|Out-Null
}

function Assert-OfficeIdleLabsFrozen($State) {
    if(-not $State.Entered){throw 'OFFICE_LABS_NOT_FROZEN'}
    $null=Assert-OfficeIdleLabsState $State $false
}

function Exit-OfficeIdleLabs($State,[scriptblock]$PersistRecovery,[switch]$WhatIf) {
    if(-not $State.RestoreNeeded){return}
    if($WhatIf){return}
    try{
        Assert-OfficeLabsIdentity $State.Identity -Administrator
        $snapshot=Get-OfficeLabsTaskSnapshot
        $checked=Assert-OfficeLabsTaskDefinition $snapshot $State.Identity
        if($checked.Definition -cne $State.OriginalDefinition){throw 'OFFICE_LABS_TASK_CHANGED'}
        # Permit a failed Disable call that left the task exactly as originally captured.
        # Changed controls, scripts, task definitions or actors require recovery;
        # enabling a changed startup definition is never an automatic repair.
        $null=Assert-OfficeIdleLabsState $State ([bool]$checked.Enabled)
        if($checked.Enabled -ne $State.OriginalEnabled){
            if(-not $State.OriginalEnabled){throw 'OFFICE_LABS_TASK_CHANGED'}
            Enable-ScheduledTask -TaskName 'wt-labs-start' -TaskPath '\' -ErrorAction Stop|Out-Null
        }
        $restored=Assert-OfficeIdleLabsState $State $State.OriginalEnabled
        # Windows may omit or materialize the default Enabled element when
        # serializing the same state. Every other XML field remains exact.
        if($restored.Definition -cne $State.OriginalDefinition -or $restored.Enabled -ne $State.OriginalEnabled){throw 'OFFICE_LABS_TASK_CHANGED'}
        $State.RestoreNeeded=$false;$State.Restored=$true;$State.RecoveryRequired=$false;$State.Phase='Restored'
        & $PersistRecovery (Get-OfficeLabsRecoveryRecord $State)|Out-Null
    }catch{
        $State.RestoreNeeded=$true;$State.Restored=$false;$State.RecoveryRequired=$true;$State.Phase='RecoveryRequired'
        try{& $PersistRecovery (Get-OfficeLabsRecoveryRecord $State)|Out-Null}catch{}
        throw 'OFFICE_LABS_RECOVERY_REQUIRED'
    }
}

function Write-OfficeLabsRecoveryRecord($Record,[string]$Path,$Installer,[string]$Sid) {
    # Flush a private recovery record before changing the idle task. Atomic
    # replacements keep the previous complete record if a later write fails.
    $temporary=$Path+'.new-'+[Guid]::NewGuid().ToString('N')
    try {
        $file=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $file.Dispose()
        & $Installer {param($p,$s)Set-WtgPrivateFileAcl $p $s} $temporary $Sid
        $bytes=(New-Object Text.UTF8Encoding $false).GetBytes(($Record|ConvertTo-Json -Depth 12))
        $file=[IO.File]::Open($temporary,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
        if(Test-Path -LiteralPath $Path){
            if((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'OFFICE_LABS_RECOVERY_PATH_UNSAFE'}
            [IO.File]::Replace($temporary,$Path,[Management.Automation.Language.NullString]::Value)
        }else{[IO.File]::Move($temporary,$Path)}
    }finally{
        if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
    }
}

$runId=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$language=if([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ru'){'ru'}else{'en'}
$result=[ordered]@{schemaVersion=1;runId=$runId;host=$env:COMPUTERNAME;status='Failed';errorCode=$null;watchtowerVersion=$null;wardenVersion=$null;sourceCommit=$null;backup=$null;rebootVerified=$false}
$code=1
$resultReserved=$false
$labsFreeze=$null
$persistLabsRecovery=$null
try{
    if(-not $WhatIfPreference){
        Write-Host $(if($language -eq 'ru'){'Cilex Watchtower | Обновление для офиса'}else{'Cilex Watchtower | Office update'})
        Write-OfficeUpdateProgress 'CheckingPackage' $language
    }
    if($env:OS -ne 'Windows_NT' -or $env:COMPUTERNAME -ne $ExpectedHost){throw 'OFFICE_TARGET_HOST_MISMATCH'}
    $verified=Test-OfficePackageTrust $PackagePath $ManifestSha256
    $helpers=Join-Path $verified.Root 'helpers'
    Import-Module (Join-Path $helpers 'Common.psm1') -Force
    $installer=Import-Module (Join-Path $helpers 'Install.psm1') -Force -PassThru
    $package=Test-WtgPackage $verified.Root $ManifestSha256
    if(-not $WhatIfPreference){Write-OfficeUpdateProgress 'CheckingOffice' $language}
    $identity=Resolve-WtgTargetIdentity
    $plan=Get-WtgInstallPlan ([pscustomobject]@{InstallDir=$InstallDir;InstallScope='User'}) $identity
    if(-not (Test-Path -LiteralPath (Join-Path $plan.Directory 'watchtower.exe') -PathType Leaf)){throw 'OFFICE_EXISTING_INSTALLATION_REQUIRED'}
    $markerPath=Join-Path $plan.Directory '.cilex-install.json'
    $marker=if(Test-Path -LiteralPath $markerPath){& $installer {param($p)Assert-WtgOwnedInstallation $p} $plan}else{$null}
    $tasks=@(Get-ScheduledTask -ErrorAction Stop)
    $selection=Get-OfficeStartupSelection $plan $marker $tasks
    $context=[pscustomobject]@{RunId=$runId;InstallDir=$plan.Directory;InstallScope='User';ExpectedHost=$ExpectedHost;TargetUser=$identity.Name;TargetSid=$identity.Sid;StartupMode='AfterSignIn';Language=$language;BackendUrl='';OverrideRequirements=@();NonInteractive=$false;DependencyMode='Offline';PackageManifestSha256=$ManifestSha256;AdoptExisting=$selection.AdoptExisting;LegacyTaskName=$selection.TaskName}
    if($selection.AdoptExisting){$null=& $installer {param($c,$p)Get-WtgLegacyAdoption $c $p} $context $plan}
    else{$null=& $installer {param($p)Get-WtgTaskXml $p} $plan}
    $owned=@(& $installer {param($p)Get-WtgOwnedProcesses $p} $plan)
    $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
    if($session -eq 0 -or @($owned|Where-Object{$_.Session -ne $session}).Count){throw 'OFFICE_SIGNED_IN_SESSION_MISMATCH'}
    try{Assert-OfficeLabsSafe $identity $session $tasks}
    catch{
        if($_.Exception.Message -cne 'OFFICE_LABS_PAUSE_AND_DRAIN_REQUIRED'){throw}
        # Only an independently verified idle task can replace stale status as
        # proof of quiescence. Running or unknown Labs actors remain a refusal.
        $labsFreeze=Get-OfficeIdleLabsPlan -Identity $identity -Tasks $tasks
    }
    if(-not $PSCmdlet.ShouldProcess($ExpectedHost,'Update existing Watchtower and Warden from the verified package')){return}
    $principal=New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'OFFICE_ELEVATED_ADMINISTRATOR_REQUIRED'}
    if(-not $ResultPath){$ResultPath=Join-Path $identity.LocalAppData ('Cilex\Deploy\results\office-'+$runId+'.json')}
    $ResultPath=& $installer {param($p)Assert-WtgLocalPath $p} $ResultPath
    if(Test-Path -LiteralPath $ResultPath){throw 'OFFICE_RESULT_ALREADY_EXISTS'}
    [IO.Directory]::CreateDirectory((Split-Path -Parent $ResultPath))|Out-Null
    $reservation=[IO.File]::Open($ResultPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $reservation.Dispose();$resultReserved=$true
    if($labsFreeze){
        $recoveryPath=$ResultPath+'.labs-recovery.json'
        if(Test-Path -LiteralPath $recoveryPath){throw 'OFFICE_LABS_RECOVERY_ALREADY_EXISTS'}
        $result.labsRecoveryPath=$recoveryPath
        $recoveryWriter=${function:Write-OfficeLabsRecoveryRecord}
        $persistLabsRecovery={param($record)& $recoveryWriter $record $recoveryPath $installer $identity.Sid}.GetNewClosure()
        Enter-OfficeIdleLabs -State $labsFreeze -PersistRecovery $persistLabsRecovery
        Assert-OfficeIdleLabsFrozen -State $labsFreeze
    }
    Assert-OfficeLabsSafe $identity $session @(Get-ScheduledTask -ErrorAction Stop)
    if($labsFreeze){Assert-OfficeIdleLabsFrozen -State $labsFreeze}
    $progressWriter=${function:Write-OfficeUpdateProgress}
    $context | Add-Member -NotePropertyName InstallProgress -NotePropertyValue ({param($stage) & $progressWriter $stage $language}.GetNewClosure())
    $installed=Install-WtgPackage $context $verified.Root
    $result.status='Installed';$result.watchtowerVersion=$installed.Version;$result.wardenVersion=$installed.WardenVersion
    $result.sourceCommit=$installed.SourceCommit;$result.backup=$installed.Backup;$result.startupCheck=$installed.Runtime
    $code=0
}catch{
    $result.errorCode='OFFICE_UPDATE_FAILED'
    if($_.Exception.Message -match '^[A-Z][A-Z0-9_]{4,100}$'){$result.errorCode=$_.Exception.Message}
    if($_.Exception.Data.Contains('RollbackVerified')){$result.rollbackVerified=[bool]$_.Exception.Data['RollbackVerified']}
}finally{
    if($code -eq 0){
        try { Write-OfficeUpdateProgress 'Finishing' $language }
        catch { # Restoring Labs and saving the report must run even if the console is gone.
        }
    }
    if($labsFreeze -and $persistLabsRecovery -and -not $WhatIfPreference){
        try{
            Exit-OfficeIdleLabs -State $labsFreeze -PersistRecovery $persistLabsRecovery
            $result.labsStartupRestored=[bool]$labsFreeze.Restored
        }catch{
            if($result.errorCode){$result.installationErrorCode=$result.errorCode}
            $result.status='RecoveryRequired';$result.errorCode='OFFICE_LABS_STARTUP_RECOVERY_REQUIRED';$result.labsStartupRestored=$false;$code=1
        }
    }
    if(-not $WhatIfPreference -and $resultReserved){
        try{[IO.File]::WriteAllText($ResultPath,($result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding $false))}catch{$code=1;$result.status='ResultNotSaved'}
    }
}
if($WhatIfPreference){if($result.status -eq 'Failed'){Write-Output ('Office check blocked: '+$result.errorCode);exit 1};return}
if($code -eq 0){
    Write-OfficeUpdateProgress 'Complete' $language
    Write-Host ('Watchtower {0} | Warden {1}' -f $result.watchtowerVersion, $result.wardenVersion)
    if($result.startupCheck -and $result.startupCheck.Video -eq 'Verified'){
        Write-Host $(if($language -eq 'ru'){'Видео с камер проверено.'}else{'Camera video verified.'})
    }else{
        Write-Host $(if($language -eq 'ru'){'Проверка видео с камер ещё не завершена.'}else{'Camera video verification is pending.'})
    }
}elseif($result.status -eq 'ResultNotSaved'){
    Write-Host $(if($language -eq 'ru'){'Не удалось сохранить отчёт. Проверьте состояние Watchtower перед повторной попыткой.'}else{'The report could not be saved. Check Watchtower before retrying.'})
}elseif($result.status -eq 'RecoveryRequired'){
    Write-Host $(if($language -eq 'ru'){'Требуется восстановить запуск Labs.'}else{'Labs startup needs recovery.'})
}elseif($result.errorCode -eq 'INSTALL_CANCELLED'){
    Write-Host $(if($language -eq 'ru'){'Обновление отменено.'}else{'Update cancelled.'})
}elseif($result.Contains('rollbackVerified') -and $result.rollbackVerified){
    Write-Host $(if($language -eq 'ru'){'Обновление остановлено. Предыдущая версия восстановлена.'}else{'Update stopped. The previous version was restored.'})
}else{
    Write-Host $(if($language -eq 'ru'){'Обновление не завершено.'}else{'Update did not complete.'})
}
if($code -ne 0 -and $result.errorCode){Write-Host $(if($language -eq 'ru'){'Код: '+$result.errorCode}else{'Code: '+$result.errorCode})}
if($resultReserved -and $result.status -ne 'ResultNotSaved'){
    Write-Host $(if($language -eq 'ru'){'Отчёт: '+$ResultPath}else{'Report: '+$ResultPath})
}
exit $code
