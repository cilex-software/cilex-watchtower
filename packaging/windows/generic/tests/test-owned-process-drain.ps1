#requires -Version 5.1
param([switch]$FixtureDefinitionsOnly)
# Real drain logic with raw CIM rows and retained native-handle doubles only.
# -FixtureDefinitionsOnly shares these OS doubles with the managed transaction
# test; it does not import a module or run any fixture entry point.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2

function New-WtgDrainFixtureState($Plan,[object[]]$Rows){
    return [pscustomobject]@{Plan=$Plan;Rows=$Rows;Processes=@{};Opened=(New-Object 'Collections.Generic.List[object]');Events=(New-Object 'Collections.Generic.List[string]');Killed=(New-Object 'Collections.Generic.List[string]');WaitArguments=(New-Object 'Collections.Generic.List[int]');CimQueries=0;DeadOwnerCalls=0;DenyHandlePid=0;OwnerGoneAfterExit=$true;OwnerExitRacePid=0;OwnerWaitRacePid=0;OwnerReturnCodeRacePid=0;CallbackCalled=$false;CallbackFault=$false;PersistentPid=0;KillRacePid=0;Generation=0;InjectDrainedQueryError=$null;DrainedQueryErrorInjected=$false;OnDrainedQueryError=$null;InjectLiveRootAfterExit=$false;LiveRootInjected=$false;OnLiveRootInjected=$null}
}

function Install-WtgDrainFixtureCapabilities($Module,$State){
    & $Module {param($State)
        $script:DrainFixture=$State
        function script:Get-FixtureDrainKey($Row){return ([string]$Row.ProcessId+'|'+([DateTime]$Row.CreatedUTC).ToUniversalTime().Ticks)}
        function script:Set-FixtureDrainRows([object[]]$Rows){
            $script:DrainFixture.Rows=$Rows;$script:DrainFixture.Processes=@{}
            foreach($row in $Rows){
                $process=[pscustomobject]@{Row=$row;NativeId=$row.ProcessId;NativeCreatedUTC=$row.CreatedUTC;NativePath=$row.Path;NativeSession=$row.Session;Exited=$false;KillRequested=$false;HasExitedReads=0;Persistent=($row.ProcessId -eq $script:DrainFixture.PersistentPid);KillRace=($row.ProcessId -eq $script:DrainFixture.KillRacePid)}
                $script:DrainFixture.Processes[[int]$row.ProcessId]=$process
            }
        }
        function script:Get-CimInstance {param($ClassName,$Filter,$ErrorAction)
            if($ClassName -eq 'Win32_OperatingSystem'){return [pscustomobject]@{LastBootUpTime=[DateTime]::Now.AddHours(-1)}}
            if($ClassName -ne 'Win32_Process'){throw 'FIXTURE_UNEXPECTED_CIM_CLASS'}
            $script:DrainFixture.CimQueries++
            if($script:DrainFixture.InjectLiveRootAfterExit -and -not $script:DrainFixture.LiveRootInjected -and $script:DrainFixture.CallbackCalled -and $script:DrainFixture.Processes.Count -gt 0 -and @($script:DrainFixture.Processes.Values|Where-Object{-not $_.Exited}).Count -eq 0){
                $script:DrainFixture.LiveRootInjected=$true
                $row=$script:DrainFixture.Rows[0].PSObject.Copy();$row.ProcessId=999;$row.ParentId=1;$row.CreatedUTC=[DateTime]::UtcNow
                $script:DrainFixture.Rows+=,$row
                $script:DrainFixture.Processes[999]=[pscustomobject]@{Row=$row;NativeId=999;NativeCreatedUTC=$row.CreatedUTC;NativePath=$row.Path;NativeSession=$row.Session;Exited=$false;KillRequested=$false;HasExitedReads=0;Persistent=$false;KillRace=$false}
                $script:DrainFixture.Events.Add('UnexpectedLiveRoot:999')
                if($script:DrainFixture.OnLiveRootInjected){& $script:DrainFixture.OnLiveRootInjected}
            }
            if($script:DrainFixture.InjectDrainedQueryError -and -not $script:DrainFixture.DrainedQueryErrorInjected -and $script:DrainFixture.CallbackCalled -and $script:DrainFixture.Processes.Count -gt 0 -and @($script:DrainFixture.Processes.Values|Where-Object{-not $_.Exited}).Count -eq 0){
                $script:DrainFixture.DrainedQueryErrorInjected=$true
                if($script:DrainFixture.OnDrainedQueryError){& $script:DrainFixture.OnDrainedQueryError}
                # This fault occurs only after native exit was proven. A later
                # CIM recovery sample can now stop reporting the old dead rows.
                $script:DrainFixture.Rows=@()
                throw $script:DrainFixture.InjectDrainedQueryError
            }
            foreach($row in $script:DrainFixture.Rows){
                [pscustomobject]@{Name=[IO.Path]::GetFileName($row.Path);ExecutablePath=$row.Path;CommandLine=('"'+$row.Path+'" fixture');ProcessId=$row.ProcessId;ParentProcessId=$row.ParentId;SessionId=$row.Session;CreationDate=$row.CreatedUTC;FixtureOwnerSid=$row.Sid;FixtureKey=(Get-FixtureDrainKey $row)}
            }
        }
        function script:Invoke-CimMethod {param($InputObject,$MethodName,$ErrorAction)
            if($MethodName -cne 'GetOwnerSid'){throw 'FIXTURE_UNEXPECTED_CIM_METHOD'}
            $process=$script:DrainFixture.Processes[[int]$InputObject.ProcessId]
            if($process -and $script:DrainFixture.CallbackCalled -and $InputObject.ProcessId -eq $script:DrainFixture.OwnerExitRacePid){$process.Exited=$true}
            if($process -and $script:DrainFixture.CallbackCalled -and $InputObject.ProcessId -in @($script:DrainFixture.OwnerWaitRacePid,$script:DrainFixture.OwnerReturnCodeRacePid)){
                $process|Add-Member -NotePropertyName WaitCompletesExit -NotePropertyValue $true -Force
                if($InputObject.ProcessId -eq $script:DrainFixture.OwnerReturnCodeRacePid){return [pscustomobject]@{ReturnValue=1;Sid=$null}}
                throw 'FIXTURE_FINISHING_OWNER_UNAVAILABLE'
            }
            if($process -and $process.Exited -and $script:DrainFixture.OwnerGoneAfterExit){$script:DrainFixture.DeadOwnerCalls++;throw 'FIXTURE_EXITED_OWNER_UNAVAILABLE'}
            return [pscustomobject]@{ReturnValue=0;Sid=$InputObject.FixtureOwnerSid}
        }
        function script:Get-WtgNativeProcessHandle([int]$ProcessId){
            if($ProcessId -eq $script:DrainFixture.DenyHandlePid){throw (New-Object UnauthorizedAccessException 'Fixture denied native process access')}
            if(-not $script:DrainFixture.Processes.ContainsKey($ProcessId)){return $null}
            $process=$script:DrainFixture.Processes[$ProcessId]
            $handle=[pscustomobject]@{Process=$process;Fixture=$script:DrainFixture;Disposed=$false;Token=($script:DrainFixture.Opened.Count+1000)}
            $handle|Add-Member -MemberType ScriptProperty -Name Id -Value {return [int]$this.Process.NativeId}
            $handle|Add-Member -MemberType ScriptProperty -Name Handle -Value {return [IntPtr]$this.Token}
            $handle|Add-Member -MemberType ScriptProperty -Name HasExited -Value {$this.Process.HasExitedReads++;return [bool]$this.Process.Exited}
            $handle|Add-Member -MemberType ScriptProperty -Name StartTime -Value {return [DateTime]$this.Process.NativeCreatedUTC}
            $handle|Add-Member -MemberType ScriptProperty -Name MainModule -Value {
                if($this.Process.PSObject.Properties['ModuleReadThrows'] -and $this.Process.ModuleReadThrows){throw 'FIXTURE_TERMINATING_MODULE_UNAVAILABLE'}
                return [pscustomobject]@{FileName=$this.Process.NativePath}
            }
            $handle|Add-Member -MemberType ScriptProperty -Name SessionId -Value {return $this.Process.NativeSession}
            $handle|Add-Member -MemberType ScriptMethod -Name Kill -Value {
                if(-not $this.Fixture.CallbackCalled){throw 'FIXTURE_KILL_BEFORE_VERIFIED_CALLBACK'}
                $this.Fixture.Killed.Add(([string]$this.Id+'|'+([DateTime]$this.Process.Row.CreatedUTC).Ticks));$this.Fixture.Events.Add('Kill:'+$this.Id)
                $this.Process.KillRequested=$true
                if($this.Process.KillRace){$this.Process.Exited=$true;throw 'FIXTURE_ALREADY_TERMINATING'}
                if(-not $this.Process.Persistent){$this.Process.Exited=$true}
            }
            $handle|Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {param($Milliseconds)
                $this.Fixture.WaitArguments.Add([int]$Milliseconds)
                if($this.Process.PSObject.Properties['WaitCompletesExit'] -and $this.Process.WaitCompletesExit){$this.Process.Exited=$true}
                return [bool]$this.Process.Exited
            }
            $handle|Add-Member -MemberType ScriptMethod -Name Dispose -Value {$this.Disposed=$true}
            $script:DrainFixture.Opened.Add($handle);$script:DrainFixture.Events.Add('Open:'+$ProcessId)
            return $handle
        }
        function script:Start-Sleep {param($Milliseconds,$Seconds)
            # Yield a real millisecond only for bounded-deadline tests. This does
            # not call a Windows task/process/service API or mutate any machine state.
            [Threading.Thread]::Sleep(1)
        }
        function script:Get-Process {throw 'FIXTURE_REAL_PROCESS_QUERY_FORBIDDEN'}
        function script:Start-Process {throw 'FIXTURE_REAL_PROCESS_START_FORBIDDEN'}
        function script:Stop-Process {throw 'FIXTURE_REAL_PROCESS_STOP_FORBIDDEN'}
        function script:Get-Service {throw 'FIXTURE_REAL_SERVICE_QUERY_FORBIDDEN'}
        function script:Set-ExecutionPolicy {throw 'FIXTURE_SECURITY_CHANGE_FORBIDDEN'}
        Set-FixtureDrainRows $State.Rows
    } $State
}

if($FixtureDefinitionsOnly){return}
$script:passed=0
function Assert($Value,[string]$Name){if(-not $Value){throw ('FAIL: '+$Name)};$script:passed++}
function Reject([scriptblock]$Action,[string]$Code){$failure=$null;try{& $Action|Out-Null}catch{$failure=$_};Assert ($failure -and $failure.Exception.Message -like ('*'+$Code+'*')) $Code;return $failure}
$module=Import-Module (Join-Path $PSScriptRoot '..\Install.psm1') -Force -PassThru
try{
    $plan=[pscustomobject]@{Directory='C:\Fixture\Cilex Watchtower';Identity=[pscustomobject]@{Sid='S-1-5-21-1-2-3-1001'}}
    function New-Chain {
        $created=[DateTime]::UtcNow.AddMinutes(-5)
        return @(
            [pscustomobject]@{Path=(Join-Path $plan.Directory 'warden\warden-launcher.exe');ProcessId=100;ParentId=1;Session=1;CreatedUTC=$created;Sid=$plan.Identity.Sid},
            [pscustomobject]@{Path=(Join-Path $plan.Directory 'warden\warden.exe');ProcessId=101;ParentId=100;Session=1;CreatedUTC=$created.AddSeconds(1);Sid=$plan.Identity.Sid},
            [pscustomobject]@{Path=(Join-Path $plan.Directory 'warden\warden.exe');ProcessId=102;ParentId=101;Session=1;CreatedUTC=$created.AddSeconds(2);Sid=$plan.Identity.Sid},
            [pscustomobject]@{Path=(Join-Path $plan.Directory 'watchtower.exe');ProcessId=103;ParentId=102;Session=1;CreatedUTC=$created.AddSeconds(3);Sid=$plan.Identity.Sid}
        )
    }
    function Reset-Drain {
        $state=New-WtgDrainFixtureState $plan (New-Chain)
        Install-WtgDrainFixtureCapabilities $module $state
        return $state
    }
    $callback={
        & $module {
            $script:DrainFixture.CallbackCalled=$true;$script:DrainFixture.Events.Add('Callback')
            if($script:DrainFixture.CallbackFault){throw 'FIXTURE_CALLBACK_PARTIAL_FAILURE'}
        }
    }
    function Drain($Callback=$callback,[int]$Timeout=2000,$Admission=$null){& $module {param($p,$b,$t,$a)Stop-WtgOwnedProcesses -Plan $p -BeforeStop $b -TimeoutMilliseconds $t -Admission $a} $plan $Callback $Timeout $Admission}
    function Assert-Disposed($State,[string]$Label){Assert (@($State.Opened|Where-Object{-not $_.Disposed}).Count -eq 0) ($Label+': every acquired handle is disposed')}

    $state=Reset-Drain;$null=Drain
    Assert ($state.Killed.Count -eq 4) 'all four captured native generations drain without waiting for stale CIM removal'
    Assert ($state.Rows.Count -eq 4 -and @($state.Processes.Values|Where-Object{-not $_.Exited}).Count -eq 0) 'stale CIM rows are retained while native handles prove zero live processes'
    Assert ($state.DeadOwnerCalls -eq 0) 'dead retained generations are classified before querying unavailable owner data'
    Assert ($state.CimQueries -ge 3) 'capture and two fresh zero-live samples are observed'
    $callbackIndex=$state.Events.IndexOf('Callback');$eventsBeforeCallback=@($state.Events|Select-Object -First $callbackIndex)
    Assert ($callbackIndex -ge 4 -and ($eventsBeforeCallback -join ',') -eq 'Open:100,Open:101,Open:102,Open:103' -and @($eventsBeforeCallback|Where-Object{$_ -like 'Kill:*'}).Count -eq 0) 'all original native handles are captured before task-stop callback or any kill'
    Assert-Disposed $state 'successful four-process drain'

    $state=Reset-Drain
    $raceCallback={& $module {$script:DrainFixture.CallbackCalled=$true;$script:DrainFixture.Processes[100].Exited=$true;$script:DrainFixture.Processes[101].Exited=$true;$script:DrainFixture.Processes[102].KillRace=$true}}
    $null=Drain $raceCallback
    Assert ($state.Killed.Count -eq 2 -and @($state.Processes.Values|Where-Object{-not $_.Exited}).Count -eq 0) 'asynchronous job teardown and a terminating child race drain only remaining captured identities'
    Assert-Disposed $state 'asynchronous teardown'

    $state=Reset-Drain
    $newCallback={& $module {
        $script:DrainFixture.CallbackCalled=$true
        $row=$script:DrainFixture.Rows[0].PSObject.Copy();$row.ProcessId=999;$row.ParentId=1;$row.CreatedUTC=[DateTime]::UtcNow
        $script:DrainFixture.Rows+=,$row
        $script:DrainFixture.Processes[999]=[pscustomobject]@{Row=$row;NativeId=999;NativeCreatedUTC=$row.CreatedUTC;NativePath=$row.Path;NativeSession=1;Exited=$false;KillRequested=$false;HasExitedReads=0;Persistent=$false;KillRace=$false}
    }}
    $null=Reject {Drain $newCallback} 'INSTALL_PROCESS_RESPAWNED'
    Assert (-not(@($state.Killed|Where-Object{$_ -like '999|*'}).Count)) 'new live root is refused and never killed'
    Assert-Disposed $state 'new live root refusal'

    $state=Reset-Drain
    $reuseCallback={& $module {
        $script:DrainFixture.CallbackCalled=$true
        $script:DrainFixture.Processes[103].Exited=$true
        $row=$script:DrainFixture.Rows[3].PSObject.Copy();$row.CreatedUTC=$row.CreatedUTC.AddSeconds(1)
        $script:DrainFixture.Rows[3]=$row
        $script:DrainFixture.Processes[103]=[pscustomobject]@{Row=$row;NativeId=103;NativeCreatedUTC=$row.CreatedUTC;NativePath=$row.Path;NativeSession=1;Exited=$false;KillRequested=$false;HasExitedReads=0;Persistent=$false;KillRace=$false}
    }}
    $null=Reject {Drain $reuseCallback} 'INSTALL_PROCESS_CHANGED'
    Assert (-not(@($state.Killed|Where-Object{$_ -like '103|*'}).Count)) 'reused process ID is not killed through either old or new identity'
    Assert-Disposed $state 'process ID reuse'

    foreach($kind in @('id','creation','path','session')){
        $state=Reset-Drain
        switch($kind){'id'{$state.Processes[103].NativeId=999};'creation'{$state.Processes[103].NativeCreatedUTC=$state.Processes[103].NativeCreatedUTC.AddSeconds(1)};'path'{$state.Processes[103].NativePath='C:\Foreign\watchtower.exe'};'session'{$state.Processes[103].NativeSession=7}}
        $null=Reject {Drain} 'INSTALL_PROCESS_CHANGED'
        Assert (-not $state.CallbackCalled -and $state.Killed.Count -eq 0) ($kind+': changed identity refuses before callback or kill')
        Assert-Disposed $state ($kind+' identity change')
    }
    $state=Reset-Drain;$state.Rows[2].Sid='S-1-5-21-9-8-7-1001'
    $null=Reject {Drain} 'INSTALL_PROCESS_OWNER_OR_SESSION_MISMATCH'
    Assert (-not $state.CallbackCalled -and $state.Killed.Count -eq 0) 'foreign owner cannot reach task stop or process kill'
    Assert-Disposed $state 'foreign owner'
    $state=Reset-Drain;$state.Rows[2].Session=7
    $null=Reject {Drain} 'INSTALL_PROCESS_OWNER_OR_SESSION_MISMATCH'
    Assert (-not $state.CallbackCalled -and $state.Killed.Count -eq 0) 'mixed nonzero desktop sessions are refused before task stop'
    Assert-Disposed $state 'mixed desktop sessions'
    foreach($change in @('owner','session','path','creation')){
        $state=Reset-Drain
        & $module {param($Change)$script:FixturePostCaptureChange=$Change} $change
        $changedCallback={& $module {
            $script:DrainFixture.CallbackCalled=$true
            switch($script:FixturePostCaptureChange){
                'owner'{$script:DrainFixture.Rows[2].Sid='S-1-5-21-9-8-7-1001'}
                'session'{$script:DrainFixture.Rows[2].Session=7}
                'path'{$script:DrainFixture.Rows[2].Path=Join-Path $script:DrainFixture.Plan.Directory 'watchtower.exe'}
                'creation'{$script:DrainFixture.Rows[2].CreatedUTC=$script:DrainFixture.Rows[2].CreatedUTC.AddSeconds(1)}
            }
        }}
        $code=if($change -eq 'owner'){'INSTALL_PROCESS_OWNER_OR_SESSION_MISMATCH'}else{'INSTALL_PROCESS_CHANGED'}
        $null=Reject {Drain $changedCallback} $code
        Assert ($state.Killed.Count -eq 0) ($change+': post-capture ownership or identity change refuses without any kill')
        Assert-Disposed $state ($change+' change after capture')
    }

    $state=Reset-Drain;$state.OwnerExitRacePid=102
    $null=Drain
    Assert ($state.DeadOwnerCalls -eq 1 -and $state.Killed.Count -eq 3) 'a captured process exiting during owner lookup is accepted only after retained native exit proof'
    Assert-Disposed $state 'owner lookup exit race'
    foreach($failureMode in @('throw','return-code')){
        $state=Reset-Drain
        if($failureMode -eq 'throw'){$state.OwnerWaitRacePid=102}else{$state.OwnerReturnCodeRacePid=102}
        $null=Drain
        Assert ($state.Processes[102].Exited -and -not(@($state.Killed|Where-Object{$_ -like '102|*'}).Count)) ($failureMode+': failed owner lookup for a captured finishing process waits for held exit proof without killing it')
        Assert ($state.WaitArguments.Count -gt 0) ($failureMode+': owner teardown race uses a bounded native wait')
        Assert-Disposed $state ($failureMode+' owner teardown race')
    }

    $state=Reset-Drain
    $moduleExitCallback={& $module {
        $script:DrainFixture.CallbackCalled=$true
        $script:DrainFixture.Processes[103]|Add-Member -NotePropertyName ModuleReadThrows -NotePropertyValue $true
        $script:DrainFixture.Processes[103]|Add-Member -NotePropertyName WaitCompletesExit -NotePropertyValue $true
    }}
    $null=Drain $moduleExitCallback
    Assert ($state.Processes[103].Exited -and -not(@($state.Killed|Where-Object{$_ -like '103|*'}).Count)) 'module metadata becoming unreadable after capture waits for exact held exit proof without killing unverified process'
    Assert-Disposed $state 'module metadata teardown race'

    $state=Reset-Drain
    $moduleLiveCallback={& $module {
        $script:DrainFixture.CallbackCalled=$true
        $script:DrainFixture.Processes[103]|Add-Member -NotePropertyName ModuleReadThrows -NotePropertyValue $true
    }}
    $null=Reject {Drain $moduleLiveCallback} 'INSTALL_PROCESS_HANDLE_UNVERIFIED'
    Assert (-not $state.Processes[103].Exited -and -not(@($state.Killed|Where-Object{$_ -like '103|*'}).Count)) 'unreadable still-live captured process refuses and is never killed without identity proof'
    Assert-Disposed $state 'unreadable still-live process'

    $state=Reset-Drain
    $hiddenReuseCallback={& $module {
        $script:DrainFixture.CallbackCalled=$true;$script:DrainFixture.Processes[103].Exited=$true
        $row=$script:DrainFixture.Rows[3].PSObject.Copy();$row.CreatedUTC=$row.CreatedUTC.AddSeconds(1)
        $script:DrainFixture.Rows=@($script:DrainFixture.Rows|Where-Object{$_.ProcessId -ne 103})
        $script:DrainFixture.Processes[103]=[pscustomobject]@{Row=$row;NativeId=103;NativeCreatedUTC=$row.CreatedUTC;NativePath=$row.Path;NativeSession=1;Exited=$false;KillRequested=$false;HasExitedReads=0;Persistent=$false;KillRace=$false}
    }}
    $null=Reject {Drain $hiddenReuseCallback} 'INSTALL_PROCESS_CHANGED'
    Assert (-not(@($state.Killed|Where-Object{$_ -like '103|*'}).Count)) 'native observational reopen detects PID reuse even when fresh CIM omits that PID'
    Assert-Disposed $state 'PID reuse omitted by CIM'
    $state=Reset-Drain
    $staleReuseCallback={& $module {
        $script:DrainFixture.CallbackCalled=$true;$script:DrainFixture.Processes[103].Exited=$true
        $row=$script:DrainFixture.Rows[3].PSObject.Copy();$row.CreatedUTC=$row.CreatedUTC.AddSeconds(1)
        # CIM still reports the old row; native reopen observes the reused PID.
        $script:DrainFixture.Processes[103]=[pscustomobject]@{Row=$row;NativeId=103;NativeCreatedUTC=$row.CreatedUTC;NativePath=$row.Path;NativeSession=1;Exited=$false;KillRequested=$false;HasExitedReads=0;Persistent=$false;KillRace=$false}
    }}
    $null=Reject {Drain $staleReuseCallback} 'INSTALL_PROCESS_CHANGED'
    Assert (-not(@($state.Killed|Where-Object{$_ -like '103|*'}).Count)) 'old stale CIM generation cannot hide a different live native process using the same PID'
    Assert-Disposed $state 'PID reuse hidden by stale CIM'

    $state=Reset-Drain;$state.DenyHandlePid=102
    $failure=$null;try{$null=Drain}catch{$failure=$_}
    Assert ($failure -and -not $state.CallbackCalled -and $state.Killed.Count -eq 0) 'native access denial is a refusal before callback, never absence'
    Assert-Disposed $state 'access denial'

    $state=Reset-Drain;$state.Processes[103].Persistent=$true
    $null=Reject {Drain -Timeout 20} 'INSTALL_PROCESS_STOP_TIMEOUT'
    Assert ($state.Killed.Count -le 4 -and -not $state.Processes[103].Exited) 'deadline failure does not loop into killing additional or reused identities'
    Assert (@($state.WaitArguments|Where-Object{$_ -gt 20 -or $_ -lt 0}).Count -eq 0) 'every native wait is bounded by the shared deadline remainder'
    Assert-Disposed $state 'known-live deadline failure'

    $state=Reset-Drain;$state.CallbackFault=$true
    $null=Reject {Drain} 'FIXTURE_CALLBACK_PARTIAL_FAILURE'
    Assert ($state.CallbackCalled -and $state.Killed.Count -eq 0) 'partial task-stop callback failure preserves original error and performs no process kill'
    Assert-Disposed $state 'partial callback failure'
    # Recovery must reuse only the pre-authorized original cohort. A fresh
    # census cannot silently authorize a process born after the first refusal.
    $state=Reset-Drain;$admission=[pscustomobject]@{Initialized=$false;Rows=@()}
    $null=Drain -Admission $admission
    Assert ($admission.Initialized -and $admission.Rows.Count -eq 4) 'admission records exactly the four native-validated original generations'
    $admittedBefore=$admission.Rows|ConvertTo-Json -Depth 10 -Compress
    $killedBefore=$state.Killed.Count
    $null=Drain -Admission $admission
    Assert ($state.Killed.Count -eq $killedBefore -and ($admission.Rows|ConvertTo-Json -Depth 10 -Compress) -ceq $admittedBefore) 'recovery reuses original cohort without re-killing or admitting stale dead rows'
    Assert ($state.DeadOwnerCalls -eq 0) 'cross-call stale dead rows are proven natively before their unavailable owner method'
    Assert-Disposed $state 'cross-call original cohort reuse'
    $state.Processes=@{}
    $null=Drain -Admission $admission
    Assert ($state.Killed.Count -eq $killedBefore -and $state.Rows.Count -eq 4 -and $state.DeadOwnerCalls -eq 0) 'cross-call stale CIM rows with absent native processes allow original-cohort recovery'
    Assert-Disposed $state 'cross-call absent native processes'

    $state=Reset-Drain;$admission=[pscustomobject]@{Initialized=$false;Rows=@()};$null=Drain -Admission $admission
    & $module {
        $row=$script:DrainFixture.Rows[0].PSObject.Copy();$row.ProcessId=999;$row.ParentId=1;$row.CreatedUTC=[DateTime]::UtcNow
        $script:DrainFixture.Rows+=,$row
        $script:DrainFixture.Processes[999]=[pscustomobject]@{Row=$row;NativeId=999;NativeCreatedUTC=$row.CreatedUTC;NativePath=$row.Path;NativeSession=1;Exited=$false;KillRequested=$false;HasExitedReads=0;Persistent=$false;KillRace=$false}
    }
    $eventsBefore=$state.Events.Count;$killsBefore=$state.Killed.Count
    $null=Reject {Drain -Admission $admission} 'INSTALL_PROCESS_RESPAWNED'
    Assert ($state.Killed.Count -eq $killsBefore -and $state.Processes[999].Exited -eq $false -and -not(@($state.Events|Select-Object -Skip $eventsBefore|Where-Object{$_ -eq 'Callback'}).Count)) 'recovery refuses new live root before callback or any additional process kill'
    Assert ($admission.Rows.Count -eq 4 -and -not(@($admission.Rows|Where-Object{$_.ProcessId -eq 999}).Count)) 'refused new live root is never admitted into original recovery cohort'
    Assert-Disposed $state 'cross-call new-root refusal'

    foreach($reuse in @('original-live-omitted','new-generation-omitted')){
        $state=Reset-Drain;$admission=[pscustomobject]@{Initialized=$false;Rows=@()};$state.CallbackFault=$true
        $null=Reject {Drain -Admission $admission} 'FIXTURE_CALLBACK_PARTIAL_FAILURE'
        $state.CallbackFault=$false
        $state.Rows=@($state.Rows|Where-Object{$_.ProcessId -ne 103})
        if($reuse -eq 'new-generation-omitted'){
            & $module {
                $script:DrainFixture.Processes[103].Exited=$true
                $row=$script:DrainFixture.Processes[103].Row.PSObject.Copy();$row.CreatedUTC=$row.CreatedUTC.AddSeconds(1)
                $script:DrainFixture.Processes[103]=[pscustomobject]@{Row=$row;NativeId=103;NativeCreatedUTC=$row.CreatedUTC;NativePath=$row.Path;NativeSession=1;Exited=$false;KillRequested=$false;HasExitedReads=0;Persistent=$false;KillRace=$false}
            }
        }
        $callbackCountBefore=@($state.Events|Where-Object{$_ -eq 'Callback'}).Count
        $code=if($reuse -eq 'new-generation-omitted'){'INSTALL_PROCESS_CHANGED'}else{'INSTALL_PROCESS_HANDLE_UNVERIFIED'}
        $null=Reject {Drain -Admission $admission} $code
        Assert ($state.Killed.Count -eq 0 -and @($state.Events|Where-Object{$_ -eq 'Callback'}).Count -eq $callbackCountBefore) ($reuse+': recovery independently checks original native PID even when CIM omits it, before callback or kill')
        Assert (-not $state.Processes[103].Exited) ($reuse+': omitted unverified live generation is never killed or declared quiet')
        Assert-Disposed $state ($reuse+' cross-call admission proof')
    }

    $state=Reset-Drain;$admission=[pscustomobject]@{Initialized=$false;Rows=@()};$state.DenyHandlePid=102
    $captureFailure=$null;try{$null=Drain -Admission $admission}catch{$captureFailure=$_}
    Assert ($captureFailure -and $admission.Initialized -and $admission.Rows.Count -eq 2) 'partial first capture seals only successfully validated identities'
    $state.DenyHandlePid=0
    $null=Reject {Drain -Admission $admission} 'INSTALL_PROCESS_RESPAWNED'
    Assert (-not $state.CallbackCalled -and $state.Killed.Count -eq 0 -and $admission.Rows.Count -eq 2) 'retry after partial capture does not adopt identities never authorized'
    Assert-Disposed $state 'partial first-capture admission refusal'

    $state=Reset-Drain;$admission=[pscustomobject]@{Initialized=$false;Rows=@()};$state.Rows[2].Sid='S-1-5-21-9-8-7-1001'
    $null=Reject {Drain -Admission $admission} 'INSTALL_PROCESS_OWNER_OR_SESSION_MISMATCH'
    Assert ($admission.Initialized -and $admission.Rows.Count -eq 0) 'first census failure seals an empty cohort before native admission'
    $state.Rows[2].Sid=$plan.Identity.Sid
    $null=Reject {Drain -Admission $admission} 'INSTALL_PROCESS_RESPAWNED'
    Assert (-not $state.CallbackCalled -and $state.Killed.Count -eq 0) 'retry after failed census cannot introduce a new original cohort'
    Assert-Disposed $state 'failed-census sealed cohort'

    # Independently exercise the real native-handle wrapper, while its only
    # dependency Get-Process is an advanced-function double. Error identity must
    # distinguish an absent PID from denied or otherwise unverified access.
    $tokens=$null;$errors=$null;$source=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\Install.psm1'),[ref]$tokens,[ref]$errors)
    $nativeDefinition=$source.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-WtgNativeProcessHandle'},$false).Extent.Text
    $nativeModule=New-Module -ScriptBlock ([scriptblock]::Create($nativeDefinition+@'
function Get-Process {
    [CmdletBinding()]
    param($Id)
    if($script:Mode -eq 'exists'){return [pscustomobject]@{Id=$Id;FixtureOnly=$true}}
    $errorId=if($script:Mode -eq 'missing'){'NoProcessFoundForGivenId'}elseif($script:Mode -eq 'denied'){'PermissionDenied'}else{'UnexpectedNativeReadFailure'}
    $record=New-Object Management.Automation.ErrorRecord (New-Object InvalidOperationException 'Fixture native lookup failure'),$errorId,([Management.Automation.ErrorCategory]::ObjectNotFound),$Id
    $PSCmdlet.ThrowTerminatingError($record)
}
Export-ModuleMember -Function Get-WtgNativeProcessHandle
'@))
    try{
        & $nativeModule {$script:Mode='missing'}
        Assert ($null -eq (& $nativeModule {Get-WtgNativeProcessHandle 123})) 'only a genuine no-such-PID error is treated as absent'
        & $nativeModule {$script:Mode='exists'}
        Assert ((& $nativeModule {Get-WtgNativeProcessHandle 123}).FixtureOnly) 'existing native process lookup returns its retained handle object'
        foreach($mode in @('denied','other')){
            & $nativeModule {param($Mode)$script:Mode=$Mode} $mode
            $null=Reject {& $nativeModule {Get-WtgNativeProcessHandle 123}} 'INSTALL_PROCESS_HANDLE_UNVERIFIED'
        }
    }finally{Remove-Module -ModuleInfo $nativeModule -Force -ErrorAction SilentlyContinue}
    Write-Output ('Owned process drain: '+$script:passed+' checks passed. Raw CIM and native handles were in-memory fixtures only.')
}finally{Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue}
