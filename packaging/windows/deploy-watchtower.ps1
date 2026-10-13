#requires -Version 5.1
<#
.SYNOPSIS
Build, package and install Cilex Watchtower on Windows. Separate from the station updater.
.DESCRIPTION
Check/WhatIf are read-only. BuildInstaller creates a complete offline installer.
Use -GhToken (Read-Host -AsSecureString) for a private repository; never paste a token into an argument.
#>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Low')]
param(
    [ValidateSet('Check','Build','Install','RemoteInstall','BuildInstaller')][string]$Mode='Install',
    [string]$Repository='https://github.com/romayankin/cilex-watchtower.git',
    [string]$Tag,
    [Alias('gh_token')][Security.SecureString]$GhToken,
    [string]$PackagePath,[string]$PackageSha256,[string]$PackageManifestSha256,
    [string]$SourceDirectory,[string]$SourceCommit,[string]$SourceBundle,[string]$SourceSha256,
    [string]$InstallDir,[ValidateSet('User','Machine')][string]$InstallScope='User',
    [string]$TargetHost,[string]$TargetUser,[string]$ExpectedHost,
    [PSCredential]$Credential,[ValidateSet('WinRM','SMBService')][string]$Transport='WinRM',
    [string]$RemoteStagePath,[string]$RemoteStageLocalPath,
    [ValidateSet('AfterSignIn','UnattendedReboot')][string]$StartupMode,
    [string]$BackendUrl,[ValidateSet('Auto','en','ru')][string]$Language='Auto',
    [ValidateSet('Auto','Manual','Offline')][string]$DependencyMode='Auto',
    [string]$CacheDir,[string]$WorkDir,[string]$OutputDir,
    [string[]]$OverrideRequirements=@(),[switch]$NonInteractive,[switch]$AcceptPlan,[switch]$AcceptLicenses,
    [hashtable]$Tools=@{},[ValidateRange(1,64)][int]$BuildJobs=2,
    [ValidateSet('Build','Target')][string]$CheckRole='Target',
    [switch]$Json,[switch]$CreateBootstrapBundle,
    [string]$SigningThumbprint,[string]$TimestampUrl,
    [switch]$AdoptExisting,[string]$LegacyTaskName,
    [switch]$ConsentUnattended,[string]$AutologonPath,
    [switch]$VerifyOnly,[string]$ResumeRunId,[switch]$ConfirmNoManualSignIn,
    [switch]$DeferEnrollment
)
$ErrorActionPreference='Stop'
if([Console]::IsOutputRedirected){[Console]::OutputEncoding=New-Object Text.UTF8Encoding $false}
$moduleRoot=Join-Path $PSScriptRoot 'generic'
Import-Module (Join-Path $moduleRoot 'Common.psm1')
$Language=Get-WtgLanguage $Language
$base=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Cilex\Deploy'
if(-not $CacheDir){$CacheDir=Join-Path $base 'cache'}
if(-not $WorkDir){$WorkDir=Join-Path $base 'work'}
if(-not $OutputDir){$OutputDir=Join-Path $base 'output'}
$defaultInstall=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\Cilex Watchtower'
if(-not $InstallDir -and -not $TargetHost -and -not $TargetUser){
    if($InstallScope -eq 'Machine'){$InstallDir=Join-Path $env:ProgramFiles 'Cilex Watchtower'}else{$InstallDir=$defaultInstall}
}
$runId=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$context=[pscustomobject]@{
    Mode=$Mode;Language=$Language;NonInteractive=[bool]$NonInteractive;DependencyMode=$DependencyMode
    CacheDir=$CacheDir;WorkDir=$WorkDir;OutputDir=$OutputDir;RunDir='';RunId=$runId
    Repository=$Repository;Tag=$Tag;InstallDir=$InstallDir;InstallScope=$InstallScope
    TargetUser=$TargetUser;TargetHost=$TargetHost;ExpectedHost=$ExpectedHost;StartupMode=$StartupMode
    BackendUrl=$BackendUrl;OverrideRequirements=$OverrideRequirements;AcceptLicenses=[bool]$AcceptLicenses
    BuildJobs=$BuildJobs;Tools=$Tools;PackageSha256=$PackageSha256;PackageManifestSha256=$PackageManifestSha256
    SigningThumbprint=$SigningThumbprint;TimestampUrl=$TimestampUrl;AdoptExisting=[bool]$AdoptExisting
    LegacyTaskName=$LegacyTaskName;ConsentUnattended=[bool]$ConsentUnattended;AutologonPath=$AutologonPath
    RemoteStageLocalPath=$RemoteStageLocalPath;VerifyOnly=[bool]$VerifyOnly;ResumeRunId=$ResumeRunId
    DeferEnrollment=[bool]$DeferEnrollment;ConfirmNoManualSignIn=[bool]$ConfirmNoManualSignIn
}
$result=[ordered]@{SchemaVersion=1;RunId=$runId;Mode=$Mode;Status='Preparing';StartedUTC=[DateTime]::UtcNow.ToString('o');Source=$null;Checks=@();AcceptedFindings=@();Build=$null;Installer=$null;Installation=$null;Error=$null;ExitCode=$null}
$exitCode=1;$entryLock=$null
try {
    if($env:OS -ne 'Windows_NT'){throw (Get-WtgMessage WindowsOnly -Language $Language)}
    if($WhatIfPreference){
        Write-WtgMessage $context Plan @($Mode, $(if($TargetHost){$TargetHost}else{$env:COMPUTERNAME}), $(if($PackagePath){$PackagePath}elseif($Tag){$Tag}else{'main'}))
        Write-WtgMessage $context Preview
        return
    }
    if($VerifyOnly -and $Mode -notin @('Install','RemoteInstall')){throw (Get-WtgMessage InputConflict @('VerifyOnly / '+$Mode) $Language)}
    if($ConfirmNoManualSignIn -and -not $VerifyOnly){throw (Get-WtgMessage InputConflict @('ConfirmNoManualSignIn requires VerifyOnly') $Language)}
    if($ResumeRunId -and $Mode -ne 'RemoteInstall'){throw (Get-WtgMessage InputConflict @('ResumeRunId / '+$Mode) $Language)}
    if($SourceDirectory -and $SourceBundle){throw (Get-WtgMessage InputConflict @('SourceDirectory / SourceBundle') $Language)}
    if($Tag -and ($SourceDirectory -or $SourceBundle)){throw (Get-WtgMessage InputConflict @('Tag / SourceDirectory / SourceBundle') $Language)}
    if($PackagePath -and $Mode -notin @('Install','RemoteInstall','Check')){throw (Get-WtgMessage InputConflict @('PackagePath / '+$Mode) $Language)}
    if($PackagePath -and ($Tag -or $SourceDirectory -or $SourceBundle -or $GhToken)){throw (Get-WtgMessage InputConflict @('PackagePath / source selection or GitHub credential') $Language)}
    if($Mode -eq 'RemoteInstall' -and (-not $TargetHost -or -not $TargetUser)){throw (Get-WtgMessage RequiredInputs @('TargetHost, TargetUser') $Language)}
    if($TargetHost -and $Mode -notin @('RemoteInstall','Check')){throw (Get-WtgMessage InputConflict @('TargetHost / '+$Mode) $Language)}
    if($TargetHost -and $TargetHost -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$'){throw (Get-WtgMessage InvalidHost -Language $Language)}
    if($BackendUrl){
        $uri=$null
        if(-not [Uri]::TryCreate($BackendUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment){throw (Get-WtgMessage InvalidBackend -Language $Language)}
    }
    Import-Module (Join-Path $moduleRoot 'Requirements.psm1')
    $buildNeeded=-not $PackagePath -and $Mode -ne 'Check' -and -not $VerifyOnly -and -not $ResumeRunId
    $roles=if($Mode -eq 'Check'){@($CheckRole)}elseif($buildNeeded -and $Mode -eq 'Install'){@('Build','Target')}elseif($buildNeeded){@('Build')}else{@('Target')}
    if($Mode -eq 'RemoteInstall' -and -not $buildNeeded){$roles=@()}
    if($VerifyOnly -or $ResumeRunId){$roles=@()}
    do {
        if(-not $Json){Write-WtgMessage $context Checking}
        $findings=@()
        foreach($role in $roles){$findings+=@(Get-WtgRequirements -Context $context -Role $role)}
        $findings=@(Merge-WtgFindings $findings)
        if($TargetHost -and $Mode -eq 'Check'){
            $message=if($Language -eq 'ru'){'Показаны проверки локального компьютера. Удалённый компьютер будет проверен перед установкой.'}else{'These are local checks. Remote target requirements and identity are checked before installation.'}
            $findings+=[pscustomobject]@{Id='remote.deferred';State='UNKNOWN';Message=$message;CanOverride=$false}
        }
        $result.Checks=$findings
        if($Mode -eq 'Check'){
            $result.Status='Checked';$result.ExitCode=0
            if(@($findings|Where-Object State -eq 'BLOCKED').Count){$result.ExitCode=10}
            elseif(@($findings|Where-Object State -ne 'PASS').Count){$result.ExitCode=2}
            if($Json){$result|ConvertTo-Json -Depth 12}else{foreach($f in $findings){Write-Host ('{0} [{1}]: {2}' -f (Get-WtgMessage ('State'+$f.State) -Language $Language),$f.Id,$f.Message)}}
            exit $result.ExitCode
        }
        foreach($f in @($findings|Where-Object State -ne 'PASS')){Write-Host ('{0} [{1}]: {2}' -f (Get-WtgMessage ('State'+$f.State) -Language $Language),$f.Id,$f.Message)}
        $blocked=@($findings|Where-Object { $_.State -eq 'BLOCKED' -and -not $_.CanOverride })
        if($blocked.Count){$exitCode=10;throw (Get-WtgMessage Blocked @(($blocked.Message -join ' ')) $Language)}
        $needsConsent=@($findings|Where-Object { $_.State -ne 'PASS' -and $_.CanOverride -and $_.Id -notin $context.OverrideRequirements })
        if(-not $needsConsent.Count){break}
        if($NonInteractive){$exitCode=10;throw (Get-WtgMessage OverrideRequired @(($needsConsent.Id -join ', ')) $Language)}
        $choice=Read-Host (Get-WtgMessage Requirements -Language $Language)
        if($choice -match '^(?i)c$'){$context.OverrideRequirements+=@($needsConsent.Id);break}
        if($choice -notmatch '^(?i)r$'){$exitCode=3;throw (Get-WtgMessage Cancelled -Language $Language)}
    }while($true)
    $result.AcceptedFindings=@($context.OverrideRequirements)
    if($Mode -in @('Install','RemoteInstall') -and -not $VerifyOnly -and -not $ResumeRunId){
        if(-not $context.StartupMode){
            if($NonInteractive){$exitCode=3;throw (Get-WtgMessage StartupRequired -Language $Language)}
            $startupChoice=Read-Host (Get-WtgMessage Startup -Language $Language)
            if($startupChoice -eq '1'){$context.StartupMode='AfterSignIn'}elseif($startupChoice -eq '2'){$context.StartupMode='UnattendedReboot'}else{$exitCode=3;throw (Get-WtgMessage Cancelled -Language $Language)}
        }
        if(-not $context.BackendUrl -and -not $DeferEnrollment){
            if($NonInteractive){throw (Get-WtgMessage RequiredInputs @('BackendUrl or DeferEnrollment') $Language)}
            $context.BackendUrl=Read-Host (Get-WtgMessage Backend -Language $Language)
            if(-not $context.BackendUrl){$context.DeferEnrollment=$true}
        }
    }
    if($context.BackendUrl){
        $uri=$null
        if(-not [Uri]::TryCreate($context.BackendUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $context.BackendUrl -match '[\r\n,]'){throw (Get-WtgMessage InvalidBackend -Language $Language)}
    }
    Write-WtgMessage $context Plan @($Mode, $(if($TargetHost){$TargetHost}else{$env:COMPUTERNAME}), $(if($PackagePath){$PackagePath}elseif($Tag){$Tag}else{'main'}))
    if(-not $AcceptPlan -and -not $VerifyOnly -and -not $ResumeRunId){
        if($NonInteractive){$exitCode=3;throw (Get-WtgMessage RequiredInputs @('AcceptPlan') $Language)}
        if((Read-Host (Get-WtgMessage PlanAccept -Language $Language)) -notmatch '^(?i)y$'){$exitCode=3;throw (Get-WtgMessage Cancelled -Language $Language)}
    }
    if(-not $PSCmdlet.ShouldProcess($(if($TargetHost){$TargetHost}else{$env:COMPUTERNAME}),$Mode)){return}
    $forbidden=@($env:SystemRoot,$defaultInstall,$context.InstallDir)
    foreach($name in @('CacheDir','WorkDir','OutputDir')){
        $context.$name=Resolve-WtgSafeDirectory -Path $context.$name -ForbiddenRoots $forbidden -AllowExisting
        $null=New-Item -ItemType Directory -Path $context.$name -Force
    }
    $context.RunDir=Resolve-WtgSafeDirectory -Path (Join-Path $context.WorkDir $context.RunId)
    $null=New-Item -ItemType Directory -Path $context.RunDir
    $entryLock=[IO.File]::Open((Join-Path $context.WorkDir 'deployment.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    Write-WtgJson -Path (Join-Path $context.RunDir 'result.json') -Value $result
    if($VerifyOnly -or $ResumeRunId){
        Import-Module (Join-Path $moduleRoot 'Install.psm1')
        if($Mode -eq 'RemoteInstall'){
            Import-Module (Join-Path $moduleRoot 'Remote.psm1')
            $result.Installation=Install-WtgRemotePackage -Context $context -PackagePath $PackagePath -Credential $Credential -Transport $Transport -RemoteStagePath $RemoteStagePath
        }else{$result.Installation=Get-WtgStartupVerification -Context $context}
    }else{
        if($buildNeeded){
            Import-Module (Join-Path $moduleRoot 'Dependencies.psm1')
            Write-WtgMessage $context Dependency
            $exitCode=11
            $context.Tools=Initialize-WtgDependencies -Context $context -ForInstaller:($Mode -eq 'BuildInstaller')
            Import-Module (Join-Path $moduleRoot 'Source.psm1')
            Write-WtgMessage $context Source
            $exitCode=12
            $source=Get-WtgSource -Context $context -GhToken $GhToken -SourceDirectory $SourceDirectory -SourceCommit $SourceCommit -SourceBundle $SourceBundle -SourceSha256 $SourceSha256
            $result.Source=$source
            Import-Module (Join-Path $moduleRoot 'Build.psm1') -DisableNameChecking
            Write-WtgMessage $context Building
            $exitCode=13
            $artifact=Build-WtgArtifact -Context $context -Source $source
            $result.Build=$artifact;$PackagePath=$artifact.PackagePath
            $context.PackageManifestSha256=Get-WtgSha256 (Join-Path $PackagePath 'manifest.json')
            if($Mode -eq 'BuildInstaller'){
                Write-WtgMessage $context Packaging
                $result.Installer=New-WtgInstaller -Context $context -PackagePath $PackagePath
            }
        }
        if($Mode -in @('Install','RemoteInstall')){
            Write-WtgMessage $context Installing
            $exitCode=14
            if($Mode -eq 'RemoteInstall'){
                Import-Module (Join-Path $moduleRoot 'Remote.psm1')
                $result.Installation=Install-WtgRemotePackage -Context $context -PackagePath $PackagePath -Credential $Credential -Transport $Transport -RemoteStagePath $RemoteStagePath
            }else{
                $request=[ordered]@{}
                foreach($property in $context.PSObject.Properties){if($property.Name -ne 'Tools'){$request[$property.Name]=$property.Value}}
                $request.PackagePath=[IO.Path]::GetFullPath($PackagePath)
                $requestFile=Join-Path $context.RunDir 'install-request.json'
                $installResultFile=Join-Path $context.RunDir 'install-result.json'
                Write-WtgJson -Path $requestFile -Value $request
                $helper=Join-Path $moduleRoot 'install-target.ps1'
                $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $null=Invoke-WtgProcess -FilePath $ps -Arguments @('-NoProfile','-File',$helper,'-RequestPath',$requestFile,'-ResultPath',$installResultFile,'-RunId',$context.RunId) -TimeoutSeconds 1800 -KeepOnTimeout -AllowedExitCodes @(0,2,3010) -OutputEncoding utf-8 -LogPath (Join-Path $context.RunDir 'installation.log')
                $result.Installation=Get-Content -LiteralPath $installResultFile -Raw -Encoding UTF8|ConvertFrom-Json
                if($result.Installation.RunId -ne $context.RunId -or $result.Installation.Status -eq 'Failed'){throw 'Installation failed or its result could not be verified.'}
            }
        }
    }
    if($CreateBootstrapBundle){
        Import-Module (Join-Path $moduleRoot 'Build.psm1') -DisableNameChecking
        $result.Bootstrap=New-WtgBootstrapBundle -Context $context
    }
    $result.Status='CompletedWithDeferredChecks';$exitCode=2
    if($Mode -eq 'Build'){$result.Status='BuildVerified';$exitCode=0}
    elseif($Mode -eq 'BuildInstaller'){$result.Status='InstallerBuilt';$exitCode=0}
    elseif($result.Installation -and $result.Installation.Status -eq 'RestartRequired'){$result.Status='RestartRequired';$exitCode=3010}
    $result.ExitCode=$exitCode;$result.CompletedUTC=[DateTime]::UtcNow.ToString('o')
    $resultPath=Join-Path $context.RunDir 'result.json';Write-WtgJson -Path $resultPath -Value $result
    Write-WtgMessage $context $(if($exitCode -eq 0){'Finished'}else{'Deferred'}) @($resultPath)
    Write-WtgMessage $context NoClaim
}catch{
    $message=Protect-WtgText $_.Exception.Message
    $restartRequired=$false
    for($cause=$_.Exception;$null -ne $cause;$cause=$cause.InnerException){
        if($cause.Data.Contains('WtgRestartRequired') -and $cause.Data['WtgRestartRequired'] -eq $true){$restartRequired=$true;break}
    }
    if($restartRequired){$exitCode=3010}
    $result.Status=if($restartRequired){'RestartRequired'}elseif($exitCode -eq 3){'Cancelled'}else{'Failed'};$result.Error=$message;$result.ExitCode=$exitCode
    $displayMessage=$message
    if($message -eq 'REMOTE_SERVICE_CLEANUP_UNCONFIRMED'){
        $result.Recovery=[ordered]@{}
        foreach($key in @('ServiceName','RunId','NativeError','ResultPath')){
            if($_.Exception.Data.Contains($key)){$result.Recovery[$key]=Protect-WtgText ([string]$_.Exception.Data[$key])}
        }
        $displayMessage=if($Language -eq 'ru'){'Установка могла завершиться, но удаление временной службы не подтверждено. Проверьте сохранённый результат и указанную службу перед повторной попыткой.'}else{'Installation may have completed, but temporary service removal was not confirmed. Review the saved result and recorded service before retrying.'}
    }elseif($message -match '^[A-Z][A-Z0-9_]{4,100}$'){
        Import-Module (Join-Path $moduleRoot 'Install.psm1')
        $displayMessage=Get-WtgInstallFailureText $message $Language
    }
    if($context.RunDir -and (Test-Path -LiteralPath $context.RunDir)){
        $resultPath=Join-Path $context.RunDir 'result.json'
        Write-WtgJson -Path $resultPath -Value $result
        if($restartRequired){Write-Host $displayMessage}else{Write-WtgMessage $context Failed @($displayMessage)}
        Write-WtgMessage $context Log @($resultPath)
    }else{if($restartRequired){Write-Host $displayMessage}else{Write-WtgMessage $context Failed @($displayMessage)}}
}finally{if($entryLock){$entryLock.Dispose()}}
exit $exitCode
