#requires -Version 5.1
# Disposable files and in-memory task/Labs fixtures only; no installer or service calls.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$path=Join-Path $PSScriptRoot 'update-local-package.ps1'
$tokens=$null;$errors=$null
$tree=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Wrapper syntax did not parse.'}
foreach($node in $tree.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){
    Invoke-Expression $node.Extent.Text
}
$script:passed=0
function Assert($Value,[string]$Name){if(-not $Value){throw ('FAIL: '+$Name)};$script:passed++}
function Reject([scriptblock]$Action,[string]$Code){$caught=$false;try{& $Action|Out-Null}catch{if($_.Exception.Message -ne $Code){throw};$caught=$true};Assert $caught $Code}
function Task([string]$Name,[string]$Exe,[string]$Sid='S-1-5-21-1-2-3-1001'){
    return [pscustomobject]@{TaskName=$Name;TaskPath='\';State='Ready';Principal=[pscustomobject]@{UserId=$Sid;LogonType='Interactive';RunLevel='Limited'};Settings=[pscustomobject]@{Enabled=$true};Actions=@([pscustomobject]@{Execute=$Exe;Arguments='run';WorkingDirectory=$null})}
}
function InertLegacyTask($Plan){
    $task=Task 'wt-warden' (Join-Path $Plan.Directory 'warden\warden.exe') $Plan.Identity.Sid
    $task.Settings.Enabled=$false;$task.State='Disabled'
    return $task
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('cilex-office-wrapper-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $root 'helpers'))|Out-Null
try{
    $privateDetail='private fixture error detail'
    $installDiagnostic=[pscustomobject][ordered]@{
        ErrorCode='INSTALL_OPERATION_FAILED'
        ExceptionType='System.IO.IOException'
        Script='Install.psm1'
        Line=642
        RawMessage=$privateDetail
    }
    $installFailure=[IO.IOException]::new($privateDetail)
    $installFailure.Data['InstallFailure']=$installDiagnostic
    $installFailure.Data['RollbackVerified']=$true
    $installRecord=[Management.Automation.ErrorRecord]::new($installFailure,'FixtureInstall',[Management.Automation.ErrorCategory]::ReadError,$privateDetail)
    $result=[ordered]@{errorCode=$null}
    Set-OfficeUpdateFailure $result $installRecord
    $serialized=$result|ConvertTo-Json -Depth 6 -Compress
    $reported=$serialized|ConvertFrom-Json
    Assert ($reported.errorCode -ceq 'OFFICE_UPDATE_FAILED' -and $reported.rollbackVerified -ceq $true) 'uncoded failure and verified rollback are reported'
    Assert (($reported.diagnostics.PSObject.Properties.Name -join ',') -ceq 'install') 'verified recovery contains only the available install diagnostic'
    Assert (($reported.diagnostics.install.PSObject.Properties.Name -join ',') -ceq 'ErrorCode,ExceptionType,Script,Line') 'diagnostic exposes only the four safe fields'
    Assert ($reported.diagnostics.install.ErrorCode -ceq 'INSTALL_OPERATION_FAILED' -and $reported.diagnostics.install.ExceptionType -ceq 'System.IO.IOException' -and $reported.diagnostics.install.Script -ceq 'Install.psm1' -and $reported.diagnostics.install.Line -eq 642) 'install diagnostic retains code, type and source location'
    Assert (-not $serialized.Contains($privateDetail)) 'raw exception text, target object and extra diagnostic data are excluded'

    $rollbackFailure=[InvalidOperationException]::new('INSTALL_FAILED_ROLLBACK_UNVERIFIED')
    $rollbackFailure.Data['InstallFailure']=$installDiagnostic
    $rollbackFailure.Data['RollbackFailure']=[pscustomobject]@{ErrorCode='INSTALL_PROCESS_RESPAWNED';ExceptionType='System.Management.Automation.RuntimeException';Script='Install.psm1';Line=371}
    $rollbackFailure.Data['RollbackVerified']=$false
    $rollbackRecord=[Management.Automation.ErrorRecord]::new($rollbackFailure,'FixtureRollback',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
    $result=[ordered]@{errorCode=$null}
    Set-OfficeUpdateFailure $result $rollbackRecord
    $reported=($result|ConvertTo-Json -Depth 6 -Compress)|ConvertFrom-Json
    Assert ($reported.errorCode -ceq 'INSTALL_FAILED_ROLLBACK_UNVERIFIED' -and $reported.rollbackVerified -ceq $false) 'controlled failure code and unverified rollback are reported'
    Assert (($reported.diagnostics.PSObject.Properties.Name -join ',') -ceq 'install,rollback' -and $reported.diagnostics.rollback.ErrorCode -ceq 'INSTALL_PROCESS_RESPAWNED' -and $reported.diagnostics.rollback.Line -eq 371) 'unverified recovery preserves both diagnostics in order'

    $preflightFailure=[InvalidOperationException]::new('OFFICE_TARGET_HOST_MISMATCH')
    $preflightRecord=[Management.Automation.ErrorRecord]::new($preflightFailure,'FixturePreflight',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
    $result=[ordered]@{errorCode=$null}
    Set-OfficeUpdateFailure $result $preflightRecord
    Assert ($result.errorCode -ceq 'OFFICE_TARGET_HOST_MISMATCH' -and -not $result.Contains('diagnostics') -and -not $result.Contains('rollbackVerified')) 'preflight failure keeps its code without inventing transaction evidence'

    $entries=@()
    foreach($name in @('Common.psm1','Install.psm1','Requirements.psm1','requirements.json','StationVideoHealth.psm1')){
        $file=Join-Path (Join-Path $root 'helpers') $name
        [IO.File]::WriteAllText($file,'fixture data; never imported')
        $entries+=@{path=$name;size=(Get-Item -LiteralPath $file).Length;sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}
    }
    $manifest=@{schemaVersion=1;product='CilexWatchtower';architecture='x64';helpers=$entries}
    $manifestPath=Join-Path $root 'manifest.json'
    [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 5))
    $hash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    Assert ((Test-OfficePackageTrust $root $hash).Root -eq $root) 'verified manifest and helpers accepted'
    Reject {Test-OfficePackageTrust $root ('0'*64)} 'OFFICE_PACKAGE_MANIFEST_HASH_MISMATCH'
    Reject {Test-OfficePackageTrust '\\host\share\package' $hash} 'OFFICE_PACKAGE_LOCAL_DIRECTORY_REQUIRED'
    [IO.File]::AppendAllText((Join-Path $root 'helpers\Common.psm1'),'changed')
    Reject {Test-OfficePackageTrust $root $hash} 'OFFICE_PACKAGE_HELPER_HASH_MISMATCH'
    [IO.File]::WriteAllText((Join-Path $root 'helpers\Common.psm1'),'fixture data; never imported')
    $manifest.helpers=@($entries)+@{path='../outside.ps1';size=0;sha256=('0'*64)}
    [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 5));$badHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    Reject {Test-OfficePackageTrust $root $badHash} 'OFFICE_PACKAGE_HELPER_PATH_INVALID'
    $manifest.helpers=$entries;[IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 5));$hash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $plan=[pscustomobject]@{Directory='C:\Fixture\Cilex Watchtower';TaskName='CilexWatchtower-fixture';Identity=[pscustomobject]@{Sid='S-1-5-21-1-2-3-1001'}}
    $legacy=Task 'wt-warden' (Join-Path $plan.Directory 'warden\warden.exe')
    $managed=Task $plan.TaskName (Join-Path $plan.Directory 'warden\warden-launcher.exe')
    Assert ((Get-OfficeStartupSelection $plan $null @($legacy)).AdoptExisting) 'one exact legacy task selected'
    Assert (-not (Get-OfficeStartupSelection $plan ([pscustomobject]@{}) @($managed)).AdoptExisting) 'marked managed task selected'
    Reject {Get-OfficeStartupSelection $plan $null @()} 'OFFICE_STARTUP_OWNERSHIP_AMBIGUOUS'
    Reject {Get-OfficeStartupSelection $plan $null @($legacy,$legacy)} 'OFFICE_STARTUP_OWNERSHIP_AMBIGUOUS'
    $foreign=Task 'wt-warden' (Join-Path $plan.Directory 'warden\warden.exe') 'S-1-5-21-9-8-7-1001'
    Reject {Get-OfficeStartupSelection $plan $null @($foreign)} 'OFFICE_STARTUP_OWNERSHIP_AMBIGUOUS'
    $nested=Task 'wt-warden' (Join-Path $plan.Directory 'warden\warden.exe');$nested.TaskPath='\Unrelated\'
    Reject {Get-OfficeStartupSelection $plan $null @($nested)} 'OFFICE_STARTUP_OWNERSHIP_AMBIGUOUS'
    $shell=Task 'wt-warden' 'powershell.exe';$shell.Actions[0].Arguments='-File "'+$plan.Directory+'\start.ps1"'
    Reject {Get-OfficeStartupSelection $plan $null @($shell)} 'OFFICE_STARTUP_OWNERSHIP_AMBIGUOUS'
    $legacy.Settings.Enabled=$false
    Reject {Get-OfficeStartupSelection $plan $null @($legacy)} 'OFFICE_STARTUP_DISABLED_REVIEW_REQUIRED'
    $legacy.Settings.Enabled=$true;$legacy.Actions[0].Arguments='run extra'
    Reject {Get-OfficeStartupSelection $plan $null @($legacy)} 'OFFICE_STARTUP_OWNERSHIP_AMBIGUOUS'
    # The successful generic adoption retained wt-warden disabled. Its inert
    # historical definition must not be mistaken for a second managed owner.
    $marker=[pscustomobject]@{}
    $inert=InertLegacyTask $plan
    $beforeInert=$inert|ConvertTo-Json -Depth 8 -Compress
    $selected=Get-OfficeStartupSelection $plan $marker @($managed,$inert)
    Assert ($selected.TaskName -ceq $plan.TaskName -and -not $selected.AdoptExisting) 'marked task selected beside exact disabled historical task'
    Assert ((Get-OfficeStartupSelection $plan $marker @($inert,$managed)).TaskName -ceq $plan.TaskName) 'historical task order does not affect selection'
    Assert (($inert|ConvertTo-Json -Depth 8 -Compress) -ceq $beforeInert) 'disabled historical task is preserved unchanged'
    $inert.Actions[0].WorkingDirectory=$plan.Directory
    Assert ((Get-OfficeStartupSelection $plan $marker @($managed,$inert)).TaskName -ceq $plan.TaskName) 'exact installation working directory accepted for historical task'
    $inert.Actions[0].WorkingDirectory=''
    Assert ((Get-OfficeStartupSelection $plan $marker @($managed,$inert)).TaskName -ceq $plan.TaskName) 'empty historical working directory accepted'
    Reject {Get-OfficeStartupSelection $plan $null @($managed,$inert)} 'OFFICE_STARTUP_OWNERSHIP_AMBIGUOUS'
    Reject {Get-OfficeStartupSelection $plan $marker @($managed,$inert,(InertLegacyTask $plan))} 'OFFICE_STARTUP_OWNERSHIP_AMBIGUOUS'
    Reject {Get-OfficeStartupSelection $plan $marker @($inert)} 'OFFICE_STARTUP_OWNERSHIP_AMBIGUOUS'
    $managed.Settings.Enabled=$false
    Reject {Get-OfficeStartupSelection $plan $marker @($managed,$inert)} 'OFFICE_STARTUP_DISABLED_REVIEW_REQUIRED'
    $managed.Settings.Enabled=$true
    $invalidHistorical=@(
        @{Name='enabled';Change={param($t)$t.Settings.Enabled=$true}},
        @{Name='running';Change={param($t)$t.State='Running'}},
        @{Name='ready';Change={param($t)$t.State='Ready'}},
        @{Name='unknown state';Change={param($t)$t.State='Unknown'}},
        @{Name='missing state';Change={param($t)$t.PSObject.Properties.Remove('State')}},
        @{Name='string disabled';Change={param($t)$t.Settings.Enabled='False'}},
        @{Name='null disabled';Change={param($t)$t.Settings.Enabled=$null}},
        @{Name='missing disabled';Change={param($t)$t.Settings.PSObject.Properties.Remove('Enabled')}},
        @{Name='missing settings';Change={param($t)$t.PSObject.Properties.Remove('Settings')}},
        @{Name='foreign user';Change={param($t)$t.Principal.UserId='S-1-5-21-9-8-7-1001'}},
        @{Name='different name';Change={param($t)$t.TaskName='wt-warden-other'}},
        @{Name='nested task';Change={param($t)$t.TaskPath='\Unrelated\'}},
        @{Name='extra action';Change={param($t)$t.Actions+=,[pscustomobject]@{Execute='cmd.exe';Arguments='';WorkingDirectory=$null}}},
        @{Name='extra arguments';Change={param($t)$t.Actions[0].Arguments='run extra'}},
        @{Name='trailing argument whitespace';Change={param($t)$t.Actions[0].Arguments='run '}},
        @{Name='argument case';Change={param($t)$t.Actions[0].Arguments='RUN'}},
        @{Name='different executable';Change={param($t)$t.Actions[0].Execute=Join-Path $plan.Directory 'warden\another.exe'}},
        @{Name='different working directory';Change={param($t)$t.Actions[0].WorkingDirectory='C:\Unrelated'}},
        @{Name='missing working directory';Change={param($t)$t.Actions[0].PSObject.Properties.Remove('WorkingDirectory')}},
        @{Name='password logon';Change={param($t)$t.Principal.LogonType='Password'}},
        @{Name='missing logon';Change={param($t)$t.Principal.PSObject.Properties.Remove('LogonType')}},
        @{Name='elevated principal';Change={param($t)$t.Principal.RunLevel='Highest'}},
        @{Name='missing run level';Change={param($t)$t.Principal.PSObject.Properties.Remove('RunLevel')}},
        @{Name='missing principal';Change={param($t)$t.PSObject.Properties.Remove('Principal')}}
    )
    foreach($case in $invalidHistorical){
        $invalid=InertLegacyTask $plan
        & $case.Change $invalid
        Reject {Get-OfficeStartupSelection $plan $marker @($managed,$invalid)} 'OFFICE_STARTUP_OWNERSHIP_AMBIGUOUS'
    }
    $now=[DateTime]::UtcNow
    $status=[pscustomobject]@{updated_at=$now.ToString('o');pid=123;units=@();current=$null;state='held';server_mode='enabled'}
    $hold=[pscustomobject]@{hold=[pscustomobject]@{why='operator maintenance';by='operator'}}
    Assert (Test-OfficeLabsBarrier $null $null 0 $false 0 $now) 'no Labs process or restart actor is safe'
    Assert (-not (Test-OfficeLabsBarrier $null $null 0 $true 0 $now)) 'unknown Labs restart state blocks'
    Assert (Test-OfficeLabsBarrier $status $hold 1 $true 123 $now) 'drained worker with operator hold is safe'
    $status.units=$null
    Assert (Test-OfficeLabsBarrier $status $hold 1 $true 123 $now) 'null units means no assigned work'
    $hold.hold.by='wall-guard'
    Assert (-not (Test-OfficeLabsBarrier $status $hold 1 $true 123 $now)) 'releasable wall guard hold blocks'
    $status.server_mode='paused'
    Assert (Test-OfficeLabsBarrier $status $hold 1 $true 123 $now) 'server pause and drained work is safe'
    $status.units=@('assigned')
    Assert (-not (Test-OfficeLabsBarrier $status $hold 1 $true 123 $now)) 'assigned work blocks'
    $status.units=@();$status.current=[pscustomobject]@{id='running'}
    Assert (-not (Test-OfficeLabsBarrier $status $hold 1 $true 123 $now)) 'current unit blocks'
    $status.current=$null
    Assert (-not (Test-OfficeLabsBarrier $status $hold 2 $true 123 $now)) 'multiple workers block'
    Assert (-not (Test-OfficeLabsBarrier $status $hold 1 $true 456 $now)) 'wrong worker status blocks'
    Assert (-not (Test-OfficeLabsBarrier $status $hold 1 $true 123 $now.AddSeconds(61))) 'stale Labs status blocks'
    # Real entry point, wrong-host read-only rejection; fixture helpers cannot execute.
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $before=@(Get-ChildItem -LiteralPath $root -Recurse -File).Count
    $output=& $powershell -NoProfile -NonInteractive -File $path -PackagePath $root -ManifestSha256 $hash -ExpectedHost 'NOT-THE-OFFICE-FIXTURE' -WhatIf 2>&1
    Assert ($LASTEXITCODE -eq 1 -and ($output -join "`n") -match 'OFFICE_TARGET_HOST_MISMATCH') 'entry point rejects foreign host before helper import'
    Assert (@(Get-ChildItem -LiteralPath $root -Recurse -File).Count -eq $before) 'read-only rejection creates no result or installation files'
    Write-Output ('Office local wrapper: '+$script:passed+' checks passed. No installation or services were run.')
}finally{
    $resolved=[IO.Path]::GetFullPath($root)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'cilex-office-wrapper-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
