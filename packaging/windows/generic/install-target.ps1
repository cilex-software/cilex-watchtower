#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PackagePath='', [string]$InstallDir='',
    [ValidateSet('User','Machine')][string]$InstallScope='User',
    [string]$TargetUser='', [string]$TargetSid='', [string]$ExpectedHost='',
    [ValidateSet('AfterSignIn','UnattendedReboot')][string]$StartupMode='AfterSignIn',
    [ValidateSet('en','ru')][string]$Language='en',
    [string]$BackendUrl='', [string]$ExpectedManifestSha256='', [string]$PackageSha256='',
    [string]$RunId='', [string]$ResultPath='', [string]$RequestPath='',
    [string]$AutologonPath='', [switch]$ConsentUnattended,
    [string[]]$OverrideRequirements=@(), [ValidateSet('Auto','Manual','Offline')][string]$DependencyMode='Offline',
    [switch]$NonInteractive, [switch]$Inspect, [switch]$VerifyOnly, [switch]$Uninstall,
    [switch]$AdoptExisting, [string]$LegacyTaskName='', [switch]$ElevatedResume, [switch]$EmitJson, [switch]$ConfirmNoManualSignIn
)
$ErrorActionPreference='Stop'
if([Console]::IsOutputRedirected){[Console]::OutputEncoding=New-Object Text.UTF8Encoding $false}
Set-StrictMode -Version 2
if($PSVersionTable.PSVersion.Major -eq 5){$env:PSModulePath=(Join-Path $PSHOME 'Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')}
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Install.psm1') -Force
if(-not $RunId){$RunId=[Guid]::NewGuid().ToString('N')}
if($RunId -notmatch '^[A-Za-z0-9_-]{8,80}$'){throw 'INSTALL_RUN_ID_INVALID'}
$exitCode=1
try{
    if($RequestPath){
        $request=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($request.RunId -ne $RunId){throw 'INSTALL_REQUEST_RUN_MISMATCH'}
        # Whitelist only non-secret, non-code deployment parameters.
        foreach($name in @('PackagePath','InstallDir','InstallScope','TargetUser','TargetSid','ExpectedHost','StartupMode','Language','BackendUrl','PackageManifestSha256','PackageSha256','AutologonPath','LegacyTaskName')){
            if($request.PSObject.Properties[$name]){
                $localName=$name;if($name -eq 'PackageManifestSha256'){$localName='ExpectedManifestSha256'}
                Set-Variable -Name $localName -Value ([string]$request.$name)
            }
        }
        foreach($name in @('ConsentUnattended','NonInteractive','Inspect','VerifyOnly','Uninstall','AdoptExisting','ConfirmNoManualSignIn')){if($request.PSObject.Properties[$name]){Set-Variable -Name $name -Value ([bool]$request.$name)}}
        if($request.PSObject.Properties['OverrideRequirements']){$OverrideRequirements=@($request.OverrideRequirements)}
        if($request.PSObject.Properties['DependencyMode']){$DependencyMode=[string]$request.DependencyMode}
    }
    if($ExpectedHost -and $env:COMPUTERNAME -ne $ExpectedHost){throw 'TARGET_HOST_MISMATCH'}
    $identity=Resolve-WtgTargetIdentity -TargetUser $TargetUser -ExpectedSid $TargetSid
    if($Inspect){
        $result=[pscustomobject]@{RunId=$RunId;Target=$env:COMPUTERNAME;Status='Inspected';TargetSid=$identity.Sid;TargetUser=$identity.Name;Profile=$identity.Profile;LocalAppData=$identity.LocalAppData;AppData=$identity.AppData;ProgramFiles=$env:ProgramFiles;OS=[Environment]::OSVersion.Version.ToString();X64=[Environment]::Is64BitOperatingSystem;BootUTC=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')}
        $exitCode=0
    }else{
        if(-not $ResultPath){$ResultPath=Join-Path $identity.LocalAppData ('CilexWatchtower\Deployment\runs\'+$RunId+'\result.json')}
        $runDir=Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath));[IO.Directory]::CreateDirectory($runDir)|Out-Null
        $context=[pscustomobject]@{RunId=$RunId;RunDir=$runDir;InstallDir=$InstallDir;InstallScope=$InstallScope;TargetUser=$identity.Name;TargetSid=$identity.Sid;ExpectedHost=$ExpectedHost;StartupMode=$StartupMode;Language=$Language;BackendUrl=$BackendUrl;PackageManifestSha256=$ExpectedManifestSha256;PackageSha256=$PackageSha256;NonInteractive=[bool]$NonInteractive;AutologonPath=$AutologonPath;ConsentUnattended=[bool]$ConsentUnattended;AdoptExisting=[bool]$AdoptExisting;LegacyTaskName=$LegacyTaskName;OverrideRequirements=$OverrideRequirements;DependencyMode=$DependencyMode;ConfirmNoManualSignIn=[bool]$ConfirmNoManualSignIn}
        if($VerifyOnly){$result=Get-WtgStartupVerification $context;$exitCode=2}
        else{
            try{
                if($Uninstall){$result=Uninstall-WtgPackage $context;$exitCode=0}
                else{$result=Install-WtgPackage $context $PackagePath;$exitCode=2}
            }catch{
                if($_.Exception.Message -ne 'INSTALL_ELEVATION_REQUIRED' -or $ElevatedResume -or $NonInteractive){throw}
                # Persist only the explicit non-secret request; target SID survives alternate-admin UAC.
                $resume=Join-Path $runDir 'elevation-request.json'
                $data=[ordered]@{};foreach($p in $context.PSObject.Properties){$data[$p.Name]=$p.Value}
                $data.PackagePath=$PackagePath;$data.Uninstall=[bool]$Uninstall
                Write-WtgJson -Path $resume -Value $data
                $script=Join-Path $PSScriptRoot 'install-target.ps1'
                $arguments='-NoProfile -File "'+$script+'" -RequestPath "'+$resume+'" -ResultPath "'+$ResultPath+'" -RunId '+$RunId+' -ElevatedResume'
                $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $child=Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
                try{while(-not $child.WaitForExit(1000)){};$exitCode=$child.ExitCode}finally{$child.Dispose()}
                if(-not(Test-Path -LiteralPath $ResultPath)){throw 'INSTALL_ELEVATED_RESULT_MISSING'}
                $result=Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8|ConvertFrom-Json
                if($result.RunId -ne $RunId){throw 'INSTALL_ELEVATED_RESULT_MISMATCH'}
            }
        }
    }
}catch{
    # Exception text may originate from a vendor command; expose only approved symbolic codes.
    $code='INSTALL_FAILED';if($_.Exception.Message -match '^[A-Z][A-Z0-9_]{4,100}$'){$code=$_.Exception.Message}
    if($code -eq 'PREREQUISITE_RESTART_REQUIRED'){$exitCode=3010}
    $result=[pscustomobject]@{RunId=$RunId;Target=$env:COMPUTERNAME;Status=$(if($exitCode -eq 3010){'RestartRequired'}else{'Failed'});ErrorCode=$code}
    if($_.Exception.Data.Contains('InstallFailure')){
        $diagnostics=[ordered]@{Install=$_.Exception.Data['InstallFailure'];RollbackVerified=[bool]$_.Exception.Data['RollbackVerified']}
        if($_.Exception.Data.Contains('RollbackFailure')){$diagnostics.Rollback=$_.Exception.Data['RollbackFailure']}
        $result|Add-Member -NotePropertyName Diagnostics -NotePropertyValue $diagnostics
    }
    if($_.Exception.Data.Contains('ProbeStatusPath')){
        $recovery=[ordered]@{ProbeStatusPath=[string]$_.Exception.Data['ProbeStatusPath']}
        if($_.Exception.Data.Contains('RetainedTask')){$recovery.RetainedTask=[string]$_.Exception.Data['RetainedTask'];$recovery.CleanupVerified=$false}
        $result|Add-Member -NotePropertyName Recovery -NotePropertyValue $recovery
    }
    if(-not $EmitJson){Write-Host (Get-WtgInstallFailureText -Code $code -Language $Language)}
}
if($ResultPath){Write-WtgJson -Path $ResultPath -Value $result}
if($EmitJson){$result|ConvertTo-Json -Depth 12 -Compress}
elseif($result.Status -ne 'Failed'){
    $message=if($Language -eq 'ru'){'Работа завершена. Проверки входа, перезагрузки и подключения к серверу могут ещё требоваться.'}else{'Completed. Sign-in, reboot and backend checks may still be required.'}
    if($ResultPath){$message += ' '+$ResultPath};Write-Host $message
}
exit $exitCode
