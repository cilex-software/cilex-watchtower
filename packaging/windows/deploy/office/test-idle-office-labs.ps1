#requires -Version 5.1
# Isolated idle-Labs lifecycle regression. Definitions only are loaded; all
# Windows inspection and mutation capabilities are replaced before any entry.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$script:passed=0
function Assert($Value,[string]$Name){if(-not $Value){throw ('FAIL: '+$Name)};$script:passed++}
function Reject([scriptblock]$Action,[string]$Name){$caught=$false;try{& $Action|Out-Null}catch{if($_.Exception.Message -like 'FAIL:*' -or $_.Exception.Message -like 'FIXTURE_*_FORBIDDEN' -or $_.Exception.Message -like 'FIXTURE_UNSTUBBED_*'){throw};$caught=$true};Assert $caught $Name}
function Copy-Value($Value){return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 30)}
function Json($Value){return ConvertTo-Json -InputObject $Value -Depth 30 -Compress}

$wrapper=Join-Path $PSScriptRoot 'update-local-package.ps1'
$definitions=@()
foreach($path in @($wrapper)){
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){continue}
    $tokens=$null;$errors=$null
    $tree=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Idle-Labs source syntax did not parse.'}
    $definitions+=@($tree.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|ForEach-Object{$_.Extent.Text})
}
if(($definitions -join "`n") -notmatch 'function Get-OfficeIdleLabsPlan'){throw 'Idle-Labs implementation is unavailable.'}
$module=New-Module -Name ('OfficeIdleLabsFixture'+[Guid]::NewGuid().ToString('N')) -ScriptBlock ([scriptblock]::Create(($definitions -join "`n")+"`nExport-ModuleMember -Function *"))
$recordRoot=$null;$fakeInstaller=$null
try{
    # Install every seam before invoking any helper. Every other Windows task,
    # process, registry, policy, service and file-pin capability fails closed.
    & $module {
        function script:Clone-FixtureValue($Value){return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 30)}
        function script:New-FixtureTaskXml($Task){
            $escape=[Security.SecurityElement]
            $enabled=([string][bool]$Task.Settings.Enabled).ToLowerInvariant()
            $enabledXml='<Enabled>'+$enabled+'</Enabled>';$levelXml='<RunLevel>LeastPrivilege</RunLevel>'
            # Genuine Windows task exports omit default true/LeastPrivilege;
            # disabling emits false, and enabling removes it again.
            if($script:Case.WindowsDefaults){$levelXml='';if($Task.Settings.Enabled){$enabledXml=''}}
            return '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal><UserId>'+$escape::Escape([string]$Task.Principal.UserId)+'</UserId><LogonType>InteractiveToken</LogonType>'+$levelXml+'</Principal></Principals><Settings>'+$enabledXml+'</Settings><Actions><Exec><Command>'+$escape::Escape([string]$Task.Actions[0].Execute)+'</Command><Arguments>'+$escape::Escape([string]$Task.Actions[0].Arguments)+'</Arguments></Exec></Actions></Task>'
        }
        function script:Get-OfficeLabsExecutionContext {return Clone-FixtureValue $script:Case.Context}
        function script:Get-OfficeTaskSid {param($Task)if([string]$Task.Principal.UserId -notmatch '^S-1-'){throw 'OFFICE_LABS_TASK_UNVERIFIED'};return [string]$Task.Principal.UserId}
        function script:Get-OfficeLabsTaskSnapshot {return [pscustomobject]@{Task=(Clone-FixtureValue $script:Case.Task);Xml=$script:Case.Xml}}
        function script:Get-OfficeLabsTaskInstances {return $script:Case.Instances}
        function script:Get-OfficeLabsProcessRows {return $script:Case.Rows}
        function script:Get-OfficeLabsControlSnapshot {param($Identity)return Clone-FixtureValue $script:Case.Control}
        function script:Get-OfficeLabsFilePins {return Clone-FixtureValue $script:Case.Pins}
        function script:Get-OfficeLabsTasks {return @($script:Case.Tasks|ForEach-Object{Clone-FixtureValue $_})}
        function script:Disable-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)
            if($TaskName -cne 'wt-labs-start' -or ($TaskPath -and $TaskPath -cne '\')){throw 'FIXTURE_FOREIGN_TASK_MUTATION'}
            $recordReady=$script:Case.Records.Count -gt 0 -and $script:Case.Records[$script:Case.Records.Count-1].RestoreNeeded
            if($script:Case.DurablePath){
                $saved=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:Case.DurablePath))
                $recordReady=$saved.restoreNeeded -and $saved.phase -eq 'RestoreRequired'
            }
            if(-not $script:Case.Lease.RestoreNeeded -or -not $recordReady){throw 'FIXTURE_RECOVERY_NOT_DURABLE_BEFORE_DISABLE'}
            $script:Case.Events.Add('Disable')
            $script:Case.Task.Settings.Enabled=$false;$script:Case.Task.State='Disabled'
            $script:Case.Xml=New-FixtureTaskXml $script:Case.Task
            if($script:Case.PartialDisable){throw 'FIXTURE_DISABLE_PARTIAL'}
        }
        function script:Enable-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)
            if($TaskName -cne 'wt-labs-start' -or ($TaskPath -and $TaskPath -cne '\')){throw 'FIXTURE_FOREIGN_TASK_MUTATION'}
            $script:Case.Events.Add('Enable')
            if($script:Case.FailRestore){throw 'FIXTURE_RESTORE_FAILURE'}
            $script:Case.Task.Settings.Enabled=$true;$script:Case.Task.State='Ready'
            $script:Case.Xml=New-FixtureTaskXml $script:Case.Task
            if($script:Case.MaterializeTrueOnEnable){$script:Case.Xml=$script:Case.Xml.Replace('<Settings>','<Settings><Enabled>true</Enabled>')}
            if($script:Case.OmitTrueOnEnable){$script:Case.Xml=$script:Case.Xml.Replace('<Enabled>true</Enabled>','')}
            if($script:Case.AlterOtherXmlOnEnable){$script:Case.Xml=$script:Case.Xml.Replace('<Settings>','<Settings><Priority>8</Priority>')}
        }
        function script:Start-ScheduledTask {throw 'FIXTURE_START_FORBIDDEN'}
        function script:Stop-ScheduledTask {throw 'FIXTURE_STOP_FORBIDDEN'}
        function script:Register-ScheduledTask {throw 'FIXTURE_REGISTER_FORBIDDEN'}
        function script:Unregister-ScheduledTask {throw 'FIXTURE_UNREGISTER_FORBIDDEN'}
        function script:Get-ScheduledTask {throw 'FIXTURE_REAL_TASK_QUERY_FORBIDDEN'}
        function script:Export-ScheduledTask {throw 'FIXTURE_REAL_TASK_EXPORT_FORBIDDEN'}
        function script:Get-CimInstance {throw 'FIXTURE_REAL_CIM_QUERY_FORBIDDEN'}
        function script:Invoke-CimMethod {throw 'FIXTURE_REAL_CIM_METHOD_FORBIDDEN'}
        function script:Get-Process {throw 'FIXTURE_REAL_PROCESS_QUERY_FORBIDDEN'}
        function script:Start-Process {throw 'FIXTURE_REAL_PROCESS_START_FORBIDDEN'}
        function script:Stop-Process {throw 'FIXTURE_REAL_PROCESS_STOP_FORBIDDEN'}
        function script:Get-Service {throw 'FIXTURE_REAL_SERVICE_QUERY_FORBIDDEN'}
        function script:Get-Acl {throw 'FIXTURE_REAL_ACL_QUERY_FORBIDDEN'}
        function script:Set-Acl {throw 'FIXTURE_REAL_ACL_CHANGE_FORBIDDEN'}
        function script:Set-ExecutionPolicy {throw 'FIXTURE_POLICY_CHANGE_FORBIDDEN'}
        function script:New-Object {
            [CmdletBinding()]
            param([Parameter(Position=0)][string]$TypeName,[Parameter(Position=1)][object[]]$ArgumentList,[string]$ComObject)
            if($ComObject -or $TypeName -notin @('Xml.XmlDocument','Xml.XmlNamespaceManager','Text.UTF8Encoding')){throw ('FIXTURE_UNSTUBBED_OBJECT_'+$TypeName)}
            return Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
        }
        function script:Get-Content {throw 'FIXTURE_REAL_FILE_READ_FORBIDDEN'}
        function script:Set-Content {throw 'FIXTURE_REAL_FILE_WRITE_FORBIDDEN'}
        function script:Get-FileHash {throw 'FIXTURE_REAL_FILE_HASH_FORBIDDEN'}
    }
    function Reset-Case([bool]$Enabled=$true){
        $sid='S-1-5-21-463139321-2945944505-4245986892-1001'
        $identity=[pscustomobject]@{Sid=$sid;Name='WT-OFFICE-01\Fixture';LocalAppData='C:\Fixture\AppData\Local';Profile='C:\Fixture'}
        $task=[pscustomobject]@{TaskName='wt-labs-start';TaskPath='\';State=$(if($Enabled){'Ready'}else{'Disabled'});Settings=[pscustomobject]@{Enabled=$Enabled};Principal=[pscustomobject]@{UserId=$sid;LogonType='Interactive';RunLevel='Limited'};Actions=@([pscustomobject]@{Execute='wscript.exe';Arguments='//B //NoLogo C:\wt-labs\start-labs.vbs';WorkingDirectory=$null});Triggers=@()}
        $case=[pscustomobject]@{Identity=$identity;Task=$task;Xml='';Tasks=@($task);Instances=0;Rows=@();Context=[pscustomobject]@{Computer='WT-OFFICE-01';CurrentSid=$sid;Session=1;Administrator=$true};Control=[pscustomobject]@{Path='C:\Fixture\AppData\Local\watchtower-labs\control.json';Exists=$true;Sha256=('a'*64)};Pins=[pscustomobject]@{LauncherPath='C:\wt-labs\start-labs.vbs';LauncherSha256='D0CCA421F08A48563A5D05885C8C6776E43E85F410AE46F229D6E3B909014CD0';GuardPath='C:\wt-labs\guard3.ps1';GuardSha256='0422A323ECBE5EB010551B155FB1AF90B915EA8C980DF4D5DD768050C52B4502'};Events=(New-Object 'Collections.Generic.List[string]');Records=(New-Object 'Collections.Generic.List[object]');Lease=$null;PartialDisable=$false;FailPersist=$false;FailRestore=$false;RaceOnPersist=$false;DurablePath=$null;WindowsDefaults=$false;MaterializeTrueOnEnable=$false;OmitTrueOnEnable=$false;AlterOtherXmlOnEnable=$false}
        & $module {param($Case)$script:Case=$Case;$script:Case.Xml=New-FixtureTaskXml $Case.Task} $case
        return $case
    }
    function Plan($Case){
        $state=& $module {param($Identity,$Tasks)Get-OfficeIdleLabsPlan -Identity $Identity -Tasks $Tasks} $Case.Identity $Case.Tasks
        $Case.Lease=$state
        return $state
    }
    $persist={param($Record)
        & $module {param($r)
            if($script:Case.FailPersist){throw 'FIXTURE_PERSIST_FAILURE'}
            $script:Case.Records.Add((Clone-FixtureValue $r));$script:Case.Events.Add('Persist')
            if($script:Case.RaceOnPersist){$script:Case.Rows=@([pscustomobject]@{Name='python.exe';Path='C:\Python\python.exe';CommandLine='python.exe C:\wt-labs\run_worker.py --loop';OwnerSid=$script:Case.Identity.Sid;OwnerKnown=$true;Session=7;ProcessId=999;ParentId=111})}
        } $Record
    }
    function Enter($State,[switch]$WhatIf){& $module {param($s,$p,$w)Enter-OfficeIdleLabs -State $s -PersistRecovery $p -WhatIf:$w} $State $persist ([bool]$WhatIf)}
    function Frozen($State){& $module {param($s)Assert-OfficeIdleLabsFrozen -State $s} $State}
    function Exit-Lease($State,[switch]$WhatIf){& $module {param($s,$p,$w)Exit-OfficeIdleLabs -State $s -PersistRecovery $p -WhatIf:$w} $State $persist ([bool]$WhatIf)}
    function Definition($Case){& $module {param($Identity)Assert-OfficeLabsTaskDefinition (Get-OfficeLabsTaskSnapshot) $Identity} $Case.Identity}

    foreach($outcome in @('success','install-failure')){
        $case=Reset-Case;$state=Plan $case;$before=Json $case.Task;$xmlBefore=$case.Xml;$pinsBefore=Json $case.Pins;$controlBefore=Json $case.Control
        $failure=$null
        try{
            $null=Enter $state;$null=Frozen $state
            Assert (-not $case.Task.Settings.Enabled -and $case.Task.State -eq 'Disabled') ($outcome+': idle launcher remains disabled throughout mocked install')
            Assert ($state.RestoreNeeded -and $case.Records.Count -gt 0 -and $case.Records[0].RestoreNeeded) ($outcome+': recovery flag is set and saved before disabling')
            Assert (($case.Events -join ',') -match '^Persist,Disable') ($outcome+': recovery record precedes first task mutation')
            if($outcome -eq 'install-failure'){throw 'FIXTURE_INSTALL_FAILURE'}
        }catch{$failure=$_}finally{$null=Exit-Lease $state}
        Assert (($outcome -eq 'success' -and -not $failure) -or ($outcome -eq 'install-failure' -and $failure.Exception.Message -eq 'FIXTURE_INSTALL_FAILURE')) ($outcome+': original install outcome is retained')
        Assert ((Json $case.Task) -ceq $before -and $case.Xml -ceq $xmlBefore) ($outcome+': exact prior task and definition are restored')
        Assert (-not $state.RestoreNeeded -and @($case.Events|Where-Object{$_ -eq 'Enable'}).Count -eq 1) ($outcome+': enablement is restored once without starting the task')
        Assert ((Json $case.Pins) -ceq $pinsBefore -and (Json $case.Control) -ceq $controlBefore) ($outcome+': launcher/guard pins and existing control remain untouched')
    }
    foreach($outcome in @('success','install-failure')){
        $case=Reset-Case;$case.WindowsDefaults=$true;$case.Task.Triggers=$null
        & $module {$script:Case.Xml=New-FixtureTaskXml $script:Case.Task}
        $before=Json $case.Task;$xmlBefore=$case.Xml;$pinsBefore=Json $case.Pins;$controlBefore=Json $case.Control
        Assert ($case.Xml -notmatch '<(?:Enabled|RunLevel)>') ($outcome+': Windows-style original XML omits both defaults')
        $state=Plan $case;$failure=$null
        try{
            $null=Enter $state;$null=Frozen $state
            Assert ($case.Xml -match '<Enabled>false</Enabled>' -and $case.Xml -notmatch '<RunLevel>') ($outcome+': Windows-style Disable emits explicit false while retaining omitted RunLevel')
            Assert (-not $case.Task.Settings.Enabled -and $state.RestoreNeeded) ($outcome+': Windows-style launcher remains frozen through mocked install')
            if($outcome -eq 'install-failure'){throw 'FIXTURE_INSTALL_FAILURE'}
        }catch{$failure=$_}finally{$null=Exit-Lease $state}
        Assert (($outcome -eq 'success' -and -not $failure) -or ($outcome -eq 'install-failure' -and $failure.Exception.Message -eq 'FIXTURE_INSTALL_FAILURE')) ($outcome+': Windows-style lifecycle preserves installation outcome')
        Assert ($case.Xml -ceq $xmlBefore -and $case.Xml -notmatch '<(?:Enabled|RunLevel)>') ($outcome+': Windows-style Enable restores exact full XML with defaults omitted')
        Assert ((Json $case.Task) -ceq $before -and $case.Task.Settings.Enabled -and $state.Restored -and -not $state.RestoreNeeded) ($outcome+': Windows-style original task enablement and state return exactly')
        Assert ((Json $case.Pins) -ceq $pinsBefore -and (Json $case.Control) -ceq $controlBefore) ($outcome+': Windows-style lifecycle preserves exact existing control and file pins')
        Assert (@($case.Events|Where-Object{$_ -eq 'Disable'}).Count -eq 1 -and @($case.Events|Where-Object{$_ -eq 'Enable'}).Count -eq 1) ($outcome+': Windows-style lifecycle performs only one matched Disable and Enable')
    }
    foreach($value in @('true','false','1','0')){
        $expected=$value -in @('true','1');$case=Reset-Case $expected
        $case.Xml=$case.Xml -replace '<Enabled>[^<]*</Enabled>',('<Enabled>'+$value+'</Enabled>')
        $checked=Definition $case
        Assert ($checked.Enabled -eq $expected) ('schema boolean with matching strict API value is accepted: '+$value)
        $case.Task.Settings.Enabled=-not $expected
        Reject {Definition $case} ('schema boolean contradicting API is rejected: '+$value)
        Assert ($case.Events.Count -eq 0) ('contradictory schema boolean is rejected before any mutation: '+$value)
    }
    $case=Reset-Case;$case.WindowsDefaults=$true;& $module {$script:Case.Xml=New-FixtureTaskXml $script:Case.Task}
    $case.Task.Settings.Enabled=$false
    Reject {Definition $case} 'omitted XML Enabled cannot contradict strict API false'
    Assert ($case.Events.Count -eq 0) 'omitted-default contradiction is read-only'
    foreach($value in @('','yes','TRUE','False','2')){
        $case=Reset-Case;$case.Xml=$case.Xml.Replace('<Enabled>true</Enabled>',('<Enabled>'+$value+'</Enabled>'))
        Reject {Definition $case} ('invalid schema boolean remains rejected: '+$value)
    }
    $case=Reset-Case;$case.Xml=$case.Xml.Replace('<Enabled>true</Enabled>','<Enabled><Other>true</Other></Enabled>')
    Reject {Definition $case} 'nested content cannot impersonate a simple XML Enabled boolean'
    $case=Reset-Case;$case.Xml=$case.Xml.Replace('<Enabled>true</Enabled>',"<Enabled>`t 1 `r`n</Enabled>")
    Assert ((Definition $case).Enabled) 'XML schema whitespace around a matching boolean is accepted'
    foreach($duplicate in @('<Enabled>true</Enabled><Enabled>true</Enabled>','<Enabled>true</Enabled><Enabled>false</Enabled>')){
        $case=Reset-Case;$case.Xml=$case.Xml.Replace('<Enabled>true</Enabled>',$duplicate)
        Reject {Definition $case} 'duplicate XML Enabled elements remain rejected'
    }
    foreach($bad in @('missing-principal','foreign-principal','missing-logon','missing-action','foreign-action','xml-trigger')){
        $case=Reset-Case
        switch($bad){
            'missing-principal'{$case.Xml=$case.Xml -replace '<Principals>.*?</Principals>',''}
            'foreign-principal'{$case.Xml=$case.Xml.Replace('<UserId>'+$case.Identity.Sid+'</UserId>','<UserId>S-1-5-21-9-8-7-1001</UserId>')}
            'missing-logon'{$case.Xml=$case.Xml.Replace('<LogonType>InteractiveToken</LogonType>','')}
            'missing-action'{$case.Xml=$case.Xml -replace '<Actions>.*?</Actions>',''}
            'foreign-action'{$case.Xml=$case.Xml.Replace('<Command>wscript.exe</Command>','<Command>C:\Foreign\wscript.exe</Command>')}
            'xml-trigger'{$case.Xml=$case.Xml.Replace('<Actions>','<Triggers><TimeTrigger /></Triggers><Actions>')}
        }
        Reject {Definition $case} ('default compatibility does not relax ownership/action/trigger validation: '+$bad)
        Assert ($case.Events.Count -eq 0) ('malformed ownership/action/trigger rejection is read-only: '+$bad)
    }
    # Windows may serialize the intentionally toggled Enabled default either
    # explicitly or by omission. All remaining canonical XML must stay exact.
    $case=Reset-Case;$case.WindowsDefaults=$true;$case.MaterializeTrueOnEnable=$true
    & $module {$script:Case.Xml=New-FixtureTaskXml $script:Case.Task}
    $state=Plan $case;$null=Enter $state;$null=Exit-Lease $state
    $restoredDefinition=Definition $case
    Assert ($case.Task.Settings.Enabled -and $state.Restored -and -not $state.RestoreNeeded) 'materialized explicit true restores original enabled semantics'
    Assert ($restoredDefinition.Definition -ceq $state.OriginalDefinition -and $case.Xml -match '<Enabled>true</Enabled>') 'materialized true changes no canonical XML outside the intentional Enabled node'
    Assert (@($case.Events|Where-Object{$_ -eq 'Disable'}).Count -eq 1 -and @($case.Events|Where-Object{$_ -eq 'Enable'}).Count -eq 1) 'materialized true needs only one matched Disable and Enable'
    foreach($lexical in @('true','1')){
        $case=Reset-Case;$case.OmitTrueOnEnable=$true
        $case.Xml=$case.Xml.Replace('<Enabled>true</Enabled>',('<Enabled>'+$lexical+'</Enabled>'))
        $state=Plan $case;$null=Enter $state;$null=Exit-Lease $state
        $restoredDefinition=Definition $case
        Assert ($case.Task.Settings.Enabled -and $state.Restored -and -not $state.RestoreNeeded -and $case.Xml -notmatch '<Enabled>') ('enabled default may become omitted after restoring explicit '+$lexical)
        Assert ($restoredDefinition.Definition -ceq $state.OriginalDefinition) ('omitting restored '+$lexical+' changes no other canonical task XML')
    }
    $case=Reset-Case;$case.WindowsDefaults=$true;$case.AlterOtherXmlOnEnable=$true
    & $module {$script:Case.Xml=New-FixtureTaskXml $script:Case.Task}
    $state=Plan $case;$null=Enter $state
    Reject {Exit-Lease $state} 'semantic Enabled compatibility still rejects another XML field changing during restoration'
    Assert ($case.Task.Settings.Enabled -and $state.RecoveryRequired -and -not $state.Restored) 'changed non-Enabled XML remains truthfully unverified after enablement'
    $case=Reset-Case $false;$state=Plan $case;$before=Json $case.Task
    $null=Enter $state;$null=Frozen $state;$null=Exit-Lease $state
    Assert ((Json $case.Task) -ceq $before -and @($case.Events|Where-Object{$_ -in @('Enable','Disable')}).Count -eq 0) 'originally disabled launcher stays disabled without task mutation'
    $case=Reset-Case;$case.Task.Triggers=$null;$state=Plan $case
    Assert ($null -ne $state) 'explicit null task triggers are accepted only with empty XML triggers'
    $case=Reset-Case;$case.Task.PSObject.Properties.Remove('Triggers')
    Reject {Plan $case} 'missing task triggers remain unverified and are rejected'

    $case=Reset-Case;$state=Plan $case;$case.PartialDisable=$true;$caught=$false
    try{$null=Enter $state}catch{$caught=$true}finally{$null=Exit-Lease $state}
    Assert ($caught -and $case.Task.Settings.Enabled -and -not $state.RestoreNeeded) 'partially successful Disable exception still restores enablement in finally'
    Assert (($case.Events -join ',') -match 'Disable.*Enable') 'partial Disable recovery performs only matched enable restoration'

    $case=Reset-Case;$state=Plan $case;$case.FailPersist=$true
    try{$null=Enter $state}catch{}finally{if($state.RestoreNeeded){$null=Exit-Lease $state}}
    Assert ($case.Task.Settings.Enabled -and @($case.Events|Where-Object{$_ -in @('Enable','Disable')}).Count -eq 0) 'recovery persistence failure before Disable causes no task mutation'

    $case=Reset-Case;$state=Plan $case;$case.RaceOnPersist=$true
    Reject {Enter $state} 'actor appearing during recovery persistence is rejected before Disable'
    Assert ($case.Task.Settings.Enabled -and -not $state.RestoreNeeded -and @($case.Events|Where-Object{$_ -eq 'Disable'}).Count -eq 0) 'post-persistence race leaves the original task enabled and no false restoration obligation'

    $case=Reset-Case;$state=Plan $case;$null=Enter $state;$case.FailRestore=$true
    Reject {try{}finally{$null=Exit-Lease $state}} 'restoration failure throws and prohibits a successful final result'
    Assert ($state.RestoreNeeded -and -not $case.Task.Settings.Enabled) 'failed restoration keeps recovery required and task disabled'
    $case=Reset-Case;$state=Plan $case;$null=Enter $state;$case.FailPersist=$true
    Reject {Exit-Lease $state} 'failure to save restored recovery state cannot report success'
    Assert ($case.Task.Settings.Enabled -and $state.RecoveryRequired -and $state.RestoreNeeded -and -not $state.Restored) 'final recovery-write failure retains explicit recovery requirement even after enablement'

    foreach($bad in @('Running','Queued','Unknown','Ready-disabled','Disabled-enabled')){
        $case=Reset-Case
        switch($bad){'Ready-disabled'{$case.Task.Settings.Enabled=$false};'Disabled-enabled'{$case.Task.State='Disabled'};default{$case.Task.State=$bad}}
        Reject {Plan $case} ('unsafe or contradictory task state is refused: '+$bad)
        Assert ($case.Events.Count -eq 0) ('refusal is read-only: '+$bad)
    }
    foreach($bad in @('foreign','extra','trigger','instance','unknown-enabled','unknown-owner','wrong-session','wrong-host')){
        $case=Reset-Case
        switch($bad){
            'foreign'{$case.Task.Principal.UserId='S-1-5-21-9-8-7-1001'}
            'extra'{$other=Copy-Value $case.Task;$other.TaskName='wt-labs-extra';$case.Tasks+=,$other}
            'trigger'{$case.Task.Triggers=@([pscustomobject]@{Enabled=$true})}
            'instance'{$case.Instances=1}
            'unknown-enabled'{$case.Task.Settings.Enabled=$null}
            'unknown-owner'{$case.Task.Principal.UserId=''}
            'wrong-session'{$case.Context.Session=0}
            'wrong-host'{$case.Context.Computer='ANOTHER-PC'}
        }
        Reject {Plan $case} ('unverified task/context is refused: '+$bad)
        Assert ($case.Events.Count -eq 0) ('task/context refusal causes no mutation: '+$bad)
    }
    foreach($actor in @('worker-other-owner','worker-other-session','guard-other-session','shell-unreadable','python-unreadable','python3-unreadable','ffmpeg')){
        $case=Reset-Case
        $row=[pscustomobject]@{Name='python.exe';Path='C:\Python\python.exe';CommandLine='python.exe C:\wt-labs\run_worker.py --loop';OwnerSid=$case.Identity.Sid;OwnerKnown=$true;Session=1;ProcessId=999;ParentId=111}
        switch($actor){
            'worker-other-owner'{$row.OwnerSid='S-1-5-21-9-8-7-1001'}
            'worker-other-session'{$row.Session=7}
            'guard-other-session'{$row.Name='powershell.exe';$row.CommandLine='powershell.exe -File C:\wt-labs\guard3.ps1 -StartWorker';$row.Session=7}
            'shell-unreadable'{$row.Name='powershell.exe';$row.CommandLine=$null;$row.OwnerSid=$null;$row.OwnerKnown=$false}
            'python-unreadable'{$row.CommandLine=$null;$row.OwnerSid=$null;$row.OwnerKnown=$false}
            'python3-unreadable'{$row.Name='python3.12.exe';$row.CommandLine=$null;$row.OwnerSid=$null;$row.OwnerKnown=$false}
            'ffmpeg'{$row.Name='ffmpeg.exe';$row.Path='C:\wt-labs\ffmpeg.exe';$row.CommandLine='ffmpeg.exe -i fixture'}
        }
        $case.Rows=@($row)
        Reject {Plan $case} ('plausible active/unreadable Labs actor blocks: '+$actor)
        Assert ($case.Events.Count -eq 0) ('actor rejection causes no mutation: '+$actor)
    }
    foreach($race in @('definition','control-hash','control-presence','launcher-pin','guard-pin','process','task-state','instance')){
        $case=Reset-Case;$state=Plan $case
        switch($race){
            'definition'{$case.Task.Actions[0].Arguments+=' extra';$case.Xml+='<!-- changed -->'}
            'control-hash'{$case.Control.Sha256='d'*64}
            'control-presence'{$case.Control.Exists=$false;$case.Control.Sha256=$null}
            'launcher-pin'{$case.Pins.LauncherSha256='d'*64}
            'guard-pin'{$case.Pins.GuardSha256='d'*64}
            'process'{$case.Rows=@([pscustomobject]@{Name='python.exe';Path='C:\Python\python.exe';CommandLine='python.exe C:\wt-labs\run_worker.py --loop';OwnerSid=$case.Identity.Sid;OwnerKnown=$true;Session=1;ProcessId=999;ParentId=111})}
            'task-state'{$case.Task.State='Running'}
            'instance'{$case.Instances=1}
        }
        Reject {Enter $state} ('fresh pre-disable race is refused: '+$race)
        Assert (@($case.Events|Where-Object{$_ -in @('Enable','Disable')}).Count -eq 0) ('race refusal occurs before mutation: '+$race)
    }
    foreach($race in @('definition','control','pins','actor')){
        $case=Reset-Case;$state=Plan $case;$null=Enter $state
        switch($race){
            'definition'{$case.Task.Actions[0].Arguments+=' extra';$case.Xml+='<!-- changed -->'}
            'control'{$case.Control.Sha256='d'*64}
            'pins'{$case.Pins.GuardSha256='d'*64}
            'actor'{$case.Rows=@([pscustomobject]@{Name='ffmpeg.exe';Path='C:\wt-labs\ffmpeg.exe';CommandLine='ffmpeg.exe fixture';OwnerSid=$case.Identity.Sid;OwnerKnown=$true;Session=7;ProcessId=999;ParentId=111})}
        }
        Reject {Frozen $state} ('frozen-state check rejects concurrent change: '+$race)
        Reject {Exit-Lease $state} ('restoration refuses changed dependency: '+$race)
        Assert ($state.RestoreNeeded -and $state.RecoveryRequired -and @($case.Events|Where-Object{$_ -eq 'Enable'}).Count -eq 0) ('changed dependency retains recovery requirement without enabling: '+$race)
    }
    $case=Reset-Case
    $case.Rows=@([pscustomobject]@{Name='powershell.exe';Path='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';CommandLine='powershell.exe -NoProfile -Command fixture-read-only';OwnerSid=$case.Identity.Sid;OwnerKnown=$true;Session=1;ProcessId=111;ParentId=1})
    $state=Plan $case
    Assert ($null -ne $state) 'a fully readable unrelated PowerShell process is not mistaken for Labs'
    $case=Reset-Case;$state=Plan $case;$before=Json $case.Task
    $null=Enter $state -WhatIf;$null=Exit-Lease $state -WhatIf
    Assert ((Json $case.Task) -ceq $before -and $case.Events.Count -eq 0 -and $case.Records.Count -eq 0) 'WhatIf creates no recovery output and changes no task'
    Assert (-not $state.RestoreNeeded) 'WhatIf leaves no restoration obligation'

    # Exercise the actual private recovery writer on disposable files. The only
    # ACL capability is an in-memory fake installer that refuses external paths.
    $recordRoot=Join-Path ([IO.Path]::GetTempPath()) ('cilex-idle-labs-record-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($recordRoot)|Out-Null
    $fakeInstaller=New-Module -Name ('OfficeRecoveryAclFixture'+[Guid]::NewGuid().ToString('N')) -ScriptBlock {
        $script:Root=$null;$script:FailAcl=$false;$script:AclCalls=0
        function Set-WtgPrivateFileAcl($Path,$Sid){
            if(-not [IO.Path]::GetFullPath($Path).StartsWith($script:Root,[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_EXTERNAL_ACL_PATH'}
            if(-not [IO.File]::Exists($Path) -or [IO.File]::ReadAllBytes($Path).Length -ne 0){throw 'FIXTURE_ACL_MUST_PRECEDE_RECORD_CONTENT'}
            $script:AclCalls++
            if($script:FailAcl){throw 'FIXTURE_PRIVATE_ACL_FAILURE'}
        }
        Export-ModuleMember -Function Set-WtgPrivateFileAcl
    }
    & $fakeInstaller {param($Root)$script:Root=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'} $recordRoot
    $recoveryPath=Join-Path $recordRoot 'recovery.json';$installer=$fakeInstaller;$identity=$case.Identity
    $recoveryWriter=& $module {return ${function:Write-OfficeLabsRecoveryRecord}}
    if(-not $recoveryWriter){throw 'Recovery writer function is unavailable.'}
    # This exact captured-function closure is used by the real wrapper. A
    # function-name-only closure loses the local writer in its dynamic scope.
    $durablePersist={param($record)& $recoveryWriter $record $recoveryPath $installer $identity.Sid}.GetNewClosure()
    & $durablePersist ([pscustomobject]@{phase='Before';restoreNeeded=$true;marker='fixture-only'})
    $first=Get-Content -LiteralPath $recoveryPath -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($first.phase -eq 'Before' -and $first.restoreNeeded) 'actual captured writer closure saves complete JSON after private-ACL capability'
    & $durablePersist ([pscustomobject]@{phase='After';restoreNeeded=$false;marker='fixture replacement'})
    $second=Get-Content -LiteralPath $recoveryPath -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($second.phase -eq 'After' -and -not $second.restoreNeeded) 'actual writer atomically replaces an existing complete record'
    Assert (@(Get-ChildItem -LiteralPath $recordRoot -File|Where-Object{$_.Name -like '*.new-*'}).Count -eq 0) 'successful atomic replacement leaves no temporary record'
    $recordHash=(Get-FileHash -LiteralPath $recoveryPath -Algorithm SHA256).Hash
    & $fakeInstaller {$script:FailAcl=$true}
    Reject {& $durablePersist ([pscustomobject]@{phase='MustNotReplace'})} 'private-ACL failure throws before replacing the recovery record'
    Assert ((Get-FileHash -LiteralPath $recoveryPath -Algorithm SHA256).Hash -eq $recordHash) 'private-ACL failure preserves prior complete record bytes'
    Assert (@(Get-ChildItem -LiteralPath $recordRoot -File|Where-Object{$_.Name -like '*.new-*'}).Count -eq 0) 'failed private record creation removes its temporary file'
    & $fakeInstaller {$script:FailAcl=$false}
    $case=Reset-Case;$state=Plan $case;$case.DurablePath=$recoveryPath
    $identity=$case.Identity
    $durablePersist={param($record)& $recoveryWriter $record $recoveryPath $installer $identity.Sid}.GetNewClosure()
    try{
        & $module {param($s,$p)Enter-OfficeIdleLabs -State $s -PersistRecovery $p} $state $durablePersist
        $frozen=Get-Content -LiteralPath $recoveryPath -Raw -Encoding UTF8|ConvertFrom-Json
        Assert ($frozen.restoreNeeded -and $frozen.phase -eq 'Frozen' -and -not $case.Task.Settings.Enabled) 'actual lifecycle has durable recovery state while matched task is frozen'
    }finally{& $module {param($s,$p)Exit-OfficeIdleLabs -State $s -PersistRecovery $p} $state $durablePersist}
    $restored=Get-Content -LiteralPath $recoveryPath -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($restored.restored -and -not $restored.restoreNeeded -and $case.Task.Settings.Enabled) 'actual lifecycle restores enablement and atomically saves completed recovery'
    Assert ((& $fakeInstaller {$script:AclCalls}) -ge 5) 'each durable write passes the private-ACL capability before writing content'
    Write-Output ('Idle Office Labs: '+$script:passed+' checks passed. All Windows capabilities were in-memory fixtures.')
}finally{
    Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
    if($fakeInstaller){Remove-Module -ModuleInfo $fakeInstaller -Force -ErrorAction SilentlyContinue}
    if($recordRoot){
        $resolved=[IO.Path]::GetFullPath($recordRoot);$temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if($resolved.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'cilex-idle-labs-record-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
    }
}
