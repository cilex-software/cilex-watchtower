#requires -Version 5.1
<#
.SYNOPSIS
Update the existing Office installation from a verified, extracted package.
.DESCRIPTION
Run on Office as its signed-in administrator. This uses the generic installer's
backup, startup/video verification and automatic rollback. -WhatIf is read-only.
No account, firewall, script-execution policy, automatic sign-in or Labs setting
is changed. Only the verified Watchtower/Warden installation is updated.
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

function Get-OfficeStartupSelection($Plan,$Marker,[object[]]$Tasks) {
    $expected=Join-Path $Plan.Directory $(if($Marker){'warden\warden-launcher.exe'}else{'warden\warden.exe'})
    $candidates=@()
    foreach($task in $Tasks){
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

$runId=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$language=if([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ru'){'ru'}else{'en'}
$result=[ordered]@{schemaVersion=1;runId=$runId;host=$env:COMPUTERNAME;status='Failed';errorCode=$null;watchtowerVersion=$null;wardenVersion=$null;sourceCommit=$null;backup=$null;rebootVerified=$false}
$code=1
$resultReserved=$false
try{
    if($env:OS -ne 'Windows_NT' -or $env:COMPUTERNAME -ne $ExpectedHost){throw 'OFFICE_TARGET_HOST_MISMATCH'}
    $verified=Test-OfficePackageTrust $PackagePath $ManifestSha256
    $helpers=Join-Path $verified.Root 'helpers'
    Import-Module (Join-Path $helpers 'Common.psm1') -Force
    $installer=Import-Module (Join-Path $helpers 'Install.psm1') -Force -PassThru
    $package=Test-WtgPackage $verified.Root $ManifestSha256
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
    Assert-OfficeLabsSafe $identity $session $tasks
    if(-not $PSCmdlet.ShouldProcess($ExpectedHost,'Update existing Watchtower and Warden from the verified package')){return}
    $principal=New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'OFFICE_ELEVATED_ADMINISTRATOR_REQUIRED'}
    if(-not $ResultPath){$ResultPath=Join-Path $identity.LocalAppData ('Cilex\Deploy\results\office-'+$runId+'.json')}
    $ResultPath=& $installer {param($p)Assert-WtgLocalPath $p} $ResultPath
    if(Test-Path -LiteralPath $ResultPath){throw 'OFFICE_RESULT_ALREADY_EXISTS'}
    [IO.Directory]::CreateDirectory((Split-Path -Parent $ResultPath))|Out-Null
    $reservation=[IO.File]::Open($ResultPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $reservation.Dispose();$resultReserved=$true
    $installed=Install-WtgPackage $context $verified.Root
    $result.status='Installed';$result.watchtowerVersion=$installed.Version;$result.wardenVersion=$installed.WardenVersion
    $result.sourceCommit=$installed.SourceCommit;$result.backup=$installed.Backup;$result.startupCheck=$installed.Runtime
    $code=0
}catch{
    $result.errorCode='OFFICE_UPDATE_FAILED'
    if($_.Exception.Message -match '^[A-Z][A-Z0-9_]{4,100}$'){$result.errorCode=$_.Exception.Message}
    if($_.Exception.Data.Contains('RollbackVerified')){$result.rollbackVerified=[bool]$_.Exception.Data['RollbackVerified']}
}finally{
    if(-not $WhatIfPreference -and $resultReserved){
        try{[IO.File]::WriteAllText($ResultPath,($result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding $false))}catch{$code=1;$result.status='ResultNotSaved'}
    }
}
if($WhatIfPreference){if($result.status -eq 'Failed'){Write-Output ('Office check blocked: '+$result.errorCode);exit 1};return}
if($code -eq 0){Write-Host $(if($language -eq 'ru'){'Watchtower и Warden обновлены. Перезагрузка не выполнялась.'}else{'Watchtower and Warden were updated. Windows was not restarted.'})}
else{Write-Host $(if($language -eq 'ru'){'Обновление не завершено. Код: '+$result.errorCode}else{'Update did not complete. Code: '+$result.errorCode})}
if($ResultPath){Write-Host $ResultPath}
exit $code
