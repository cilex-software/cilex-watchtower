#requires -Version 5.1
param([string]$WorkRoot=(Join-Path $env:TEMP ('cilex-entry-test-'+[Guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Common.psm1') -Force
$entry=Join-Path $root '..\deploy-watchtower.ps1'
$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$passed=0
function Assert([string]$Name,[bool]$Condition){if(-not $Condition){throw ('FAIL: '+$Name)};$script:passed++}
$unused=Join-Path $WorkRoot 'unused directories'
$common=@('-NoProfile','-NonInteractive','-File',$entry,'-WorkDir',(Join-Path $unused 'work'),'-CacheDir',(Join-Path $unused 'cache'),'-OutputDir',(Join-Path $unused 'output'))
$p=Invoke-WtgProcess $ps ($common+@('-Mode','RemoteInstall','-WhatIf','-Language','en'))
Assert 'preview does not need remote credentials' ($p.ExitCode -eq 0 -and $p.StdOut -match 'Preview only')
Assert 'preview creates no files' (-not (Test-Path -LiteralPath $WorkRoot))
foreach($mode in @('Build','BuildInstaller','Check')){
    $p=Invoke-WtgProcess $ps ($common+@('-Mode',$mode,'-VerifyOnly','-Language','en')) -AllowedExitCodes @(1)
    Assert ('verification cannot claim '+$mode) ($p.StdOut -match 'cannot be combined')
}
$p=Invoke-WtgProcess $ps ($common+@('-Mode','Build','-PackagePath','missing.exe','-Language','en')) -AllowedExitCodes @(1)
Assert 'package/build conflict refused' ($p.StdOut -match 'cannot be combined')
$p=Invoke-WtgProcess $ps ($common+@('-Mode','RemoteInstall','-NonInteractive','-Language','en')) -AllowedExitCodes @(1)
Assert 'remote identity required before changes' ($p.StdOut -match 'TargetHost, TargetUser')
$p=Invoke-WtgProcess $ps ($common+@('-Mode','Check','-BackendUrl','https://user:disposable@invalid.test','-Language','en')) -AllowedExitCodes @(1)
Assert 'credential-bearing backend refused and not printed' ($p.StdOut -match 'without a password' -and $p.StdOut -notmatch 'disposable')
$p=Invoke-WtgProcess $ps ($common+@('-Mode','Build','-SourceDirectory','unused','-SourceBundle','unused.bundle','-Language','en')) -AllowedExitCodes @(1)
Assert 'conflicting sources rejected before tool provisioning' ($p.StdOut -match 'cannot be combined')
Assert 'all invalid invocations create no files' (-not (Test-Path -LiteralPath $WorkRoot))
$p=Invoke-WtgProcess $ps ($common+@('-Mode','Check','-DependencyMode','Offline','-Json','-Language','en')) -AllowedExitCodes @(0,2,10)
$result=$p.StdOut|ConvertFrom-Json
Assert 'check returns actual assessment' ($result.Status -eq 'Checked' -and @($result.Checks).Count -gt 5)
Assert 'check creates no files' (-not (Test-Path -LiteralPath $WorkRoot))
Assert 'unknown capacity is not pass' (@($result.Checks|Where-Object {$_.Id -eq 'capacity.validation' -and $_.State -eq 'UNKNOWN'}).Count -eq 1)
$findings=@(
 [pscustomobject]@{Id='capacity';State='PASS';CanOverride=$false},
 [pscustomobject]@{Id='capacity';State='WARNING';CanOverride=$true},
 [pscustomobject]@{Id='access';State='BLOCKED';CanOverride=$true},
 [pscustomobject]@{Id='access';State='BLOCKED';CanOverride=$false}
)
$merged=@(Merge-WtgFindings $findings)
Assert 'combined roles retain warning' (($merged|Where-Object Id -eq 'capacity').State -eq 'WARNING')
Assert 'combined roles retain non-overridable failure' (-not ($merged|Where-Object Id -eq 'access').CanOverride)
Assert 'explicit English language' ((Get-WtgLanguage en) -eq 'en')
Assert 'explicit Russian language' ((Get-WtgLanguage ru) -eq 'ru')
Assert 'Russian state label translated' ((Get-WtgMessage StateBLOCKED -Language ru) -ne 'BLOCKED')
$p=Invoke-WtgProcess $ps ($common+@('-Mode','Build','-VerifyOnly','-Language','ru')) -AllowedExitCodes @(1) -OutputEncoding utf-8
Assert 'Russian error survives native Windows PowerShell capture' ($p.StdOut.Contains((Get-WtgMessage InputConflict @('VerifyOnly / Build') ru)))
$fixture=Join-Path $WorkRoot 'cleanup fixture'
$fixtureModules=Join-Path $fixture 'generic'
[IO.Directory]::CreateDirectory($fixtureModules)|Out-Null
Copy-Item -LiteralPath $entry -Destination (Join-Path $fixture 'deploy-watchtower.ps1')
Copy-Item -LiteralPath (Join-Path $root 'Common.psm1') -Destination $fixtureModules
foreach($name in @('Requirements.psm1','Install.psm1')){[IO.File]::WriteAllText((Join-Path $fixtureModules $name),'# No live operations in this fixture.')}
$remoteStub=@'
function Install-WtgRemotePackage {
    $failure=New-Object InvalidOperationException 'REMOTE_SERVICE_CLEANUP_UNCONFIRMED'
    $failure.Data['ServiceName']='cilex-deploy-test-helper'
    $failure.Data['RunId']='fixture-cleanup'
    $failure.Data['NativeError']=5
    $failure.Data['ResultPath']='C:\safe\retained-result.json'
    throw $failure
}
Export-ModuleMember -Function Install-WtgRemotePackage
'@
[IO.File]::WriteAllText((Join-Path $fixtureModules 'Remote.psm1'),$remoteStub)
$cleanupWork=Join-Path $fixture 'work'
$p=Invoke-WtgProcess $ps @('-NoProfile','-NonInteractive','-File',(Join-Path $fixture 'deploy-watchtower.ps1'),'-Mode','RemoteInstall','-VerifyOnly','-NonInteractive','-Language','en','-TargetHost','fixture.invalid','-TargetUser','FixtureUser','-WorkDir',$cleanupWork,'-CacheDir',(Join-Path $fixture 'cache'),'-OutputDir',(Join-Path $fixture 'output')) -AllowedExitCodes @(1)
$saved=Get-ChildItem -LiteralPath $cleanupWork -Filter result.json -Recurse|Select-Object -First 1
$cleanup=Get-Content -LiteralPath $saved.FullName -Raw|ConvertFrom-Json
Assert 'cleanup failure does not claim installation failure or success' ($p.StdOut -match 'Installation may have completed' -and $cleanup.Error -eq 'REMOTE_SERVICE_CLEANUP_UNCONFIRMED')
Assert 'cleanup failure retains exact helper and result location' ($cleanup.Recovery.ServiceName -eq 'cilex-deploy-test-helper' -and $cleanup.Recovery.ResultPath -eq 'C:\safe\retained-result.json')
Assert 'cleanup failure asks for review before retry' ($p.StdOut -match 'before retrying')
$p=Invoke-WtgProcess $ps @('-NoProfile','-NonInteractive','-File',(Join-Path $fixture 'deploy-watchtower.ps1'),'-Mode','RemoteInstall','-VerifyOnly','-ResumeRunId','fixture-verification','-NonInteractive','-Language','en','-TargetHost','fixture.invalid','-TargetUser','FixtureUser','-WorkDir',(Join-Path $fixture 'resume-work'),'-CacheDir',(Join-Path $fixture 'cache'),'-OutputDir',(Join-Path $fixture 'output')) -AllowedExitCodes @(1)
Assert 'verification resumption reaches protected remote reconciliation' ($p.StdOut -match 'Installation may have completed' -and $p.StdOut -notmatch 'cannot be combined')
$p=Invoke-WtgProcess $ps ($common+@('-Mode','Install','-VerifyOnly','-ResumeRunId','fixture-verification','-Language','en')) -AllowedExitCodes @(1)
Assert 'resumption remains remote only' ($p.StdOut -match 'cannot be combined')
$requirementStub=@'
function Get-WtgRequirements { return @() }
Export-ModuleMember -Function Get-WtgRequirements
'@
$dependencyStub=@'
function Initialize-WtgDependencies {
    param($Context)
    $message=if($Context.Language -eq 'ru'){'Нужна перезагрузка Windows.'}else{'A build prerequisite requires a Windows restart.'}
    $failure=New-Object InvalidOperationException $message
    $failure.Data['WtgRestartRequired']=$true
    throw $failure
}
Export-ModuleMember -Function Initialize-WtgDependencies
'@
[IO.File]::WriteAllText((Join-Path $fixtureModules 'Requirements.psm1'),$requirementStub,(New-Object Text.UTF8Encoding $true))
[IO.File]::WriteAllText((Join-Path $fixtureModules 'Dependencies.psm1'),$dependencyStub,(New-Object Text.UTF8Encoding $true))
foreach($testLanguage in @('en','ru')){
    $restartWork=Join-Path $fixture ('restart-'+$testLanguage)
    $p=Invoke-WtgProcess $ps @('-NoProfile','-NonInteractive','-File',(Join-Path $fixture 'deploy-watchtower.ps1'),'-Mode','Build','-NonInteractive','-AcceptPlan','-AcceptLicenses','-Language',$testLanguage,'-WorkDir',$restartWork,'-CacheDir',(Join-Path $fixture 'cache'),'-OutputDir',(Join-Path $fixture 'output')) -AllowedExitCodes @(3010) -OutputEncoding utf-8
    $saved=Get-ChildItem -LiteralPath $restartWork -Filter result.json -Recurse|Select-Object -First 1
    $restart=Get-Content -LiteralPath $saved.FullName -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($testLanguage+' dependency reboot returns exit 3010') ($p.ExitCode -eq 3010 -and $restart.ExitCode -eq 3010)
    Assert ($testLanguage+' dependency reboot is not installation failure') ($restart.Status -eq 'RestartRequired' -and $null -eq $restart.Source -and $null -eq $restart.Build -and $null -eq $restart.Installation)
    Assert ($testLanguage+' dependency reboot prints necessary next action') ($p.StdOut -match $(if($testLanguage -eq 'ru'){'перезагрузка Windows'}else{'requires a Windows restart'}) -and $p.StdOut -notmatch 'operation did not complete|Операция не завершена')
}
Write-Output ('PASS '+$passed+' entry checks; Check/preview created no files.')
