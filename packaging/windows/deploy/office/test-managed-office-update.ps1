#requires -Version 5.1
# Real wrapper selection and managed installer transactions, using disposable
# files and in-memory Windows capabilities. No real task, process, registry,
# service, prerequisite installer or security setting can be changed.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$script:passed=0
function Assert($Value,[string]$Name){if(-not $Value){throw ('FAIL: '+$Name)};$script:passed++}
function Json($Value){return ConvertTo-Json -InputObject $Value -Depth 20 -Compress}
. (Join-Path $PSScriptRoot '..\..\generic\tests\test-owned-process-drain.ps1') -FixtureDefinitionsOnly

$wrapper=Join-Path $PSScriptRoot 'update-local-package.ps1'
$tokens=$null;$errors=$null
$tree=[Management.Automation.Language.Parser]::ParseFile($wrapper,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Wrapper syntax did not parse.'}
# Extract definitions only. The wrapper entry point (and its OS inspection)
# is never evaluated by this fixture.
foreach($node in $tree.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){
    Invoke-Expression $node.Extent.Text
}
$module=Import-Module (Join-Path $PSScriptRoot '..\..\generic\Install.psm1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('cilex-managed-office-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
    $identity=[pscustomobject]@{Sid='S-1-5-21-1-2-3-1001';Name='FIXTURE\Operator';Profile=(Join-Path $root 'user');LocalAppData=(Join-Path $root 'user\AppData\Local');AppData=(Join-Path $root 'user\AppData\Roaming');IsCurrent=$true}
    $packageRoot=Join-Path $root 'package'
    [IO.Directory]::CreateDirectory((Join-Path $packageRoot 'payload\warden'))|Out-Null
    $files=@()
    foreach($name in @('watchtower.exe','warden/warden.exe','warden/warden-launcher.exe')){
        $file=Join-Path (Join-Path $packageRoot 'payload') $name
        [IO.File]::WriteAllText($file,'new fixture bytes, never executable: '+$name)
        $files+=@{path=$name;size=(Get-Item -LiteralPath $file).Length;sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}
    }
    $manifest=[ordered]@{schemaVersion=1;product='CilexWatchtower';version='1.1.791';wardenVersion='1.5.0';sourceCommit=('b'*40);architecture='x64';files=$files}
    $manifestPath=Join-Path $packageRoot 'manifest.json'
    [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding $false))
    $manifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $videoModule=Join-Path $root 'fixture-video.psm1'
    [IO.File]::WriteAllText($videoModule,@'
function Get-StationVideoSnapshot {param($LogPath,$ProcessId,$CreatedUTC)return [pscustomobject]@{ExpectedVideo=1;FixtureOnly=$true;ProcessId=$ProcessId}}
function Assert-StationVideoBaseline {param($Snapshot)if(-not $Snapshot.FixtureOnly){throw 'FIXTURE_VIDEO_ONLY'};return $true}
Export-ModuleMember -Function Get-StationVideoSnapshot,Assert-StationVideoBaseline
'@)

    # Install every Windows capability override BEFORE any installer entry.
    # The real package, marker, task XML, config and directory-transaction code
    # remain in use. Stubs reject paths/names outside this fixture.
    & $module {param($Root,$Identity,$VideoModule)
        $script:FixtureRoot=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
        $script:FixtureIdentity=$Identity;$script:FixtureVideoModule=$VideoModule
        function script:Assert-FixturePath([string]$Path){if(-not [IO.Path]::GetFullPath($Path).StartsWith($script:FixtureRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_EXTERNAL_PATH_FORBIDDEN'}}
        function script:Assert-FixtureTask([string]$Name){if($Name -cne $script:Fixture.Plan.TaskName){throw 'FIXTURE_LEGACY_OR_FOREIGN_TASK_MUTATION'}}
        function script:Copy-FixtureObject($Value){return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 20)}
        function script:Get-FixtureXml($Task){
            $escape=[Security.SecurityElement]
            return '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal><UserId>'+$escape::Escape([string]$Task.Principal.UserId)+'</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals><Settings><Enabled>'+([string][bool]$Task.Settings.Enabled).ToLowerInvariant()+'</Enabled></Settings><Actions><Exec><Command>'+$escape::Escape([string]$Task.Actions[0].Execute)+'</Command><Arguments>'+$escape::Escape([string]$Task.Actions[0].Arguments)+'</Arguments><WorkingDirectory>'+$escape::Escape([string]$Task.Actions[0].WorkingDirectory)+'</WorkingDirectory></Exec></Actions></Task>'
        }
        function script:Resolve-WtgTargetIdentity {return $script:FixtureIdentity}
        function script:Confirm-WtgTargetRequirements {param($Context,$Plan)
            $script:Fixture.Events.Add('Requirements:fixture-only')
            return @([pscustomobject]@{Id='fixture';State='PASS'})
        }
        function script:Test-WtgElevation {return $true}
        function script:Install-WtgRuntimePrerequisites {$script:Fixture.Events.Add('Prerequisites:fixture-only')}
        function script:Set-WtgPrivateAcl {param($Path,$Sid,[switch]$Machine)Assert-FixturePath $Path}
        function script:Set-WtgPrivateFileAcl {param($Path,$Sid)Assert-FixturePath $Path}
        function script:Get-Acl {param($LiteralPath,$ErrorAction)Assert-FixturePath $LiteralPath;return [pscustomobject]@{FixtureAcl=$LiteralPath}}
        function script:Set-Acl {param($LiteralPath,$AclObject,$ErrorAction)Assert-FixturePath $LiteralPath;$script:Fixture.Events.Add('RestoreAcl:fixture-only')}
        function script:Get-WtgRegistrationSnapshot {param($Plan)return Copy-FixtureObject $script:Fixture.Registration}
        function script:Register-WtgUninstaller {param($Plan,$Package)$script:Fixture.Registration=[pscustomobject]@{Version=$Package.Manifest.version;FixtureOnly=$true};$script:Fixture.Events.Add('Registration:new')}
        function script:Restore-WtgRegistration {param($Plan,$Snapshot)$script:Fixture.Registration=Copy-FixtureObject $Snapshot;$script:Fixture.Events.Add('Registration:restored')}
        function script:Get-WtgHelperPath {param($Name)
            if($Name -cne 'StationVideoHealth.psm1'){throw 'FIXTURE_HELPER_FORBIDDEN'}
            $script:Fixture.Events.Add('VideoBaseline:fixture-only')
            return $script:FixtureVideoModule
        }
        function script:Get-WtgInteractiveSessions {param($Plan)return @(1)}
        function script:Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)
            foreach($task in $script:Fixture.Tasks.Values){if(-not $TaskName -or $task.TaskName -eq $TaskName){$task}}
        }
        function script:Export-ScheduledTask {param($TaskName,$ErrorAction)return $script:Fixture.Xml[$TaskName]}
        function script:Disable-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)
            Assert-FixtureTask $TaskName;$script:Fixture.Events.Add('Disable:'+$TaskName)
            $script:Fixture.Tasks[$TaskName].Settings.Enabled=$false
        }
        function script:Enable-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)
            Assert-FixtureTask $TaskName;$script:Fixture.Events.Add('Enable:'+$TaskName)
            $script:Fixture.Tasks[$TaskName].Settings.Enabled=$true
        }
        function script:Stop-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)
            Assert-FixtureTask $TaskName;$script:Fixture.Events.Add('Stop:'+$TaskName)
            $script:Fixture.Tasks[$TaskName].State='Disabled';$script:Fixture.CallbackCalled=$true
            # The real scheduler can finish its instance before all descendant
            # native generations disappear. Keep the CIM rows and old handles;
            # the actual drain must classify/finish them, not this task double.
            if($script:Fixture.Processes.ContainsKey(100)){$script:Fixture.Processes[100].Exited=$true}
            if($script:Fixture.Processes.ContainsKey(101)){$script:Fixture.Processes[101].Exited=$true}
            if($script:Fixture.Processes.ContainsKey(102)){$script:Fixture.Processes[102].KillRace=$true}
        }
        function script:New-ScheduledTaskAction {param($Execute,$Argument,$WorkingDirectory)return [pscustomobject]@{Execute=$Execute;Arguments=$Argument;WorkingDirectory=$WorkingDirectory}}
        function script:New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel)return [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel}}
        function script:New-ScheduledTaskTrigger {param([switch]$AtLogOn,$User,[switch]$Once,$At,$RepetitionInterval)return [pscustomobject]@{AtLogOn=[bool]$AtLogOn;Once=[bool]$Once}}
        function script:New-ScheduledTaskSettingsSet {param($MultipleInstances,$RestartCount,$RestartInterval,$ExecutionTimeLimit,[switch]$StartWhenAvailable,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries)return [pscustomobject]@{Enabled=$true}}
        function script:Register-ScheduledTask {param($TaskName,$Action,$Principal,$Trigger,$Settings,$Xml,[switch]$Force,$ErrorAction)
            Assert-FixtureTask $TaskName
            if($Xml){
                if($Xml -cne $script:Fixture.InitialManagedXml){throw 'FIXTURE_UNEXPECTED_RESTORED_XML'}
                $script:Fixture.Tasks[$TaskName]=Copy-FixtureObject $script:Fixture.InitialManagedTask
                $script:Fixture.Tasks[$TaskName].State='Ready';$script:Fixture.Xml[$TaskName]=$Xml
                $script:Fixture.Events.Add('RegisterRestored:'+$TaskName)
            }else{
                $task=[pscustomobject]@{TaskName=$TaskName;TaskPath='\';Actions=@($Action);Principal=$Principal;Settings=$Settings;State='Ready';Triggers=@($Trigger)}
                $script:Fixture.Tasks[$TaskName]=$task;$script:Fixture.Xml[$TaskName]=Get-FixtureXml $task
                $script:Fixture.Events.Add('RegisterNew:'+$TaskName)
            }
        }
        function script:Unregister-ScheduledTask {throw 'FIXTURE_UNEXPECTED_TASK_REMOVAL'}
        function script:Start-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)
            Assert-FixtureTask $TaskName;$script:Fixture.Events.Add('Start:'+$TaskName)
            $script:Fixture.Tasks[$TaskName].State='Running'
            $created=[DateTime]::UtcNow.AddMinutes(-1);$dir=$script:Fixture.Plan.Directory
            $rows=@(
                [pscustomobject]@{Path=(Join-Path $dir 'warden\warden-launcher.exe');ProcessId=100;ParentId=1;Session=1;CreatedUTC=$created;Sid=$script:FixtureIdentity.Sid},
                [pscustomobject]@{Path=(Join-Path $dir 'warden\warden.exe');ProcessId=101;ParentId=100;Session=1;CreatedUTC=$created.AddSeconds(1);Sid=$script:FixtureIdentity.Sid},
                [pscustomobject]@{Path=(Join-Path $dir 'warden\warden.exe');ProcessId=102;ParentId=101;Session=1;CreatedUTC=$created.AddSeconds(2);Sid=$script:FixtureIdentity.Sid},
                [pscustomobject]@{Path=(Join-Path $dir 'watchtower.exe');ProcessId=103;ParentId=102;Session=1;CreatedUTC=$created.AddSeconds(3);Sid=$script:FixtureIdentity.Sid}
            )
            Set-FixtureDrainRows $rows
        }
        function script:Test-WtgInstalledStartup {param($Context,$Plan,$Before)
            $rows=@(Get-WtgOwnedProcesses $Plan)
            if(-not $Before -or -not $Before.FixtureOnly -or -not (Test-WtgProcessParentage $Plan $rows 1) -or @($script:Fixture.Processes.Values|Where-Object{$_.Exited}).Count){throw 'FIXTURE_INVALID_STARTUP_CHAIN'}
            $script:Fixture.Events.Add('Verify:fixture-chain')
            if($script:Fixture.FailVerification){$script:Fixture.FailVerification=$false;throw 'FIXTURE_VERIFY_FAILURE'}
            return [pscustomobject]@{State='FixtureManagedChainVerified';FixtureOnly=$true;Processes=$rows}
        }
        function script:Set-WtgUnattendedStartup {param($Context,$Plan)
            if($Context.StartupMode -cne 'AfterSignIn'){throw 'FIXTURE_UNEXPECTED_AUTOLOGON_REQUEST'}
            return 'AfterSignInConfiguredButUnverified'
        }
        function script:Start-Process {throw 'FIXTURE_REAL_PROCESS_LAUNCH_FORBIDDEN'}
        function script:Stop-Process {throw 'FIXTURE_REAL_PROCESS_STOP_FORBIDDEN'}
        function script:Get-Service {throw 'FIXTURE_REAL_SERVICE_ACCESS_FORBIDDEN'}
        function script:Set-ExecutionPolicy {throw 'FIXTURE_SECURITY_CHANGE_FORBIDDEN'}
    } $root $identity $videoModule

    foreach($case in @('success','rollback','before-replace-rollback','new-actor-rollback-refusal')){
        $context=[pscustomobject]@{RunId=('fixture-managed-'+$case);InstallDir=(Join-Path $root ('installed-'+$case));InstallScope='User';TargetUser=$identity.Name;TargetSid=$identity.Sid;StartupMode='AfterSignIn';Language='en';BackendUrl='';OverrideRequirements=@();NonInteractive=$false;PackageManifestSha256=$manifestHash;AdoptExisting=$false;LegacyTaskName=''}
        $plan=Get-WtgInstallPlan $context $identity
        [IO.Directory]::CreateDirectory((Join-Path $plan.Directory 'warden'))|Out-Null
        [IO.Directory]::CreateDirectory((Split-Path -Parent $plan.ConfigPath))|Out-Null
        foreach($name in @('watchtower.exe','warden\warden.exe','warden\warden-launcher.exe','retained-old-file.txt')){[IO.File]::WriteAllText((Join-Path $plan.Directory $name),'old fixture bytes: '+$name)}
        $oldMarker=[ordered]@{product='CilexWatchtower';schemaVersion=1;installId=$plan.Id;targetSid=$identity.Sid;installDir=$plan.Directory;installScope='User';taskName=$plan.TaskName;version='1.1.779';wardenVersion='1.4.10';sourceCommit=('a'*40);manifestSha256=('c'*64);runId='fixture-old-managed';files=@()}
        [IO.File]::WriteAllText((Join-Path $plan.Directory '.cilex-install.json'),($oldMarker|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding $false))
        $oldConfig='APP_CMD='+(Join-Path $plan.Directory 'watchtower.exe')+"`r`nAPP_ENV=KEEP=fixture-only,VALUE_WITH_EQUALS=one=two`r`nSTATION_TOKEN=fixture-not-a-secret`r`nBACKEND_URL=http://127.0.0.1:1"
        [IO.File]::WriteAllText($plan.ConfigPath,$oldConfig,(New-Object Text.UTF8Encoding $false))
        $managed=[pscustomobject]@{TaskName=$plan.TaskName;TaskPath='\';Principal=[pscustomobject]@{UserId=$identity.Sid;LogonType='Interactive';RunLevel='Limited'};Settings=[pscustomobject]@{Enabled=$true};State='Running';Actions=@([pscustomobject]@{Execute=(Join-Path $plan.Directory 'warden\warden-launcher.exe');Arguments='run';WorkingDirectory=$plan.Directory});Triggers=@('fixture-old-trigger')}
        $legacy=[pscustomobject]@{TaskName='wt-warden';TaskPath='\';Principal=[pscustomobject]@{UserId=$identity.Sid;LogonType='Interactive';RunLevel='Limited'};Settings=[pscustomobject]@{Enabled=$false};State='Disabled';Actions=@([pscustomobject]@{Execute=(Join-Path $plan.Directory 'warden\warden.exe');Arguments='run';WorkingDirectory=$null});Triggers=@('retained-legacy-trigger')}
        $fixture=[pscustomobject]@{Plan=$plan;Tasks=@{};Xml=@{};Rows=@();Events=(New-Object 'Collections.Generic.List[string]');Registration=[pscustomobject]@{Version='1.1.779';FixtureOnly=$true};FailVerification=($case -eq 'rollback');InitialManagedTask=$managed;InitialManagedXml=''}
        $drainState=New-WtgDrainFixtureState $plan @()
        foreach($property in $drainState.PSObject.Properties){if(-not $fixture.PSObject.Properties[$property.Name]){$fixture|Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value}}
        $fixture|Add-Member -NotePropertyName BeforeMoveFailureObserved -NotePropertyValue $false
        $fixture|Add-Member -NotePropertyName CaseRunId -NotePropertyValue $context.RunId
        if($case -eq 'before-replace-rollback'){$fixture.InjectDrainedQueryError='INSTALL_PROCESS_RESPAWNED'}
        if($case -eq 'new-actor-rollback-refusal'){$fixture.InjectLiveRootAfterExit=$true}
        Install-WtgDrainFixtureCapabilities $module $fixture
        $fixture.Tasks[$plan.TaskName]=$managed;$fixture.Tasks['wt-warden']=$legacy
        & $module {param($State)
            $script:Fixture=$State
            $script:Fixture.Xml[$State.Plan.TaskName]=(Get-FixtureXml $State.Tasks[$State.Plan.TaskName]).Replace('<Settings>','<!-- old managed task must return exactly --><Settings>')
            $script:Fixture.Xml['wt-warden']=Get-FixtureXml $State.Tasks['wt-warden']
            $script:Fixture.InitialManagedXml=$script:Fixture.Xml[$State.Plan.TaskName]
            $script:Fixture.InitialManagedTask=Copy-FixtureObject $State.Tasks[$State.Plan.TaskName]
            Start-ScheduledTask -TaskName $State.Plan.TaskName
            $script:Fixture.Events.Clear()
            $script:Fixture.OnDrainedQueryError={
                $directory=$script:Fixture.Plan.Directory;$parent=Split-Path -Parent $directory
                $script:Fixture.BeforeMoveFailureObserved=([IO.File]::ReadAllText((Join-Path $directory 'watchtower.exe')).StartsWith('old fixture bytes: ') -and (Test-Path -LiteralPath (Join-Path $parent ('.cilex-stage-'+$script:Fixture.CaseRunId))) -and -not (Test-Path -LiteralPath (Join-Path $parent ('.cilex-backup-'+$script:Fixture.CaseRunId))))
            }
            $script:Fixture.OnLiveRootInjected=$script:Fixture.OnDrainedQueryError
        } $fixture
        $legacyBefore=Json $fixture.Tasks['wt-warden'];$legacyXmlBefore=$fixture.Xml['wt-warden']
        $taskXmlBefore=$fixture.Xml[$plan.TaskName];$registrationBefore=Json $fixture.Registration
        $oldHashes=@{};foreach($file in Get-ChildItem -LiteralPath $plan.Directory -Recurse -File){$oldHashes[$file.FullName.Substring($plan.Directory.Length+1)]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
        $configHashBefore=(Get-FileHash -LiteralPath $plan.ConfigPath -Algorithm SHA256).Hash
        $marker=& $module {param($p)Assert-WtgOwnedInstallation $p} $plan
        Assert ($marker.version -eq '1.1.779') ($case+': current managed marker validates')
        $selection=Get-OfficeStartupSelection $plan $marker @($fixture.Tasks.Values)
        Assert (-not $selection.AdoptExisting -and $selection.TaskName -ceq $plan.TaskName) ($case+': actual wrapper selects managed task with inert legacy present')
        $context.AdoptExisting=$selection.AdoptExisting;$context.LegacyTaskName=$selection.TaskName
        Assert ($null -eq (& $module {param($c,$p)Get-WtgLegacyAdoption $c $p} $context $plan)) ($case+': managed selection cannot enter legacy adoption')
        Assert (& $module {param($p,$r)Test-WtgProcessParentage $p $r 1} $plan $fixture.Rows) ($case+': existing launcher and both Wardens own the app')
        if($case -in @('success','rollback')){
            $progressEvents=$fixture.Events
            $failRecoveryDisplay=$case -eq 'rollback'
            $recordProgress={
                param([string]$Stage)
                $progressEvents.Add('Progress:'+$Stage)
                if($failRecoveryDisplay -and $Stage -ceq 'RestoringPreviousVersion'){throw 'FIXTURE_RECOVERY_DISPLAY_FAILED'}
                'fixture progress output'
            }.GetNewClosure()
            $context|Add-Member -NotePropertyName InstallProgress -NotePropertyValue $recordProgress
        }
        $result=$null;$failure=$null
        try{$result=Install-WtgPackage $context $packageRoot}catch{$failure=$_}
        if($case -in @('success','rollback')){
            $expectedStages=@('CheckingRequirements','CheckingVideo','StagingFiles','ReplacingFiles','StartingWatchtower','VerifyingVideo')
            if($case -eq 'rollback'){$expectedStages+='RestoringPreviousVersion'}
            $stages=@($fixture.Events|Where-Object {$_ -like 'Progress:*'}|ForEach-Object {$_ -replace '^Progress:'})
            Assert (($stages -join '|') -ceq ($expectedStages -join '|')) ($case+': progress records each stage in order')
            $events=$fixture.Events
            Assert ($events.IndexOf('Progress:CheckingRequirements') -lt $events.IndexOf('Requirements:fixture-only')) ($case+': requirements progress precedes the requirements check')
            Assert ($events.IndexOf('Progress:CheckingVideo') -lt $events.IndexOf('VideoBaseline:fixture-only')) ($case+': baseline progress precedes the video check')
            Assert ($events.IndexOf('Progress:ReplacingFiles') -lt $events.IndexOf('RegisterNew:'+$plan.TaskName)) ($case+': replacement progress precedes registration of the new version')
            Assert ($events.IndexOf('Progress:StartingWatchtower') -lt $events.IndexOf('Start:'+$plan.TaskName)) ($case+': startup progress precedes startup')
            Assert ($events.IndexOf('Start:'+$plan.TaskName) -lt $events.IndexOf('Progress:VerifyingVideo') -and $events.IndexOf('Progress:VerifyingVideo') -lt $events.IndexOf('Verify:fixture-chain')) ($case+': verification progress occurs after startup and before verification')
            if($case -eq 'rollback'){
                Assert ($events.IndexOf('Verify:fixture-chain') -lt $events.IndexOf('Progress:RestoringPreviousVersion') -and $events.IndexOf('Progress:RestoringPreviousVersion') -lt $events.IndexOf('RegisterRestored:'+$plan.TaskName)) 'rollback: recovery progress follows failed verification and precedes restoration'
            }
        }
        if($case -eq 'success'){
            if($failure){throw $failure}
            Assert (@($result).Count -eq 1) 'success: callback output does not enter the installer result'
            Assert ($result.Version -eq '1.1.791' -and $result.WardenVersion -eq '1.5.0') 'success: real managed orchestrator reports new versions'
            Assert ($result.Runtime.FixtureOnly -and $result.Runtime.State -eq 'FixtureManagedChainVerified') 'success: fixture-only startup validates actual managed parentage'
            Assert (Test-Path -LiteralPath (Join-Path $result.Backup 'retained-old-file.txt')) 'success: complete prior directory remains in backup'
            Assert ((Get-FileHash -LiteralPath (Join-Path $plan.Directory 'watchtower.exe') -Algorithm SHA256).Hash -eq $files[0].sha256) 'success: actual directory transaction installs verified payload'
            Assert ([IO.File]::ReadAllText($plan.ConfigPath).Contains('VALUE_WITH_EQUALS=one=two')) 'success: existing non-runtime config survives actual config writer'
            Assert (($fixture.Events -join '|') -match ('Disable:'+ [regex]::Escape($plan.TaskName)+'.*Stop:'+ [regex]::Escape($plan.TaskName)+'.*RegisterNew:'+ [regex]::Escape($plan.TaskName)+'.*Start:'+ [regex]::Escape($plan.TaskName))) 'success: only managed startup is stopped, registered and started in order'
            $newMarker=& $module {param($p)Assert-WtgOwnedInstallation $p} $plan
            Assert ($newMarker.version -eq '1.1.791' -and $newMarker.wardenVersion -eq '1.5.0') 'success: owned marker advances with actual transaction'
        }elseif($case -eq 'new-actor-rollback-refusal'){
            Assert ($failure -and $failure.Exception.Message -eq 'INSTALL_FAILED_ROLLBACK_UNVERIFIED') 'new actor: actual transaction reports unverified recovery instead of adopting an unknown cohort'
            Assert ($failure.Exception.Data.Contains('RollbackVerified') -and -not $failure.Exception.Data['RollbackVerified']) 'new actor: recovery is explicitly unverified'
            Assert ($failure.Exception.Data['InstallFailure'].ErrorCode -eq 'INSTALL_PROCESS_RESPAWNED' -and $failure.Exception.Data['RollbackFailure'].ErrorCode -eq 'INSTALL_PROCESS_RESPAWNED') 'new actor: original refusal and recovery refusal are both retained'
            Assert ($fixture.LiveRootInjected -and -not $fixture.Processes[999].Exited -and -not(@($fixture.Killed|Where-Object{$_ -like '999|*'}).Count)) 'new actor: unexpected live root is never killed or replaced during recovery'
            Assert $fixture.BeforeMoveFailureObserved 'new actor: refusal occurs before original files move or replacement startup'
            Assert (@($fixture.Events|Where-Object{$_ -like 'RegisterNew:*' -or $_ -like 'RegisterRestored:*' -or $_ -like 'Start:*' -or $_ -eq 'Registration:new' -or $_ -eq 'Registration:restored'}).Count -eq 0) 'new actor: refusal never registers, restarts or reconfigures startup or registration'
            Assert (@($fixture.Events|Where-Object{$_ -like 'Disable:*' -or $_ -like 'Stop:*'}).Count -eq 2) 'new actor: recovery refusal precedes any second task disable or stop'
            Assert (-not $fixture.Tasks[$plan.TaskName].Settings.Enabled -and $fixture.Tasks[$plan.TaskName].State -eq 'Disabled') 'new actor: stopped owned task is not restarted around an unverified actor'
            Assert ((Get-FileHash -LiteralPath $plan.ConfigPath -Algorithm SHA256).Hash -eq $configHashBefore -and (Json $fixture.Registration) -ceq $registrationBefore) 'new actor: original configuration and registration are never overwritten'
            foreach($name in $oldHashes.Keys){Assert ((Get-FileHash -LiteralPath (Join-Path $plan.Directory $name) -Algorithm SHA256).Hash -eq $oldHashes[$name]) ('new actor: original file remains untouched: '+$name)}
            Assert (-not(Test-Path -LiteralPath (Join-Path (Split-Path -Parent $plan.Directory) ('.cilex-backup-'+$context.RunId))) -and -not(Test-Path -LiteralPath (Join-Path (Split-Path -Parent $plan.Directory) ('.cilex-failed-'+$context.RunId)))) 'new actor: no original or replacement directory moves during refused recovery'
        }else{
            $expectedFailure=if($case -eq 'before-replace-rollback'){'INSTALL_PROCESS_RESPAWNED'}else{'FIXTURE_VERIFY_FAILURE'}
            Assert ($failure -and $failure.Exception.Message -eq $expectedFailure) ($case+': original failure is reported without replacing its error')
            Assert ($failure.Exception.Data.Contains('RollbackVerified') -and $failure.Exception.Data['RollbackVerified']) 'rollback: actual transaction confirms recovery'
            Assert ($fixture.Xml[$plan.TaskName] -ceq $taskXmlBefore) 'rollback: exact old managed task XML returns'
            Assert ($fixture.Tasks[$plan.TaskName].Settings.Enabled -and $fixture.Tasks[$plan.TaskName].State -eq 'Running') 'rollback: prior enabled managed startup is restored and restarted'
            Assert ((Get-FileHash -LiteralPath $plan.ConfigPath -Algorithm SHA256).Hash -eq $configHashBefore) 'rollback: exact original config bytes return'
            Assert ((Json $fixture.Registration) -ceq $registrationBefore) 'rollback: original fixture registration returns'
            foreach($name in $oldHashes.Keys){Assert ((Get-FileHash -LiteralPath (Join-Path $plan.Directory $name) -Algorithm SHA256).Hash -eq $oldHashes[$name]) ('rollback: exact prior file restored: '+$name)}
            if($case -eq 'before-replace-rollback'){
                Assert $fixture.BeforeMoveFailureObserved 'before-replace failure occurs with original files in place and verified stage not moved'
                Assert (-not(Test-Path -LiteralPath (Join-Path (Split-Path -Parent $plan.Directory) ('.cilex-failed-'+$context.RunId)))) 'before-replace failure never renames old installation as failed new payload'
                Assert (-not(Test-Path -LiteralPath (Join-Path (Split-Path -Parent $plan.Directory) ('.cilex-backup-'+$context.RunId)))) 'before-replace failure never moves original installation to backup'
            }else{
                Assert (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $plan.Directory) ('.cilex-failed-'+$context.RunId+'\watchtower.exe'))) 'rollback: failed payload retained separately'
            }
            Assert (($fixture.Events -join '|') -match ('RegisterRestored:'+ [regex]::Escape($plan.TaskName)+'.*Enable:'+ [regex]::Escape($plan.TaskName)+'.*Start:'+ [regex]::Escape($plan.TaskName))) 'rollback: original managed task restoration precedes restart'
        }
        Assert ((Json $fixture.Tasks['wt-warden']) -ceq $legacyBefore -and $fixture.Xml['wt-warden'] -ceq $legacyXmlBefore) ($case+': disabled legacy task and XML remain byte-for-byte unchanged')
        Assert (-not(@($fixture.Events|Where-Object{$_ -match ':wt-warden$'}).Count)) ($case+': no capability was invoked against legacy task')
        if($case -ne 'new-actor-rollback-refusal'){Assert (& $module {param($p,$r)Test-WtgProcessParentage $p $r 1} $plan $fixture.Rows) ($case+': resulting app is owned by the complete managed launcher chain')}
        Assert (@($fixture.Opened|Where-Object{-not $_.Disposed}).Count -eq 0) ($case+': every retained native handle is disposed')
        Assert ($fixture.DeadOwnerCalls -eq 0 -and $fixture.Killed.Count -gt 0) ($case+': actual drain handles stale dead CIM owners and asynchronous descendants')
        Assert (@($fixture.Rows|Where-Object{$_.Sid -ne $identity.Sid -or $_.Session -ne 1}).Count -eq 0) ($case+': final old or new startup retains the exact intended user and desktop session')
    }
    Write-Output ('Managed Office update: '+$script:passed+' checks passed. Disposable files and in-memory Windows capabilities only.')
}finally{
    Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
    Remove-Module -Name fixture-video -Force -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($root)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'cilex-managed-office-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
