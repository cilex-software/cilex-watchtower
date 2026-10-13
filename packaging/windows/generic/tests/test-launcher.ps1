#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$VsDevCmdPath,
    [string]$LauncherPath,
    [string]$ResultPath
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\Build.psm1') -DisableNameChecking
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('wtg-launcher-tests-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($testRoot)
$context=[pscustomobject]@{RunDir=$testRoot;Tools=@{Git=$env:ComSpec;CMake=$env:ComSpec;Ninja=$env:ComSpec;VsDevCmd=$VsDevCmdPath;Python=$env:ComSpec;PkgConfig=$env:ComSpec;QtRoot=$testRoot;GStreamerRoot=$testRoot}}
$environment=& (Get-Module Build) {param($ctx) Get-WtgBuildEnvironment $ctx} $context
$compiler=Join-Path $environment.VCToolsInstallDir 'bin\Hostx64\x64\cl.exe'
function Compile-Fixture([string]$Source,[string]$Output) {
    $null=Invoke-WtgProcess -FilePath $compiler -Arguments @('/nologo','/std:c++17','/W4','/WX','/O2','/MT','/EHsc','/utf-8','/DUNICODE','/D_UNICODE',$Source,('/Fe:'+$Output),('/Fo:'+($Output+'.obj')),'/link','/SUBSYSTEM:WINDOWS','/DYNAMICBASE','/NXCOMPAT','shell32.lib') -WorkingDirectory $testRoot -Environment $environment -TimeoutSeconds 120 -LogPath ($Output+'.build.log')
}
if(-not $LauncherPath){$LauncherPath=Join-Path $testRoot 'warden-launcher.exe';Compile-Fixture (Join-Path $PSScriptRoot '..\warden-launcher.cpp') $LauncherPath}
if(-not(Test-Path -LiteralPath $LauncherPath -PathType Leaf)){throw 'Launcher under test is missing.'}
$fixture=Join-Path $testRoot 'fixture.exe';Compile-Fixture (Join-Path $PSScriptRoot 'launcher-fixture.cpp') $fixture
$script:checks=0;$cases=New-Object Collections.Generic.List[object]
function Assert-Launcher([bool]$Good,[string]$Reason){if(-not $Good){throw $Reason};$script:checks++}
function Read-FixtureRecord([string]$Path,$Launcher){
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        if(Test-Path -LiteralPath $Path){
            $data=@{};foreach($line in Get-Content -LiteralPath $Path -Encoding Unicode){if($line -match '^([^=]+)=(.*)$'){$data[$matches[1]]=$matches[2]}}
            if($data.ContainsKey('pid') -and $data.ContainsKey('created') -and $data.ContainsKey('session') -and $data.ContainsKey('cwd')){return $data}
        }
        if($Launcher.HasExited){throw ('Disposable launcher exited before readiness: '+$Launcher.ExitCode)}
        Start-Sleep -Milliseconds 50
    }while($timer.Elapsed.TotalSeconds -lt 30)
    throw 'Disposable child did not report readiness within30seconds.'
}
function Open-FixtureProcess($Record,[string]$ExpectedPath){
    $p=Get-Process -Id ([int]$Record.pid) -ErrorAction Stop;$null=$p.Handle
    if($p.MainModule.FileName -ne $ExpectedPath -or $p.StartTime.ToUniversalTime().ToFileTimeUtc() -ne [long]$Record.created -or $p.SessionId -ne [int]$Record.session){$p.Dispose();throw 'Disposable process identity differs.'}
    return $p
}
foreach($mode in @('normal-exit','zero-exit','kill-supervisor','kill-launcher','missing-warden','invalid-arguments')){
    $case=Join-Path $testRoot $mode;$bin=Join-Path $case 'warden';$state=Join-Path $case 'state'
    $null=[IO.Directory]::CreateDirectory($bin);$null=[IO.Directory]::CreateDirectory($state)
    $launcher=Join-Path $bin 'warden-launcher.exe';Copy-Item -LiteralPath $LauncherPath -Destination $launcher
    if($mode -ne 'missing-warden') {Copy-Item -LiteralPath $fixture -Destination (Join-Path $bin 'warden.exe');Copy-Item -LiteralPath $fixture -Destination (Join-Path $bin 'fixture-leaf.exe')}
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$launcher;$psi.Arguments=if($mode -eq 'invalid-arguments'){'status'}else{'run'}
    $psi.WorkingDirectory=$testRoot;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.EnvironmentVariables['WTG_LAUNCHER_FIXTURE_ROOT']=$state;$psi.EnvironmentVariables['WTG_LAUNCHER_FIXTURE_MODE']=$mode
    $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;$supervisor=$null;$leaf=$null
    try {
        Assert-Launcher ($p.Start()) ('Launcher did not start: '+$mode);$null=$p.Handle
        if($mode -in @('missing-warden','invalid-arguments')) {
            Assert-Launcher ($p.WaitForExit(10000)) ('Invalid launch did not finish: '+$mode)
            Assert-Launcher ($p.ExitCode -ne 0) ('Invalid launch reported success: '+$mode)
            Assert-Launcher (@(Get-ChildItem -LiteralPath $state -File).Count -eq 0) ('Invalid arguments launched a child: '+$mode)
        } else {
            $wardenRecord=Read-FixtureRecord (Join-Path $state 'warden.txt') $p;$leafRecord=Read-FixtureRecord (Join-Path $state 'leaf.txt') $p
            $supervisor=Open-FixtureProcess $wardenRecord (Join-Path $bin 'warden.exe');$leaf=Open-FixtureProcess $leafRecord (Join-Path $bin 'fixture-leaf.exe')
            Assert-Launcher ($wardenRecord.cwd -eq $case) 'Launcher did not set installation-root working directory.'
            Assert-Launcher (-not $leaf.HasExited) 'Harmless child was not alive before test.'
            if($mode -in @('normal-exit','zero-exit')){[IO.File]::WriteAllText((Join-Path $state 'continue.txt'),'ready')}
            if($mode -eq 'kill-supervisor'){$supervisor.Kill()}
            elseif($mode -eq 'kill-launcher'){$p.Kill()}
            Assert-Launcher ($p.WaitForExit(10000)) ('Launcher did not finish: '+$mode)
            Assert-Launcher ($supervisor.WaitForExit(10000)) ('Supervisor outlived launcher: '+$mode)
            Assert-Launcher ($leaf.WaitForExit(10000)) ('Orphan child survived: '+$mode)
            if($mode -eq 'normal-exit'){Assert-Launcher ($p.ExitCode -eq 37) 'Launcher did not propagate supervisor exit code.'}
            if($mode -eq 'zero-exit'){Assert-Launcher ($p.ExitCode -eq 0) 'Launcher did not propagate clean supervisor exit.'}
        }
        $cases.Add([pscustomobject]@{Mode=$mode;Passed=$true;LauncherExit=$p.ExitCode})
    } catch {
        $why=$_.Exception.Message
        $exited=$p.HasExited;$exitCode=if($exited){$p.ExitCode}else{$null}
        $failure=[pscustomobject]@{Mode=$mode;Message=$why;LauncherPID=$p.Id;LauncherExited=$exited;LauncherExitCode=$exitCode;LauncherSHA256=Get-WtgSha256 $launcher;FixtureRoot=$testRoot;Records=@(Get-ChildItem -LiteralPath $state -File|Select-Object Name,Length)}
        Write-WtgJson -Path (Join-Path $testRoot 'failure.json') -Value $failure
        throw ('Native fixture '+$mode+' failed: '+$why+'; launcher exit='+$exitCode+'; evidence='+$testRoot)
    } finally {
        foreach($owned in @($p,$supervisor,$leaf)) {if($owned){try{if(-not $owned.HasExited){$owned.Kill();$null=$owned.WaitForExit(5000)}}finally{$owned.Dispose()}}}
    }
}
$result=[pscustomobject]@{Passed=$true;Checks=$script:checks;LauncherSHA256=Get-WtgSha256 $LauncherPath;Cases=$cases.ToArray();FixtureRoot=$testRoot;ApplicationStarted=$false;ScheduledTasksChanged=$false}
if($ResultPath){Write-WtgJson -Path $ResultPath -Value $result}
Write-Output ('Launcher checks passed: '+$script:checks+'. No station application or task was used.')
