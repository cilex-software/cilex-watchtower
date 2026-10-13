#requires -Version 5.1
# Pure fixtures: no connection, service, task, application, or credentials are used.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot '..\Remote.psm1') -Force
$script:passed=0
function Assert($Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:passed++}
function Reject([scriptblock]$Action,[string]$Code){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true;if($_.Exception.Message -notlike "*$Code*"){throw}};Assert $failed $Code}
$stage=Get-WtgRemoteStage 'OFFICE-PC' '' 'fixture01'
Assert ($stage.UNC -eq '\\OFFICE-PC\C$\CilexWatchtower-Deploy\fixture01') 'default UNC documented correctly'
Assert ($stage.Local -eq 'C:\CilexWatchtower-Deploy\fixture01') 'default local target mapping'
$custom=Get-WtgRemoteStage 'NEW-PC' '\\NEW-PC\D$\staging' 'fixture02'
Assert ($custom.Local -eq 'D:\staging\fixture02') 'alternate drive mapping'
Reject {Get-WtgRemoteStage 'NEW-PC' '\\OTHER-PC\C$\stage' 'fixture03'} 'REMOTE_STAGE_HOST_MISMATCH'
Reject {Get-WtgRemoteStage 'NEW-PC' '\\NEW-PC\C$\stage\..\Windows' 'fixture03'} 'REMOTE_STAGE_PATH_INVALID'
Reject {Get-WtgRemoteStage 'NEW-PC' '\\NEW-PC\ordinary\stage' 'fixture03'} 'REMOTE_NONADMIN_SHARE_LOCAL_PATH_REQUIRED'
$share=Get-WtgRemoteStage 'NEW-PC' '\\NEW-PC\ordinary\stage' 'fixture04' 'D:\shared\stage'
Assert ($share.Local -eq 'D:\shared\stage\fixture04') 'ordinary share explicit mapping'
Reject {Get-WtgRemoteStage 'NEW-PC & command' '' 'fixture05'} 'REMOTE_TARGET_OR_RUN_INVALID'
Reject {Get-WtgRemoteStage 'NEW-PC' '' '../bad'} 'REMOTE_TARGET_OR_RUN_INVALID'
$ctx=[pscustomobject]@{RunId='fixture06';InstallDir='D:\Apps\Cilex Watchtower';InstallScope='User';TargetUser='NEW-PC\Operator';StartupMode='AfterSignIn';Language='ru';BackendUrl='https://backend.example';GhToken='DISPOSABLE-SENTINEL-NOT-A-CREDENTIAL';Credential='DISPOSABLE-CREDENTIAL-SENTINEL';Password='DISPOSABLE-PASSWORD-SENTINEL'}
$req=New-WtgRemoteRequest $ctx 'D:\stage\package' ('a'*64) 'NEW-PC' 'S-1-5-21-1-2-3-1001'
$json=$req|ConvertTo-Json -Depth 8
Assert ($json -notmatch 'SENTINEL') 'remote request excludes all credential fields'
Assert ($req.TargetSid -eq 'S-1-5-21-1-2-3-1001') 'remote target SID pinned'
Assert $req.NonInteractive 'remote worker cannot prompt for secrets'
$result=[pscustomobject]@{RunId='fixture06';Target='NEW-PC';TargetSid='S-1-5-21-1-2-3-1001';Status='InstalledWithDeferredChecks'}
Assert ((Assert-WtgRemoteResult $result 'fixture06' 'NEW-PC' 'S-1-5-21-1-2-3-1001').Status -eq 'InstalledWithDeferredChecks') 'matching result accepted'
Reject {Assert-WtgRemoteResult ([pscustomobject]@{RunId='fixture06';Target='NEW-PC';Status='InstalledWithDeferredChecks'}) 'fixture06' 'NEW-PC'} 'REMOTE_RESULT_USER_MISMATCH'
Reject {Assert-WtgRemoteResult ([pscustomobject]@{RunId='fixture06';Target='NEW-PC';TargetSid=$result.TargetSid;Status='Running'}) 'fixture06' 'NEW-PC'} 'REMOTE_RESULT_STATUS_INVALID'
Reject {Assert-WtgRemoteResult ([pscustomobject]@{RunId='fixture06';Target='NEW-PC'}) 'fixture06' 'NEW-PC'} 'REMOTE_RESULT_INVALID'
$restart=[pscustomobject]@{RunId='fixture06';Target='NEW-PC';Status='RestartRequired';ErrorCode='PREREQUISITE_RESTART_REQUIRED'}
Assert ((Assert-WtgRemoteResult $restart 'fixture06' 'NEW-PC').Status -eq 'RestartRequired') 'restart is a distinct terminal result without claiming an installed account'
$restart.ErrorCode='UNKNOWN'
Reject {Assert-WtgRemoteResult $restart 'fixture06' 'NEW-PC'} 'REMOTE_RESULT_INVALID'
Reject {Assert-WtgRemoteResult $result 'different' 'NEW-PC'} 'REMOTE_RESULT_IDENTITY_MISMATCH'
Reject {Assert-WtgRemoteResult $result 'fixture06' 'OTHER-PC'} 'REMOTE_RESULT_IDENTITY_MISMATCH'
Reject {Assert-WtgRemoteResult $result 'fixture06' 'NEW-PC' 'S-1-5-21-4-5-6-1001'} 'REMOTE_RESULT_USER_MISMATCH'
$result.Status='Failed'
Reject {Assert-WtgRemoteResult $result 'fixture06' 'NEW-PC'} 'REMOTE_TARGET_OPERATION_FAILED'
$ctx|Add-Member -NotePropertyName OverrideRequirements -NotePropertyValue @('graphics.adapter')
$ctx|Add-Member -NotePropertyName VerifyOnly -NotePropertyValue $true
$req=New-WtgRemoteRequest $ctx '' '' 'NEW-PC'
Assert $req.VerifyOnly 'read-only verification mode survives remote request'
Assert ($req.OverrideRequirements -contains 'graphics.adapter') 'explicit accepted warnings survive remote request'
$ctx.StartupMode=''
$verificationRequest=New-WtgRemoteRequest $ctx '' '' 'NEW-PC'
Assert ($verificationRequest.StartupMode -eq 'AfterSignIn') 'verification request supplies a valid inert startup value when no setup choice is needed'
function Confirm-FixtureStartupValue {param([ValidateSet('AfterSignIn','UnattendedReboot')][string]$StartupMode='AfterSignIn',$Request)Set-Variable -Name StartupMode -Value ([string]$Request.StartupMode);return $StartupMode}
Assert ((Confirm-FixtureStartupValue -Request $verificationRequest) -eq 'AfterSignIn') 'request survives the actual ValidateSet variable assignment used by the target'
$ctx.StartupMode='AfterSignIn'
Assert (Test-WtgSmbIntegrity ([pscustomobject]@{RequireSecuritySignature=$true})) 'mandatory SMB signing proves integrity without privileged connection inventory'
Assert (-not(Test-WtgSmbIntegrity ([pscustomobject]@{RequireSecuritySignature=$false}))) 'optional signing alone does not prove integrity'
Assert (Test-WtgSmbIntegrity $null @([pscustomobject]@{ShareName='C$';Encrypted=$true}) 'C$') 'staging-share encryption proves integrity'
Assert (Test-WtgSmbIntegrity $null @([pscustomobject]@{ShareName='C$';Signed=$true}) 'C$') 'staging-share signing proves integrity'
Assert (-not(Test-WtgSmbIntegrity $null @([pscustomobject]@{ShareName='C$';Signed=$false;Encrypted=$false}) 'C$')) 'unprotected connection rejected'
Assert (-not(Test-WtgSmbIntegrity $null @([pscustomobject]@{ShareName='Other';Encrypted=$true};[pscustomobject]@{ShareName='C$';Encrypted=$false}) 'C$')) 'encrypted unrelated share does not authorize the staging share'
Assert (-not(Test-WtgSmbIntegrity $null @([pscustomobject]@{ShareName='C$';Encrypted=$true};[pscustomobject]@{ShareName='C$';Encrypted=$false}) 'C$')) 'ambiguous staging connections require protection on every candidate'
Assert (-not(Test-WtgSmbIntegrity $null @([pscustomobject]@{Encrypted=$true}) 'C$')) 'missing share identity cannot prove integrity'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('cilex-remote-tests-'+[Guid]::NewGuid().ToString('N'))
try{
    $source=Join-Path $fixture 'source';$destination=Join-Path $fixture 'target'
    [IO.Directory]::CreateDirectory((Join-Path $source 'payload'))|Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'manifest.json'),'{}')
    [IO.File]::WriteAllText((Join-Path $source 'payload\fixture.dll'),'fixture')
    [IO.File]::WriteAllText((Join-Path $source 'unexpected-private-data.txt'),'not part of package')
    $module=Get-Module Remote
    $resumeContext=[pscustomobject]@{TargetUser='NEW-PC\Operator';InstallDir='D:\Apps\Cilex Watchtower';InstallScope='User';StartupMode='AfterSignIn';VerifyOnly=$false}
    $savedRequest=[pscustomobject]@{RunId='fixture06';ExpectedHost='NEW-PC';TargetSid='S-1-5-21-1-2-3-1001';TargetUser=$resumeContext.TargetUser;InstallDir=$resumeContext.InstallDir;InstallScope='User';StartupMode='AfterSignIn';VerifyOnly=$false;PackageManifestSha256=('a'*64)}
    $savedResult=[pscustomobject]@{RunId='fixture06';Target='NEW-PC';TargetSid=$savedRequest.TargetSid;Status='InstalledWithDeferredChecks';InstallDir=$savedRequest.InstallDir;InstallScope='User';StartupMode='AfterSignIn';ManifestSha256=('a'*64);Runtime=[pscustomobject]@{State='VerifiedCurrentSession'}}
    function Retained {return [pscustomobject]@{Request=($savedRequest|ConvertTo-Json);Result=($savedResult|ConvertTo-Json)}}
    $resumed=& $module {param($r,$c)Assert-WtgRetainedOutcome $r $c 'fixture06' 'NEW-PC' 'S-1-5-21-1-2-3-1001'} (Retained) $resumeContext
    Assert ($resumed.Status -eq 'InstalledWithDeferredChecks') 'retained result requires the original account and install intent'
    $savedRequest.TargetSid='S-1-5-21-1-2-3-1002'
    Reject {& $module {param($r,$c)Assert-WtgRetainedOutcome $r $c 'fixture06' 'NEW-PC' 'S-1-5-21-1-2-3-1001'} (Retained) $resumeContext} 'REMOTE_RETAINED_REQUEST_IDENTITY_MISMATCH'
    $savedRequest.TargetSid=$savedResult.TargetSid
    $savedResult.ManifestSha256='b'*64
    Reject {& $module {param($r,$c)Assert-WtgRetainedOutcome $r $c 'fixture06' 'NEW-PC' 'S-1-5-21-1-2-3-1001'} (Retained) $resumeContext} 'REMOTE_RETAINED_PACKAGE_MISMATCH'
    $savedResult.ManifestSha256='a'*64;$savedResult.InstallDir='D:\Other'
    Reject {& $module {param($r,$c)Assert-WtgRetainedOutcome $r $c 'fixture06' 'NEW-PC' 'S-1-5-21-1-2-3-1001'} (Retained) $resumeContext} 'REMOTE_RETAINED_RESULT_INTENT_MISMATCH'
    $savedResult.InstallDir=$savedRequest.InstallDir;$resumeContext.StartupMode='UnattendedReboot'
    Reject {& $module {param($r,$c)Assert-WtgRetainedOutcome $r $c 'fixture06' 'NEW-PC' 'S-1-5-21-1-2-3-1001'} (Retained) $resumeContext} 'REMOTE_RETAINED_REQUEST_INTENT_MISMATCH'
    $resumeContext.StartupMode='AfterSignIn';$savedResult.Status='Inspected'
    Reject {& $module {param($r,$c)Assert-WtgRetainedOutcome $r $c 'fixture06' 'NEW-PC' 'S-1-5-21-1-2-3-1001'} (Retained) $resumeContext} 'REMOTE_RESULT_STATUS_INVALID'
    $savedResult.Status='InstalledWithDeferredChecks';$savedResult.PSObject.Properties.Remove('TargetSid')
    Reject {& $module {param($r,$c)Assert-WtgRetainedOutcome $r $c 'fixture06' 'NEW-PC' 'S-1-5-21-1-2-3-1001'} (Retained) $resumeContext} 'REMOTE_RESULT_USER_MISMATCH'
    $defaultRequest=[ordered]@{InstallDir='';InstallScope='User'}
    & $module {param($r)Set-WtgRemoteRequestDirectory $r ([pscustomobject]@{LocalAppData='C:\Users\Operator\AppData\Local';ProgramFiles='C:\Program Files'})} $defaultRequest
    Assert ($defaultRequest.InstallDir -eq 'C:\Users\Operator\AppData\Local\Programs\Cilex Watchtower') 'request pins the target profile default before installation'
    $untrusted=Join-Path $fixture 'untrusted-result.json';[IO.File]::WriteAllText($untrusted,'this is not JSON')
    Reject {& $module {param($p)
        function Get-WtgStageAcl {param($Path,[switch]$File)return [pscustomobject]@{OwnerSid='S-1-5-21-1-2-3-1001';Reparse=$false;Rules=@()}}
        Read-WtgProtectedRemoteRecord $p
    } $untrusted} 'REMOTE_STAGE_UNTRUSTED_OWNER'
    Assert $true 'an untrusted retained file is rejected before its contents are parsed'
    & $module {param($s,$d)Copy-WtgRemoteFiles $s $d -PackageOnly} $source $destination
    Assert (Test-Path -LiteralPath (Join-Path $destination 'manifest.json')) 'declared package metadata copied'
    Assert (Test-Path -LiteralPath (Join-Path $destination 'payload\fixture.dll')) 'package payload copied'
    Assert (-not(Test-Path -LiteralPath (Join-Path $destination 'unexpected-private-data.txt'))) 'unrelated source files are never sent to the remote computer'
    $run=Join-Path $fixture 'проверка запуска';[IO.Directory]::CreateDirectory((Join-Path $run 'helpers'))|Out-Null
    $fake='param([string]$RequestPath,[string]$ResultPath,[string]$RunId); [IO.File]::WriteAllText($ResultPath,$RunId)'
    [IO.File]::WriteAllText((Join-Path $run 'helpers\install-target.ps1'),$fake,(New-Object Text.UTF8Encoding $true))
    $stage=[pscustomobject]@{Local=$run;UNC=$run}
    $launch=& $module {param($s,$w)New-WtgSmbLaunch $s 'inspect' 'fixture-launch' $w} $stage $env:SystemRoot
    & $module {param($l)Write-WtgSmbLaunch $l} $launch
    Assert ($launch.Command.StartsWith('"'+$env:SystemRoot+'\System32\cmd.exe"')) 'SCM command resolves the real Windows directory'
    Assert ($launch.Body -notmatch 'ExecutionPolicy|Bypass') 'launcher never weakens script policy'
    $inline=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($launch.EncodedCommand))
    Assert ($inline -notmatch 'ExecutionPolicy|Bypass|Invoke-Expression') 'outer error reporter leaves normal script policy enforcement intact'
    $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/d','/c',('"'+$launch.LauncherUNC+'"')) -WindowStyle Hidden -PassThru
    try{$null=$process.WaitForExit(10000)}finally{$process.Dispose()}
    $clock=[Diagnostics.Stopwatch]::StartNew();$resultPath=Join-Path $run 'inspect-result.json'
    while(-not(Test-Path -LiteralPath $resultPath) -and $clock.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 200}
    Assert (Test-Path -LiteralPath $resultPath) 'actual harmless helper launches from a Cyrillic path'
    Assert ((Get-Content -LiteralPath $resultPath -Raw) -eq 'fixture-launch') 'detached helper receives exact run binding'
    [IO.File]::WriteAllText((Join-Path $run 'helpers\install-target.ps1'),"throw [Management.Automation.PSSecurityException]::new('fixture policy refusal')",(New-Object Text.UTF8Encoding $true))
    Remove-Item -LiteralPath $resultPath -Force
    $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/d','/c',('"'+$launch.LauncherUNC+'"')) -WindowStyle Hidden -PassThru
    try{$null=$process.WaitForExit(10000)}finally{$process.Dispose()}
    $clock.Restart();while(-not(Test-Path -LiteralPath $resultPath) -and $clock.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 200}
    $blocked=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($blocked.ErrorCode -eq 'REMOTE_SCRIPT_POLICY_BLOCKED' -and $blocked.Status -eq 'Failed') 'policy refusal gets a prompt structured result without changing policy'
    Reject {Assert-WtgRemoteResult $blocked 'fixture-launch' $env:COMPUTERNAME} 'REMOTE_SCRIPT_POLICY_BLOCKED'
    $acl=[pscustomobject]@{OwnerSid='S-1-5-18';Reparse=$false;Rules=@([pscustomobject]@{Sid='S-1-5-32-545';Rights=0x6L;InheritOnly=$false;Type='Allow'})}
    & $module {param($a)Assert-WtgStageAcl $a $false} $acl
    Assert $true 'create-only parent rights cannot replace the protected owned child'
    Reject {& $module {param($a)Assert-WtgStageAcl $a $true} $acl} 'REMOTE_STAGE_WRITABLE_BY_OTHER_USERS'
    $acl.Rules[0].Rights=0x40L
    Reject {& $module {param($a)Assert-WtgStageAcl $a $false} $acl} 'REMOTE_STAGE_WRITABLE_BY_OTHER_USERS'
    foreach($unsafeRights in @(0x100L,0x10L,0x40000000L)){
        $acl.Rules[0].Rights=$unsafeRights
        Reject {& $module {param($a)Assert-WtgStageAcl $a $false} $acl} 'REMOTE_STAGE_WRITABLE_BY_OTHER_USERS'
    }
    $acl.Rules=@();$acl.Reparse=$true
    Reject {& $module {param($a)Assert-WtgStageAcl $a $false} $acl} 'REMOTE_STAGE_REPARSE_FORBIDDEN'
    $acl.Reparse=$false;$acl.OwnerSid='S-1-5-21-1-2-3-1001'
    Reject {& $module {param($a)Assert-WtgStageAcl $a $false} $acl} 'REMOTE_STAGE_UNTRUSTED_OWNER'
    & $module {Assert-WtgStageMapping '\\NEW-PC\ordinary\stage\run00001' 'D:\share\stage\run00001' 'D:\share'}
    Assert $true 'custom share mapping uses actual share metadata'
    Reject {& $module {Assert-WtgStageMapping '\\NEW-PC\ordinary\stage\run00001' 'C:\other\stage\run00001' 'D:\share'}} 'REMOTE_STAGE_LOCAL_MAPPING_MISMATCH'
    & $module {Initialize-WtgRemoteNative}
    Assert ([bool]('WtgRemote.Native' -as [type]).GetMethod('CreatePrivateDirectory')) 'native secure directory creation compiles without invoking services'
    & $module {Assert-WtgServiceCleanup $true 0 'cilex-deploy-fixture-install' 'fixture-run' '\\TEST\C$\run\install-result.json'}
    Assert $true 'confirmed helper cleanup permits completion'
    $cleanupFailure=$null
    try{& $module {Assert-WtgServiceCleanup $false 5 'cilex-deploy-fixture-install' 'fixture-run' '\\TEST\C$\run\install-result.json'}}catch{$cleanupFailure=$_.Exception}
    Assert ($cleanupFailure -and $cleanupFailure.Message -eq 'REMOTE_SERVICE_CLEANUP_UNCONFIRMED') 'unconfirmed helper cleanup cannot report clean completion'
    Assert ($cleanupFailure.Data['ServiceName'] -eq 'cilex-deploy-fixture-install' -and $cleanupFailure.Data['RunId'] -eq 'fixture-run') 'cleanup failure identifies the exact retained helper and run'
    Assert ($cleanupFailure.Data['ResultPath'] -eq '\\TEST\C$\run\install-result.json' -and $cleanupFailure.Data['NativeError'] -eq 5) 'cleanup failure retains the installation result location and Windows error'
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('cilex-remote-tests-')){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
Write-Host ("Remote fixture tests: {0} passed." -f $script:passed)
