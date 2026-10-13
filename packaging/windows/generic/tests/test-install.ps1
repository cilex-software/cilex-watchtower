#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$module=Import-Module (Join-Path $PSScriptRoot '..\Install.psm1') -Force -PassThru
$script:passed=0
function Assert($Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:passed++}
function Reject([scriptblock]$Action,[string]$Code){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true;if($_.Exception.Message -notlike "*$Code*"){throw}};Assert $failed $Code}
$root=Join-Path ([IO.Path]::GetTempPath()) ('cilex-install-tests-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
    foreach($bad in @('..\outside','dir\..\outside','C:\outside','\\host\share\file','abc:stream','CON.txt','sub\LPT1','path.\file','a\\b')){
        Reject {& $module {param($r,$p)Resolve-WtgPayloadPath $r $p} $root $bad} 'PACKAGE_'
    }
    Assert ((& $module {param($r)Resolve-WtgPayloadPath $r 'warden/warden.exe'} $root) -eq (Join-Path $root 'warden\warden.exe')) 'normal payload path'
    Reject {& $module {Assert-WtgLocalPath 'C:\'}} 'INSTALL_ROOT_FORBIDDEN'
    $pkg=Join-Path $root 'package';[IO.Directory]::CreateDirectory((Join-Path $pkg 'payload\warden'))|Out-Null
    $files=@()
    foreach($name in @('watchtower.exe','warden/warden.exe','warden/warden-launcher.exe')){
        $p=Join-Path (Join-Path $pkg 'payload') $name;[IO.File]::WriteAllText($p,'fixture - never executable')
        $files += [pscustomobject]@{path=$name;sha256=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash;size=(Get-Item -LiteralPath $p).Length}
    }
    $manifest=[ordered]@{schemaVersion=1;product='CilexWatchtower';version='1.2.3';wardenVersion='1.4.10';sourceCommit=('a'*40);architecture='x64';files=$files}
    $mf=Join-Path $pkg 'manifest.json';[IO.File]::WriteAllText($mf,($manifest|ConvertTo-Json -Depth 8))
    $package=Test-WtgPackage $pkg
    Assert ($package.Bytes -eq 78) 'payload sizes accumulated'
    Reject {Test-WtgPackage $pkg ('0'*64)} 'PACKAGE_MANIFEST_HASH_MISMATCH'
    [IO.File]::WriteAllText((Join-Path $pkg 'payload\extra.dll'),'unexpected')
    Reject {Test-WtgPackage $pkg} 'PACKAGE_UNDECLARED_FILE'
    Remove-Item -LiteralPath (Join-Path $pkg 'payload\extra.dll')
    [IO.File]::AppendAllText((Join-Path $pkg 'payload\watchtower.exe'),'tampered')
    Reject {Test-WtgPackage $pkg} 'PACKAGE_FILE_HASH_MISMATCH'
    [IO.File]::WriteAllText((Join-Path $pkg 'payload\watchtower.exe'),'fixture - never executable')
    $manifest.files=@($files)+$files[0];[IO.File]::WriteAllText($mf,($manifest|ConvertTo-Json -Depth 8))
    Reject {Test-WtgPackage $pkg} 'PACKAGE_FILE_ENTRY_INVALID'
    $manifest.files=$files;[IO.File]::WriteAllText($mf,($manifest|ConvertTo-Json -Depth 8));$package=Test-WtgPackage $pkg
    $identity=[pscustomobject]@{Sid='S-1-5-21-1-2-3-1001';Name='TEST\Operator';Profile=(Join-Path $root 'user');LocalAppData=(Join-Path $root 'user\AppData\Local');AppData=(Join-Path $root 'user\AppData\Roaming')}
    $context=[pscustomobject]@{InstallDir=(Join-Path $root 'installed');InstallScope='User'}
    $plan=Get-WtgInstallPlan $context $identity
    Assert ($plan.Identity.Sid -eq $identity.Sid) 'target SID retained'
    $default=Get-WtgInstallPlan ([pscustomobject]@{}) $identity
    Assert ($default.Directory -eq (Join-Path $identity.LocalAppData 'Programs\Cilex Watchtower')) 'user destination resolved from intended profile'
    Reject {Get-WtgInstallPlan ([pscustomobject]@{InstallDir=$identity.Profile}) $identity} 'INSTALL_PROTECTED_DIRECTORY'
    [IO.Directory]::CreateDirectory($plan.Directory)|Out-Null;[IO.File]::WriteAllText((Join-Path $plan.Directory 'old.dll'),'old')
    Reject {& $module {param($p)Assert-WtgOwnedInstallation $p} $plan} 'INSTALL_DIRECTORY_UNMANAGED'
    # Override only ACL application in this module instance. All paths below are disposable fixtures.
    & $module {function script:Set-WtgPrivateAcl {param($Path,$Sid,[switch]$Machine)}}
    $configPlan=$plan.PSObject.Copy();$configPlan.Identity=$identity.PSObject.Copy();$configPlan.Identity.Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $configPlan.ConfigPath=Join-Path $root 'config-fixture\warden.conf';[IO.Directory]::CreateDirectory((Split-Path -Parent $configPlan.ConfigPath))|Out-Null
    [IO.File]::WriteAllText($configPlan.ConfigPath,('APP_CMD='+$plan.Directory+'\watchtower.exe'+"`r`n"+'APP_ENV=FIRST=value,VALUE_WITH_EQUALS=one=two,UNICODE_PATH=C:\Папка пользователя\Видео,EMPTY='+"`r`n"+'BACKEND_TOKEN=fixture-only'))
    $null=& $module {param($p)Set-WtgWardenConfiguration ([pscustomobject]@{BackendUrl=''}) $p} $configPlan
    $configFixture=[IO.File]::ReadAllText($configPlan.ConfigPath)
    Assert ($configFixture -match 'VALUE_WITH_EQUALS=one=two') 'native PS5 configuration parser preserves equals inside values'
    Assert ($configFixture -match 'EMPTY=(?:,|\r?\n|$)' -and $configFixture -match 'FIRST=value') 'native PS5 configuration parser supports empty and multiple values'
    Assert ($configFixture.Contains('UNICODE_PATH=C:\Папка пользователя\Видео')) 'native PS5 configuration parser preserves Cyrillic and spaces'
    Assert ($configFixture -match 'BACKEND_TOKEN=fixture-only' -and $configFixture -match 'GST_PLUGIN_SCANNER_1_0=') 'configuration retains existing enrollment while pinning packaged runtime paths'
    $script:configured=$false;$script:beforeSawStaged=$false
    $configure={$script:configured=$true}
    $verify={[pscustomobject]@{Passed=$true}}
    $restore={param($Phase)}
    $before={ $script:beforeSawStaged=(Test-Path -LiteralPath (Join-Path $root '.cilex-stage-transaction01\watchtower.exe')) }
    $tx=& $module {param($p,$plan,$c,$v,$r,$b)Invoke-WtgDirectoryTransaction $p $plan 'transaction01' $c $v $r $b} $package $plan $configure $verify $restore $before
    Assert $script:configured 'configuration called after replacement'
    Assert $script:beforeSawStaged 'all payload staged before process-stop callback'
    Assert (Test-Path -LiteralPath (Join-Path $tx.Backup 'old.dll')) 'unknown previous file preserved in full backup'
    Assert ((Get-FileHash -LiteralPath (Join-Path $plan.Directory 'watchtower.exe') -Algorithm SHA256).Hash -eq $files[0].sha256) 'installed payload verified'
    $marked=& $module {param($p)Assert-WtgOwnedInstallation $p} $plan
    Assert ($marked.installId -eq $plan.Id) 'owned marker matches exact installation'
    $beforeHash=(Get-FileHash -LiteralPath (Join-Path $plan.Directory '.cilex-install.json') -Algorithm SHA256).Hash
    $script:restoreCalls=@()
    $failVerify={throw 'FIXTURE_VERIFICATION_FAILED'}
    $restore={param($Phase)$script:restoreCalls += $Phase}
    Reject {& $module {param($p,$plan,$c,$v,$r)Invoke-WtgDirectoryTransaction $p $plan 'transaction02' $c $v $r} $package $plan {} $failVerify $restore} 'FIXTURE_VERIFICATION_FAILED'
    Assert ((Get-FileHash -LiteralPath (Join-Path $plan.Directory '.cilex-install.json') -Algorithm SHA256).Hash -eq $beforeHash) 'failed verification restores previous complete installation'
    Assert (($script:restoreCalls -join ',') -eq 'BeforeFiles,AfterFiles') 'rollback callbacks ordered around restored files'
    Assert (Test-Path -LiteralPath (Join-Path $root '.cilex-failed-transaction02\watchtower.exe')) 'failed payload retained for diagnosis'
    $brokenRestore={param($Phase)throw 'FIXTURE_RESTORE_FAILURE'}
    $rollbackFailure=$null;try{& $module {param($p,$plan,$v,$r)Invoke-WtgDirectoryTransaction $p $plan 'transaction03' {} $v $r} $package $plan $failVerify $brokenRestore|Out-Null}catch{$rollbackFailure=$_.Exception}
    Assert ($rollbackFailure.Message -eq 'INSTALL_FAILED_ROLLBACK_UNVERIFIED') 'rollback failure remains a failed deployment'
    Assert ($rollbackFailure.Data['InstallFailure'].ErrorCode -eq 'FIXTURE_VERIFICATION_FAILED' -and $rollbackFailure.Data['RollbackFailure'].ErrorCode -eq 'FIXTURE_RESTORE_FAILURE') 'original and recovery errors are both retained'
    Assert ($rollbackFailure.Data['RollbackFailure'].Line -gt 0 -and -not $rollbackFailure.Data['RollbackVerified']) 'recovery error has a useful location and an unverified state'
    $safeDiagnostic=try{throw 'example-secret-value must never be reported'}catch{& $module {param($e)Get-WtgFailureDiagnostic $e} $_}
    Assert (($safeDiagnostic|ConvertTo-Json) -notmatch 'example-secret-value' -and $safeDiagnostic.ErrorCode -eq 'INSTALL_OPERATION_FAILED') 'diagnostics exclude arbitrary exception messages and source text'
    # Hostile ZIP traversal fails before the destination is created.
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
    $zip=Join-Path $root 'hostile.zip';$archive=[IO.Compression.ZipFile]::Open($zip,[IO.Compression.ZipArchiveMode]::Create)
    try{$entry=$archive.CreateEntry('../outside');$writer=New-Object IO.StreamWriter($entry.Open());$writer.Write('bad');$writer.Dispose()}finally{$archive.Dispose()}
    $dest=Join-Path $root 'hostile-extracted';$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    Reject {Expand-WtgPackage $zip $dest $hash} 'PACKAGE_UNSAFE_PATH'
    Assert (-not(Test-Path -LiteralPath $dest)) 'malicious ZIP rejected without writing extraction directory'
    Reject {Expand-WtgPackage $zip $dest ('0'*64)} 'PACKAGE_TRUSTED_SHA256_REQUIRED'
    $goodZip=Join-Path $root 'valid.zip';[IO.Compression.ZipFile]::CreateFromDirectory($pkg,$goodZip)
    $inputContext=[pscustomobject]@{RunDir=$root;PackageSha256=(Get-FileHash -LiteralPath $goodZip -Algorithm SHA256).Hash}
    $unpacked=Expand-WtgInstallInput $inputContext $goodZip 'valid-extracted'
    Assert ((Test-WtgPackage $unpacked).Manifest.version -eq '1.2.3') 'trusted valid ZIP extracts into verified package'
    Reject {Expand-WtgInstallInput $inputContext $goodZip 'valid-extracted'} 'PACKAGE_EXTRACTION_DESTINATION_EXISTS'
    $fakeExe=Join-Path $root 'fixture.exe';[IO.File]::WriteAllText($fakeExe,'never execute')
    Reject {Expand-WtgInstallInput $inputContext $fakeExe 'bad-exe'} 'PACKAGE_TRUSTED_SHA256_REQUIRED'
    Assert ((Get-WtgInstallFailureText 'INSTALL_INSUFFICIENT_DISK' 'en') -match 'disk') 'failure is understandable in English'
    Assert ((Get-WtgInstallFailureText 'INSTALL_INSUFFICIENT_DISK' 'ru') -match 'диске') 'failure is understandable in Russian'
    $comTask=[pscustomobject]@{TaskName='WindowsComTask';Actions=@([pscustomobject]@{ClassId='{00000000-0000-0000-0000-000000000000}';Data=''})}
    & $module {param($t,$d)Assert-WtgNoOtherStartupAction @($t) 'legacy-task' $d} $comTask $plan.Directory
    Assert $true 'Windows COM-handler tasks do not break adoption inspection'
    $otherTask=[pscustomobject]@{TaskName='other-launcher';Actions=@([pscustomobject]@{Execute=(Join-Path $plan.Directory 'warden\warden.exe');Arguments='run'})}
    Reject {& $module {param($t,$d)Assert-WtgNoOtherStartupAction @($t) 'legacy-task' $d} $otherTask $plan.Directory} 'ADOPT_OTHER_STARTUP_ACTION_PRESENT'
    $otherTask.Actions[0].Execute='powershell.exe';$otherTask.Actions[0].Arguments='-File "'+$plan.Directory+'\start.ps1"'
    Reject {& $module {param($t,$d)Assert-WtgNoOtherStartupAction @($t) 'legacy-task' $d} $otherTask $plan.Directory} 'ADOPT_OTHER_STARTUP_ACTION_PRESENT'
    # Exercise the actual task identity/action validator using in-memory task records.
    # No scheduled task is queried, created or changed by these fixtures.
    $taskXml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal><UserId>'+ $plan.Identity.Sid +'</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals><Settings><Enabled>true</Enabled></Settings><Actions><Exec><Command>'+ (Join-Path $plan.Directory 'warden\warden-launcher.exe') +'</Command><Arguments>run</Arguments></Exec></Actions></Task>'
    & $module {param($plan,$xml)
        $script:FixtureStartupTask=$null;$script:FixtureStartupXml=$xml
        function script:Get-ScheduledTask {param($TaskName,$ErrorAction) if($script:FixtureStartupTask){return $script:FixtureStartupTask}}
        function script:Export-ScheduledTask {param($TaskName,$ErrorAction) return $script:FixtureStartupXml}
    } $plan $taskXml
    Reject {& $module {param($p)Assert-WtgStartupTask $p} $plan} 'VERIFY_STARTUP_TASK_MISSING'
    & $module {param($p)$script:FixtureStartupTask=[pscustomobject]@{TaskName=$p.TaskName;TaskPath='\'}} $plan
    Assert (& $module {param($p)Assert-WtgStartupTask $p} $plan) 'enabled task with exact account and action permits verification'
    & $module {param($x)$script:FixtureStartupXml=$x.Replace('<Enabled>true</Enabled>','<Enabled>false</Enabled>')} $taskXml
    Reject {& $module {param($p)Assert-WtgStartupTask $p} $plan} 'VERIFY_STARTUP_TASK_DISABLED'
    & $module {param($x)$script:FixtureStartupXml=$x.Replace('<Enabled>true</Enabled>','')} $taskXml
    Reject {& $module {param($p)Assert-WtgStartupTask $p} $plan} 'VERIFY_STARTUP_TASK_ENABLED_STATE_UNKNOWN'
    & $module {$script:FixtureStartupTask|Add-Member -NotePropertyName Settings -NotePropertyValue ([pscustomobject]@{Enabled=$true})}
    Assert (& $module {param($p)Assert-WtgStartupTask $p} $plan) 'omitted default Enabled is accepted only when the live task API confirms it'
    & $module {$script:FixtureStartupTask.Settings.Enabled=$false}
    Reject {& $module {param($p)Assert-WtgStartupTask $p} $plan} 'VERIFY_STARTUP_TASK_DISABLED'
    & $module {param($x)$script:FixtureStartupTask.Settings.Enabled=$true;$script:FixtureStartupXml=$x.Replace('<RunLevel>LeastPrivilege</RunLevel>','')} $taskXml
    Reject {& $module {param($p)Get-WtgTaskXml $p} $plan} 'INSTALL_TASK_OWNERSHIP_MISMATCH'
    & $module {$script:FixtureStartupTask|Add-Member -NotePropertyName Principal -NotePropertyValue ([pscustomobject]@{RunLevel='Limited'})}
    Assert ([bool](& $module {param($p)Get-WtgTaskXml $p} $plan)) 'omitted default RunLevel is accepted only when the live task API confirms Limited'
    & $module {$script:FixtureStartupTask.Principal.RunLevel='Highest'}
    Reject {& $module {param($p)Get-WtgTaskXml $p} $plan} 'INSTALL_TASK_OWNERSHIP_MISMATCH'
    & $module {param($x)$script:FixtureStartupTask.Principal.RunLevel='Limited';$script:FixtureStartupXml=$x.Replace('<LogonType>InteractiveToken</LogonType>','')} $taskXml
    Reject {& $module {param($p)Get-WtgTaskXml $p} $plan} 'INSTALL_TASK_OWNERSHIP_MISMATCH'
    & $module {param($x,$s)$script:FixtureStartupXml=$x.Replace($s,'S-1-5-21-9-8-7-1002')} $taskXml $plan.Identity.Sid
    Reject {& $module {param($p)Assert-WtgStartupTask $p} $plan} 'INSTALL_TASK_OWNERSHIP_MISMATCH'
    & $module {param($x)$script:FixtureStartupXml=$x.Replace('<Arguments>run</Arguments>','<Arguments>status</Arguments>')} $taskXml
    Reject {& $module {param($p)Assert-WtgStartupTask $p} $plan} 'INSTALL_TASK_OWNERSHIP_MISMATCH'
    & $module {param($x)$script:FixtureStartupXml=$x.Replace('warden-launcher.exe','warden.exe')} $taskXml
    Reject {& $module {param($p)Get-WtgTaskXml $p} $plan} 'INSTALL_TASK_OWNERSHIP_MISMATCH'
    $legacyPlan=$plan.PSObject.Copy();$legacyPlan|Add-Member -NotePropertyName AllowLegacyWarden -NotePropertyValue $true
    Assert ([bool](& $module {param($p)Get-WtgTaskXml $p} $legacyPlan)) 'native Warden task remains accepted only for explicit legacy adoption or recovery'
    & $module {$script:FixtureStartupTask=$null}
    $created=[DateTime]::UtcNow.AddMinutes(-5)
    $runtimeRows=@(
        [pscustomobject]@{Path=(Join-Path $plan.Directory 'warden\warden-launcher.exe');ProcessId=10;ParentId=1;Session=1;CreatedUTC=$created},
        [pscustomobject]@{Path=(Join-Path $plan.Directory 'warden\warden.exe');ProcessId=11;ParentId=10;Session=1;CreatedUTC=$created.AddSeconds(1)},
        [pscustomobject]@{Path=(Join-Path $plan.Directory 'warden\warden.exe');ProcessId=12;ParentId=11;Session=1;CreatedUTC=$created.AddSeconds(2)},
        [pscustomobject]@{Path=(Join-Path $plan.Directory 'watchtower.exe');ProcessId=13;ParentId=12;Session=1;CreatedUTC=$created.AddSeconds(3)}
    )
    Assert (& $module {param($p,$r)Test-WtgProcessParentage $p $r 1} $plan $runtimeRows) 'launcher owns both native Warden processes while Warden remains the app parent'
    Assert (-not(& $module {param($p,$r)Test-WtgProcessParentage $p $r 1} $plan @($runtimeRows|Select-Object -Skip 1))) 'new installation refuses a missing launcher'
    Assert (& $module {param($p,$r)Test-WtgProcessParentage $p $r 1} $legacyPlan @($runtimeRows|Select-Object -Skip 1)) 'legacy rollback can verify the original native hierarchy'
    $runtimeRows[1].ParentId=999
    Assert (-not(& $module {param($p,$r)Test-WtgProcessParentage $p $r 1} $plan $runtimeRows)) 'orphan Warden is not accepted as launcher-managed'
    $runtimeRows[1].ParentId=12
    Assert (-not(& $module {param($p,$r)Test-WtgProcessParentage $p $r 1} $plan $runtimeRows)) 'cyclic or reused process parentage is rejected'
    $runtimeRows[1].ParentId=10;$runtimeRows[2].Session=2
    Assert (-not(& $module {param($p,$r)Test-WtgProcessParentage $p $r 1} $plan $runtimeRows)) 'every supervisor must belong to the intended desktop session'
    $boot=[DateTime]::UtcNow.AddMinutes(-10)
    $last=[pscustomobject]@{InstalledUTC=$boot.AddHours(-1).ToString('o')}
    $runtime=[pscustomobject]@{State='VerifiedCurrentSession';Visibility=[pscustomobject]@{State='Verified'};Processes=@([pscustomobject]@{CreatedUTC=$boot.AddMinutes(1)})}
    $automatic=[pscustomobject]@{Enabled=$true;AccountMatches=$true;BannerPresent=$false}
    $boundMarker=[pscustomobject]@{runId='fixture-run';targetSid=$identity.Sid;installDir=$plan.Directory;installScope='User';version='1.2.3';wardenVersion='1.4.10';sourceCommit=('a'*40);manifestSha256=('b'*64)}
    $boundRecord=$boundMarker.PSObject.Copy()
    Assert ((& $module {param($r,$m)Get-WtgInstallRecordState $r $m} $boundRecord $boundMarker) -eq 'Current') 'matching installation record can supply reboot evidence'
    Assert ((& $module {param($m)Get-WtgInstallRecordState $null $m} $boundMarker) -eq 'Missing') 'missing installation record is explicitly unverified'
    foreach($field in @('runId','targetSid','installDir','installScope','version','wardenVersion','sourceCommit','manifestSha256')){
        $changedRecord=$boundRecord.PSObject.Copy();$changedRecord.$field='different'
        Assert ((& $module {param($r,$m)Get-WtgInstallRecordState $r $m} $changedRecord $boundMarker) -eq 'Mismatched') ('record mismatch defers evidence: '+$field)
    }
    $newerMarker=$boundMarker.PSObject.Copy();$newerMarker.runId='newer-installation'
    Assert ((& $module {param($r,$m)Get-WtgInstallRecordState $r $m} $boundRecord $newerMarker) -eq 'Mismatched') 'newer marker never borrows an older successful installation record'
    Assert (-not(Test-WtgRebootEvidence $last $boot $runtime $automatic $false).RebootVerified) 'running desktop does not prove automatic sign-in'
    Assert (Test-WtgRebootEvidence $last $boot $runtime $automatic $true).RebootVerified 'explicit monitored reboot evidence accepted'
    $runtime.Visibility.State='Deferred'
    Assert (-not(Test-WtgRebootEvidence $last $boot $runtime $automatic $true).RebootVerified) 'reboot verification cannot claim a visible wall without desktop proof'
    $runtime.State='VerifiedProcessesVisibilityDeferred'
    Assert (Test-WtgRebootEvidence $last $boot $runtime $automatic $true).RebootObserved 'read-only cross-session check can record a new boot while keeping visibility unverified'
    $runtime.State='VerifiedCurrentSession'
    $runtime.Visibility.State='Verified'
    $automatic.AccountMatches=$false
    Assert (-not(Test-WtgRebootEvidence $last $boot $runtime $automatic $true).RebootVerified) 'different autologon account is not accepted'
    $automatic.AccountMatches=$true;$automatic.BannerPresent=$true
    Assert (-not(Test-WtgRebootEvidence $last $boot $runtime $automatic $true).RebootVerified) 'logon notice prevents automatic sign-in claim'
    $automatic.BannerPresent=$false;$last.InstalledUTC=$boot.AddMinutes(1).ToString('o')
    Assert (-not(Test-WtgRebootEvidence $last $boot $runtime $automatic $true).RebootObserved) 'same pre-install boot cannot prove reboot startup'
    $expectedWindow=[pscustomobject]@{Nonce='fixture-nonce';RunId='fixture-window';OwnerSid=$identity.Sid;ProcessId=777;Session=1;Path=(Join-Path $plan.Directory 'watchtower.exe');CreatedUTC=[DateTime]::UtcNow.ToString('o');ResultPath=(Join-Path $root 'window-proof.json')}
    $window=[pscustomobject]@{Nonce=$expectedWindow.Nonce;RunId=$expectedWindow.RunId;OwnerSid=$identity.Sid;Status='Observed';ProcessId=777;Session=1;Path=$expectedWindow.Path;CreatedUTC=$expectedWindow.CreatedUTC;Visible=$true}
    Assert ((& $module {param($p,$e)ConvertFrom-WtgWindowProof $p $e} $window $expectedWindow).State -eq 'Verified') 'matching user-desktop window proof is accepted'
    foreach($name in @('OwnerSid','Session','Path','ProcessId')){
        $copy=$window|ConvertTo-Json|ConvertFrom-Json
        switch($name){'OwnerSid'{$copy.OwnerSid='S-1-5-18'};'Session'{$copy.Session=0};'Path'{$copy.Path='C:\other.exe'};'ProcessId'{$copy.ProcessId=888}}
        Reject {& $module {param($p,$e)ConvertFrom-WtgWindowProof $p $e} $copy $expectedWindow} 'INSTALL_WINDOW_PROBE_IDENTITY_MISMATCH'
    }
    $copy=$window|ConvertTo-Json|ConvertFrom-Json;$copy.CreatedUTC=[DateTime]::Parse($window.CreatedUTC).AddSeconds(2).ToString('o')
    Reject {& $module {param($p,$e)ConvertFrom-WtgWindowProof $p $e} $copy $expectedWindow} 'INSTALL_WINDOW_PROBE_PROCESS_CHANGED'
    $copy=$window|ConvertTo-Json|ConvertFrom-Json;$copy.Nonce='other-run'
    Reject {& $module {param($p,$e)ConvertFrom-WtgWindowProof $p $e} $copy $expectedWindow} 'INSTALL_WINDOW_PROBE_INVALID'
    Reject {& $module {param($e)ConvertFrom-WtgWindowProof ([pscustomobject]@{Status='Observed'}) $e} $expectedWindow} 'INSTALL_WINDOW_PROBE_INVALID'
    $copy=$window|ConvertTo-Json|ConvertFrom-Json;$copy.Status='Unavailable';$copy.Visible=$false
    Assert ((& $module {param($p,$e)ConvertFrom-WtgWindowProof $p $e} $copy $expectedWindow).State -eq 'Deferred') 'blocked desktop observation is deferred rather than failing healthy startup'
    Assert ((& $module {param($e)Get-WtgProbeWaitOutcome $null $e $true} $expectedWindow).Reason -eq 'ProbeTimedOut') 'missing desktop result has an explicit bounded-timeout outcome'
    $encoded=& $module {param($e)New-WtgWindowProbeCommand $e} $expectedWindow
    $inline=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
    Assert ($inline -notmatch 'ExecutionPolicy|Bypass|Invoke-Expression|Start-Process|Stop-Process') 'window observer contains only a query and result write'
    $taskSpec=[pscustomobject]@{Name='fixture-visibility';Sid=$identity.Sid;Executable='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';Arguments=('-NoProfile -NonInteractive -EncodedCommand '+$encoded)}
    $probeTask=[pscustomobject]@{TaskName=$taskSpec.Name;TaskPath='\';Principal=[pscustomobject]@{UserId=$identity.Sid;LogonType='Interactive';RunLevel='Limited'};Actions=@([pscustomobject]@{Execute=$taskSpec.Executable;Arguments=$taskSpec.Arguments})}
    & $module {param($t,$s)Assert-WtgWindowProbeTask $t $s} $probeTask $taskSpec
    Assert $true 'only the exact bound observer task qualifies for cleanup'
    $probeTask.Actions[0].Arguments+=' changed'
    Reject {& $module {param($t,$s)Assert-WtgWindowProbeTask $t $s} $probeTask $taskSpec} 'INSTALL_WINDOW_PROBE_TASK_CHANGED'
    $crossProcess=[pscustomobject]@{Session=9876}
    Assert ((& $module {param($p,$a)Get-WtgWindowVisibility ([pscustomobject]@{}) $p $a -ReadOnly} $plan $crossProcess).Reason -eq 'DifferentDesktopReadOnly') 'cross-session VerifyOnly does not create any task or trust SYSTEM window visibility'
    & $module {
        $script:FixtureProbeTask=$null;$script:FixtureProbeCleanupFailure=$false;$script:FixtureProbeRegistrationFailure=$false;$script:FixtureProbePartialRegistration=$false;$script:FixtureProbeBadProof=$false;$script:FixtureProbeStops=0
        function script:New-WtgWindowProbeCommand {param($Expected)$script:FixtureWindowExpected=$Expected;return 'fixture-command'}
        function script:Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)if($script:FixtureProbeTask -and (-not $TaskName -or $script:FixtureProbeTask.TaskName -eq $TaskName)){return $script:FixtureProbeTask}}
        function script:New-ScheduledTaskAction {param($Execute,$Argument,$WorkingDirectory)return [pscustomobject]@{Execute=$Execute;Arguments=$Argument}}
        function script:New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel)return [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel}}
        function script:New-ScheduledTaskSettingsSet {return [pscustomobject]@{}}
        function script:Register-ScheduledTask {param($TaskName,$Action,$Principal,$Settings,$ErrorAction)if($script:FixtureProbeRegistrationFailure){throw 'FIXTURE_PROBE_BLOCKED'};$script:FixtureProbeTask=[pscustomobject]@{TaskName=$TaskName;TaskPath='\';Actions=@($Action);Principal=$Principal;State='Running'};if($script:FixtureProbePartialRegistration){throw 'FIXTURE_PARTIAL_REGISTRATION'};return $script:FixtureProbeTask}
        function script:Start-ScheduledTask {param($TaskName,$ErrorAction)
            $e=$script:FixtureWindowExpected
            $proof=[ordered]@{Nonce=$e.Nonce;RunId=$e.RunId;OwnerSid=$e.OwnerSid;Status='Observed';ProcessId=$e.ProcessId;Session=$e.Session;Path=$e.Path;CreatedUTC=$e.CreatedUTC;Visible=$true}
            if($script:FixtureProbeBadProof){$proof.OwnerSid='S-1-5-18'}
            [IO.File]::WriteAllText($e.ResultPath,($proof|ConvertTo-Json))
        }
        function script:Unregister-ScheduledTask {param($TaskName,$Confirm,$ErrorAction)if($script:FixtureProbeCleanupFailure){throw 'FIXTURE_CLEANUP_BLOCKED'};$script:FixtureProbeTask=$null}
        function script:Stop-ScheduledTask {param($TaskName,$ErrorAction)$script:FixtureProbeTask.State='Ready';$script:FixtureProbeStops++}
    }
    $probeProcess=[pscustomobject]@{ProcessId=777;Session=1;Path=$expectedWindow.Path;CreatedUTC=[DateTime]::Parse($expectedWindow.CreatedUTC)}
    $probeContext=[pscustomobject]@{RunId='fixture-window-orchestration'}
    $probeResult=& $module {param($c,$p,$a)Invoke-WtgUserWindowProbe $c $p $a} $probeContext $plan $probeProcess
    Assert ($probeResult.State -eq 'Verified' -and $probeResult.CleanupVerified) 'actual observer orchestration validates result and confirms owned task removal'
    Assert ((& $module {$script:FixtureProbeStops}) -eq 1) 'still-running owned observer is stopped before its task is removed'
    & $module {$script:FixtureProbeCleanupFailure=$true}
    $probeResult=& $module {param($c,$p,$a)Invoke-WtgUserWindowProbe $c $p $a} $probeContext $plan $probeProcess
    Assert ($probeResult.State -eq 'Deferred' -and $probeResult.ObservedState -eq 'Verified' -and -not $probeResult.CleanupVerified -and $probeResult.RetainedTask -like '*-visibility-*') 'cleanup failure defers completion while preserving the observation and exact retained task'
    & $module {$script:FixtureProbeTask=$null;$script:FixtureProbeRegistrationFailure=$true}
    $probeResult=& $module {param($c,$p,$a)Invoke-WtgUserWindowProbe $c $p $a} $probeContext $plan $probeProcess
    Assert ($probeResult.State -eq 'Deferred') 'blocked observer task does not roll back an otherwise healthy application'
    & $module {$script:FixtureProbeRegistrationFailure=$false;$script:FixtureProbeCleanupFailure=$false;$script:FixtureProbePartialRegistration=$true}
    $probeResult=& $module {param($c,$p,$a)Invoke-WtgUserWindowProbe $c $p $a} $probeContext $plan $probeProcess
    Assert ($probeResult.State -eq 'Deferred' -and $probeResult.CleanupVerified -and -not(& $module {$script:FixtureProbeTask})) 'registration that creates then throws is reconciled and its exact helper removed'
    & $module {$script:FixtureProbePartialRegistration=$false;$script:FixtureProbeCleanupFailure=$true;$script:FixtureProbeBadProof=$true}
    $badProbe=$null;try{& $module {param($c,$p,$a)Invoke-WtgUserWindowProbe $c $p $a} $probeContext $plan $probeProcess|Out-Null}catch{$badProbe=$_.Exception}
    Assert ($badProbe.Message -eq 'INSTALL_WINDOW_PROBE_IDENTITY_MISMATCH' -and $badProbe.Data['RetainedTask'] -and $badProbe.Data['CleanupVerified'] -eq $false) 'identity failure retains cleanup failure details'
    Assert (Test-Path -LiteralPath $badProbe.Data['ProbeStatusPath']) 'identity and cleanup failure evidence is saved in the private probe folder'
    & $module {
        $script:FixtureRemovalTask=$null;$script:FixtureRemovalCount=0;$script:FixtureRemovalQueryFailure=$false
        function script:Get-ScheduledTask {param($TaskPath,$ErrorAction)if($script:FixtureRemovalQueryFailure){throw 'FIXTURE_TASK_QUERY_FAILED'};if($script:FixtureRemovalTask){return $script:FixtureRemovalTask}}
        function script:Get-WtgTaskXml {return '<fixture-validated-task />'}
        function script:Unregister-ScheduledTask {param($TaskName,$TaskPath,$Confirm,$ErrorAction)if(-not $script:FixtureRemovalTask){throw 'FIXTURE_MISSING_TASK_CIM_ERROR'};$script:FixtureRemovalTask=$null;$script:FixtureRemovalCount++}
    }
    & $module {param($p)Remove-WtgTaskIfPresent $p} $plan
    Assert ((& $module {$script:FixtureRemovalCount}) -eq 0) 'rollback before task creation does not unregister a missing task'
    & $module {param($p)$script:FixtureRemovalTask=[pscustomobject]@{TaskName=$p.TaskName}} $plan
    & $module {param($p)Remove-WtgTaskIfPresent $p} $plan
    Assert ((& $module {$script:FixtureRemovalCount}) -eq 1) 'created owned task is removed and absence verified'
    & $module {$script:FixtureRemovalQueryFailure=$true}
    Reject {& $module {param($p)Remove-WtgTaskIfPresent $p} $plan} 'FIXTURE_TASK_QUERY_FAILED'
    & $module {
        $script:FixtureRestoredEnabled=$false
        function script:Get-ScheduledTask {param($TaskPath,$ErrorAction)return [pscustomobject]@{TaskName='fixture-restore-enabled';Settings=[pscustomobject]@{Enabled=$script:FixtureRestoredEnabled}}}
        function script:Enable-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)$script:FixtureRestoredEnabled=$true}
        function script:Disable-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)$script:FixtureRestoredEnabled=$false}
    }
    & $module {Set-WtgRestoredTaskEnabled 'fixture-restore-enabled' $true}
    Assert ((& $module {Get-WtgTaskEnabled 'fixture-restore-enabled'}) -eq $true) 'rollback explicitly restores previously enabled task even when XML omitted the default'
    & $module {Set-WtgRestoredTaskEnabled 'fixture-restore-enabled' $false}
    Assert ((& $module {Get-WtgTaskEnabled 'fixture-restore-enabled'}) -eq $false) 'rollback preserves a previously disabled task'
    & $module {
        $script:FixtureStopOrder=New-Object Collections.Generic.List[string];$script:FixtureTaskStillRunning=$false
        function script:Get-WtgTaskXml {$script:FixtureStopOrder.Add('Validate');return '<owned />'}
        function script:Disable-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)$script:FixtureStopOrder.Add('Disable')}
        function script:Stop-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)$script:FixtureStopOrder.Add('Stop')}
        function script:Get-ScheduledTask {param($TaskPath,$ErrorAction)return [pscustomobject]@{TaskName='fixture-restore-enabled';State=$(if($script:FixtureTaskStillRunning){'Running'}else{'Disabled'})}}
    }
    $stopPlan=$plan.PSObject.Copy();$stopPlan.TaskName='fixture-restore-enabled'
    & $module {param($p)Stop-WtgTaskExecution $p} $stopPlan
    Assert ((& $module {$script:FixtureStopOrder -join ','}) -eq 'Validate,Disable,Validate,Stop') 'task instance is validated immediately before stopping and state is checked'
    & $module {$script:FixtureTaskStillRunning=$true}
    Reject {& $module {param($p)Stop-WtgTaskExecution $p 0} $stopPlan} 'INSTALL_TASK_STOP_TIMEOUT'
    & $module {
        function script:New-ScheduledTaskAction {param($Execute,$Argument,$WorkingDirectory)return [pscustomobject]@{Execute=$Execute;Arguments=$Argument}}
        function script:New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel)return [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel}}
        function script:New-ScheduledTaskTrigger {param([switch]$AtLogOn,$User,[switch]$Once,$At,$RepetitionInterval)if($Once){$script:FixtureRecoveryInterval=$RepetitionInterval;$script:FixtureFirstRecovery=$At};return [pscustomobject]@{Once=[bool]$Once}}
        function script:New-ScheduledTaskSettingsSet {param($MultipleInstances,$RestartCount,$RestartInterval,$ExecutionTimeLimit,[switch]$StartWhenAvailable,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries)$script:FixtureInstanceMode=$MultipleInstances;return [pscustomobject]@{}}
        function script:Register-ScheduledTask {param($TaskName,$Action,$Principal,$Trigger,$Settings,[switch]$Force,$ErrorAction)$script:FixtureTaskExecutable=$Action.Execute}
    }
    & $module {param($p)Register-WtgTask $p} $plan
    Assert ((& $module {$script:FixtureRecoveryInterval.TotalMinutes}) -eq 1 -and (& $module {$script:FixtureFirstRecovery}) -le (Get-Date).AddSeconds(61)) 'recovery begins in one minute and repeats every minute'
    Assert ((& $module {$script:FixtureInstanceMode}) -eq 'IgnoreNew' -and (& $module {$script:FixtureTaskExecutable}) -eq (Join-Path $plan.Directory 'warden\warden-launcher.exe')) 'periodic recovery cannot duplicate a running launcher task'
    # Exercise the real orchestration with every OS/process capability replaced INSIDE
    # this private imported module. No real registry/task/process call can be reached.
    & $module {param($identity)
        $script:FixtureIdentity=$identity;$script:FixtureFailConfigure=$false;$script:FixtureConfigured=0
        function script:Resolve-WtgTargetIdentity {return $script:FixtureIdentity}
        function script:Confirm-WtgTargetRequirements {param($Context,$Plan)return @([pscustomobject]@{Id='fixture';State='PASS'})}
        function script:Test-WtgElevation {return $true}
        function script:Install-WtgRuntimePrerequisites {}
        function script:Get-WtgTaskXml {return $null}
        function script:Get-ScheduledTask {param($TaskPath,$TaskName,$ErrorAction)return @()}
        function script:Get-WtgOwnedProcesses {return @()}
        function script:Get-WtgInteractiveSessions {return @()}
        function script:Register-WtgTask {$script:FixtureConfigured++}
        function script:Unregister-ScheduledTask {param($TaskName,$Confirm,$ErrorAction)}
        function script:Set-WtgWardenConfiguration {if($script:FixtureFailConfigure){throw 'FIXTURE_CONFIG_FAIL'}}
        function script:Register-WtgUninstaller {}
        function script:Get-WtgRegistrationSnapshot {return [pscustomobject]@{Present=$false;Values=@()}}
        function script:Restore-WtgRegistration {}
        function script:Test-WtgInstalledStartup {return [pscustomobject]@{State='DeferredUntilSignIn';Video='Deferred';Processes=@()}}
        function script:Set-WtgUnattendedStartup {return 'AfterSignInConfiguredButUnverified'}
        function script:Get-CimInstance {return [pscustomobject]@{LastBootUpTime=[DateTime]::Now.AddHours(-1)}}
    } $identity
    $installContext=[pscustomobject]@{RunId='fixture-full-01';RunDir=$root;InstallDir=(Join-Path $root 'fullinstall');InstallScope='User';TargetUser='TEST\Operator';TargetSid=$identity.Sid;Language='en';OverrideRequirements=@()}
    $identity|Add-Member -NotePropertyName IsCurrent -NotePropertyValue $true
    $result=Install-WtgPackage $installContext $pkg
    Assert ($result.Status -eq 'InstalledWithDeferredChecks') 'complete first-install orchestrator preserves deferred truth'
    Assert ($result.TargetSid -eq $identity.Sid) 'complete installer binds intended account'
    Assert ((& $module {$script:FixtureConfigured}) -eq 1) 'real orchestration invokes module-private task capability'
    Reject {Get-WtgStartupVerification $installContext} 'VERIFY_STARTUP_TASK_MISSING'
    $previous=(Get-FileHash -LiteralPath (Join-Path $installContext.InstallDir 'watchtower.exe') -Algorithm SHA256).Hash
    $installContext.RunId='fixture-full-02'; & $module {$script:FixtureFailConfigure=$true}
    Reject {Install-WtgPackage $installContext $pkg} 'FIXTURE_CONFIG_FAIL'
    Assert ((Get-FileHash -LiteralPath (Join-Path $installContext.InstallDir 'watchtower.exe') -Algorithm SHA256).Hash -eq $previous) 'orchestrated failure restores prior payload'
    $fullPlan=Get-WtgInstallPlan $installContext $identity
    $lock=[IO.File]::Open((Join-Path $fullPlan.StatePath 'install.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$lock.Dispose()
    Assert $true 'installation lock released after failed transaction'
    & $module {$script:FixtureFailConfigure=$false;function script:Set-WtgUnattendedStartup {throw 'AUTOLOGON_PUBLISHER_NOT_VERIFIED'}}
    $installContext.RunId='fixture-full-03';$installContext|Add-Member -NotePropertyName StartupMode -NotePropertyValue 'UnattendedReboot'
    $partial=Install-WtgPackage $installContext $pkg
    Assert ($partial.Status -eq 'InstalledWithDeferredChecks') 'post-install sign-in setup failure retains truthful installed state'
    Assert ($partial.Startup -eq 'UnattendedSetupNotCompleted') 'unattended mode is not silently changed to sign-in mode'
    Assert ($partial.StartupErrorCode -eq 'AUTOLOGON_PUBLISHER_NOT_VERIFIED') 'setup error is preserved without raw exception text'
    Assert (Test-Path -LiteralPath $partial.Backup) 'post-install setup failure retains verified backup location'
    Write-Host ("Install fixture tests: {0} passed." -f $script:passed)
}finally{
    # Resolve and check before recursive deletion; never delete a computed external path.
    $resolved=[IO.Path]::GetFullPath($root)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('cilex-install-tests-')){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
