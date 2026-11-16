[CmdletBinding()]
param([string]$PythonPath,[string]$MakensisPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$modulePath=Join-Path $PSScriptRoot '..\Build.psm1'
# Independent tests do not depend on a configured station or toolchain.
function global:Get-WtgSha256 { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
Import-Module $modulePath -Force -DisableNameChecking
$script:checks=0
function Assert-True { param([bool]$Value,[string]$Reason) if (-not $Value) { throw $Reason }; $script:checks++ }
function Assert-Refused { param([scriptblock]$Action,[string]$Reason) $refused=$false; try { & $Action | Out-Null } catch { $refused=$true }; Assert-True $refused $Reason }
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('wtg-build-tests-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($testRoot)
$utf8=New-Object Text.UTF8Encoding($false)
function Save-Manifest { param($Manifest,[string]$Path) [IO.File]::WriteAllText((Join-Path $Path 'manifest.json'),($Manifest | ConvertTo-Json -Depth 20),$utf8) }
function New-TestPackage {
    $package=Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
    $payload=Join-Path $package 'payload';$helpers=Join-Path $package 'helpers'
    $null=[IO.Directory]::CreateDirectory($payload);$null=[IO.Directory]::CreateDirectory($helpers)
    $files=@()
    foreach ($name in @('watchtower.exe','warden/warden.exe','warden/warden-launcher.exe','licenses/warden-launcher.cpp','platforms/qwindows.dll','multimedia/ffmpegmediaplugin.dll','ffmpeg.exe','prerequisites/vc_redist.x64.exe')) {
        $path=Join-Path $payload $name;$null=[IO.Directory]::CreateDirectory((Split-Path -Parent $path));[IO.File]::WriteAllText($path,$name,$utf8)
        $files+= [pscustomobject]@{path=$name;sha256=Get-WtgSha256 $path;size=(Get-Item -LiteralPath $path).Length}
    }
    $helper=Join-Path $helpers 'test.ps1';[IO.File]::WriteAllText($helper,'# fixture',$utf8)
    $launcher=[pscustomobject]@{version='1.0.0';sourcePath='packaging/windows/generic/warden-launcher.cpp';sourcePayloadPath='licenses/warden-launcher.cpp';sourceSha256=Get-WtgSha256 (Join-Path $payload 'licenses\warden-launcher.cpp');binaryPath='warden/warden-launcher.exe';binarySha256=Get-WtgSha256 (Join-Path $payload 'warden\warden-launcher.exe')}
    $manifest=[pscustomobject]@{schemaVersion=1;product='CilexWatchtower';architecture='x64';version='1.2.3';wardenVersion='1.4.10';sourceCommit=('a'*40);deploymentLauncher=$launcher;files=$files;helpers=@([pscustomobject]@{path='test.ps1';sha256=Get-WtgSha256 $helper;size=(Get-Item -LiteralPath $helper).Length})}
    Save-Manifest $manifest $package
    [pscustomobject]@{Path=$package;Manifest=$manifest}
}
try {
    foreach ($file in @($modulePath,(Join-Path $PSScriptRoot '..\installer-entry.ps1'))) {
        $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
        Assert-True ($errors.Count -eq 0) ('PowerShell syntax: '+$file)
    }
    $package=New-TestPackage
    $manifest=Test-WtgArtifact $package.Path
    Assert-True ($manifest.version -eq '1.2.3') 'Valid fixture package was refused.'
    $package=New-TestPackage;$package.Manifest.deploymentLauncher.sourceSha256=('0'*64);Save-Manifest $package.Manifest $package.Path
    Assert-Refused { Test-WtgArtifact $package.Path } 'Launcher source provenance mismatch accepted.'
    $package=New-TestPackage;$package.Manifest.deploymentLauncher.binarySha256=('0'*64);Save-Manifest $package.Manifest $package.Path
    Assert-Refused { Test-WtgArtifact $package.Path } 'Launcher binary provenance mismatch accepted.'
    foreach ($property in @('schemaVersion','product','architecture','sourceCommit','version','wardenVersion')) {
        $package=New-TestPackage;$package.Manifest.$property='invalid';Save-Manifest $package.Manifest $package.Path
        Assert-Refused { Test-WtgArtifact $package.Path } ('Invalid identity accepted: '+$property)
    }
    foreach ($unsafe in @('../escape','/absolute','C:/absolute','x/../escape','x\escape','x:stream')) {
        $package=New-TestPackage;$package.Manifest.files[0].path=$unsafe;Save-Manifest $package.Manifest $package.Path
        Assert-Refused { Test-WtgArtifact $package.Path } ('Unsafe path accepted: '+$unsafe)
    }
    $package=New-TestPackage;$package.Manifest.files+= $package.Manifest.files[0];Save-Manifest $package.Manifest $package.Path
    Assert-Refused { Test-WtgArtifact $package.Path } 'Duplicate file accepted.'
    $package=New-TestPackage;$package.Manifest.files[0].sha256=('0'*64);Save-Manifest $package.Manifest $package.Path
    Assert-Refused { Test-WtgArtifact $package.Path } 'Wrong hash accepted.'
    $package=New-TestPackage;$package.Manifest.files[0].size++;Save-Manifest $package.Manifest $package.Path
    Assert-Refused { Test-WtgArtifact $package.Path } 'Wrong size accepted.'
    $package=New-TestPackage;[IO.File]::WriteAllText((Join-Path $package.Path 'payload\unexpected.dll'),'extra',$utf8)
    Assert-Refused { Test-WtgArtifact $package.Path } 'Unlisted payload accepted.'
    $package=New-TestPackage;[IO.File]::WriteAllText((Join-Path $package.Path 'private.txt'),'extra',$utf8)
    Assert-Refused { Test-WtgArtifact $package.Path } 'Unlisted top-level content accepted.'
    $package=New-TestPackage;[IO.File]::WriteAllText((Join-Path $package.Path 'helpers\test.ps1'),'changed',$utf8)
    Assert-Refused { Test-WtgArtifact $package.Path } 'Modified helper accepted.'
    $source=Join-Path $testRoot 'source';$null=[IO.Directory]::CreateDirectory((Join-Path $source 'warden'))
    [IO.File]::WriteAllText((Join-Path $source 'CMakeLists.txt'),'project(Watchtower VERSION 1.2.3 LANGUAGES CXX)',$utf8)
    [IO.File]::WriteAllText((Join-Path $source 'warden\warden.py'),'WARDEN_VERSION = "1.4.10"',$utf8)
    $version=Get-WtgSourceVersion $source
    Assert-True ($version.Version -eq '1.2.3' -and $version.WardenVersion -eq '1.4.10') 'Source version parsing failed.'
    [IO.File]::WriteAllText((Join-Path $source 'CMakeLists.txt'),'project(Watchtower)',$utf8)
    Assert-Refused { Get-WtgSourceVersion $source } 'Missing source version accepted.'
    $vendor=Join-Path $testRoot 'vendor.cmd'
    [IO.File]::WriteAllText($vendor,('@set VCToolsInstallDir=C:\fixture'+[Environment]::NewLine),[Text.Encoding]::ASCII)
    $environmentContext=[pscustomobject]@{RunDir=$testRoot;Tools=@{Git=$env:ComSpec;CMake=$env:ComSpec;Ninja=$env:ComSpec;VsDevCmd=$vendor;Python=$env:ComSpec;PkgConfig=$env:ComSpec;QtRoot=$testRoot;GStreamerRoot=$testRoot}}
    $savedEnvironment=@{}
    try {
        foreach($name in @('GH_TEST_AUTH','GITHUB_TEST_AUTH','WTG_TEST_HEADER')) {
            $savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
            [Environment]::SetEnvironmentVariable($name,'synthetic fixture credential','Process')
        }
        $buildEnvironment=& (Get-Module Build) {param($ctx)Get-WtgBuildEnvironment $ctx} $environmentContext
        foreach($name in @('GH_TEST_AUTH','GITHUB_TEST_AUTH','WTG_TEST_HEADER')) {
            Assert-True (-not $buildEnvironment[$name]) ('Build environment retained a credential scope: '+$name)
        }
    } finally {
        foreach($name in $savedEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process')}
    }
    if ($PythonPath) {
        & $PythonPath -B (Join-Path $PSScriptRoot 'test-runtime-closure.py')
        Assert-True ($LASTEXITCODE -eq 0) 'Runtime dependency closure tests failed.'
    }
    Import-Module (Join-Path $PSScriptRoot '..\Common.psm1') -Force -DisableNameChecking
    $bootstrapContext=[pscustomobject]@{RunDir=$testRoot;OutputDir=(Join-Path $testRoot 'bootstrap-output');RunId='fixture'}
    $bootstrap=New-WtgBootstrapBundle $bootstrapContext
    $bootstrapRoot=Join-Path $testRoot 'bootstrap'
    Assert-True (Test-Path -LiteralPath $bootstrap.Path) 'Bootstrap archive missing.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $bootstrapRoot 'README.md') -Raw) -match '\]\(packaging/windows/generic/README\.md\)') 'Bootstrap entry guide has no usable usage link.'
    Assert-True (Test-Path -LiteralPath (Join-Path $bootstrapRoot 'packaging\windows\generic\README.md')) 'Detailed guide missing from standalone bootstrap.'
    Assert-True (Test-Path -LiteralPath (Join-Path $bootstrapRoot 'packaging\windows\generic\warden-launcher.cpp')) 'Native launcher source missing from bootstrap.'
    Assert-True (Test-Path -LiteralPath (Join-Path $bootstrapRoot 'packaging\windows\generic\tests\launcher-fixture.cpp')) 'Native launcher fixture missing from bootstrap.'
    Assert-True (Test-Path -LiteralPath (Join-Path $bootstrapRoot 'packaging\windows\BuildState.psm1')) 'Build reuse wrapper missing from bootstrap.'
    Assert-True (Test-Path -LiteralPath (Join-Path $bootstrapRoot 'packaging\build_state.py')) 'Committed-source/build reuse check missing from bootstrap.'
    $bootstrapManifest=Get-Content -LiteralPath (Join-Path $bootstrapRoot 'bootstrap-manifest.json') -Raw | ConvertFrom-Json
    foreach ($entry in $bootstrapManifest.files) {
        if ((Get-WtgSha256 (Join-Path $bootstrapRoot $entry.path)) -ne $entry.sha256) { throw 'Bootstrap content differs from its manifest.' }
    }
    $script:checks++
    if ($MakensisPath) {
        Import-Module (Join-Path $PSScriptRoot '..\Common.psm1') -Force -DisableNameChecking
        $package=New-TestPackage
        # Only non-executable payload fixtures are wrapped/extracted. This
        # regression never installs Watchtower, launches it or registers tasks.
        foreach ($name in @('Common.psm1','Install.psm1','install-target.ps1','installer-entry.ps1')) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('..\'+$name)) -Destination (Join-Path $package.Path 'helpers')
        }
        # Exercise the real NSIS/entry argument path against a recording helper.
        # It cannot install software or touch a Windows task.
        $recordingHelper=@'
[CmdletBinding()]
param([string]$PackagePath,[string]$ExpectedManifestSha256,[string]$InstallDir='',
 [string]$TargetUser,[string]$StartupMode,[string]$InstallScope,[string]$Language,
 [string]$ResultPath,[string]$BackendUrl,[string]$AutologonPath,
 [string[]]$OverrideRequirements=@(),[switch]$NonInteractive,[switch]$ConsentUnattended)
if ($OverrideRequirements -notcontains 'capacity.validation') { exit 23 }
$record=[ordered]@{InstallDir=$InstallDir;TargetUser=$TargetUser;StartupMode=$StartupMode;
 OverrideRequirements=$OverrideRequirements;NonInteractive=[bool]$NonInteractive;
 ConsentUnattended=[bool]$ConsentUnattended;AutologonPath=$AutologonPath}
[IO.File]::WriteAllText($ResultPath,($record|ConvertTo-Json -Depth 5))
exit 0
'@
        [IO.File]::WriteAllText((Join-Path $package.Path 'helpers\install-target.ps1'),$recordingHelper,$utf8)
        $package.Manifest.helpers=@(& (Get-Module Build) {param($p)Get-WtgPayloadFiles $p} (Join-Path $package.Path 'helpers'))
        Save-Manifest $package.Manifest $package.Path
        $context=[pscustomobject]@{RunDir=$testRoot;OutputDir=(Join-Path $testRoot 'installer');Tools=@{Makensis=$MakensisPath}}
        $installer=New-WtgInstaller $context $package.Path
        Assert-True (Test-Path -LiteralPath $installer.Path) 'Installer compiler produced no output.'
        $extract=Join-Path $testRoot 'extracted'
        $process=Start-Process -FilePath $installer.Path -ArgumentList @('/S',('/EXTRACTONLY="'+$extract+'"')) -WindowStyle Hidden -PassThru
        try {
            if (-not $process.WaitForExit(60000)) { throw 'Fixture extraction timed out.' }
            Assert-True ($process.ExitCode -eq 0) 'Installer extraction failed.'
        } finally { $process.Dispose() }
        $verified=Test-WtgArtifact $extract
        Assert-True ($verified.version -eq '1.2.3') 'Extracted package did not retain its identity and hashes.'
        # Repeating extraction must never overwrite even a test-owned directory.
        $process=Start-Process -FilePath $installer.Path -ArgumentList @('/S',('/EXTRACTONLY="'+$extract+'"')) -WindowStyle Hidden -PassThru
        try {
            if (-not $process.WaitForExit(60000)) { throw 'Repeat fixture extraction timed out.' }
            Assert-True ($process.ExitCode -ne 0) 'Existing extraction directory was overwritten.'
        } finally { $process.Dispose() }
        $null=Test-WtgArtifact $extract
        $script:checks++
        $recordPath=Join-Path $testRoot 'entry-forwarded.json'
        $baseArguments=@('/S','/STARTUPMODE=UnattendedReboot','/LANGUAGE=en','/TARGETUSER=WTG-FIXTURE\OTHER',('/RESULT="'+$recordPath+'"'))
        $process=Start-Process -FilePath $installer.Path -ArgumentList ($baseArguments+@('/OVERRIDEREQUIREMENTS=capacity.validation,graphics.adapter','/CONSENTUNATTENDED','/AUTOLOGONPATH=C:\fixture\Autologon.exe')) -WindowStyle Hidden -PassThru
        try {
            if (-not $process.WaitForExit(60000)) { throw 'Fixture entry forwarding timed out.' }
            Assert-True ($process.ExitCode -eq 0) 'Explicit warning consent was not forwarded.'
        } finally { $process.Dispose() }
        $record=Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-True ($record.OverrideRequirements.Count -eq 2 -and $record.OverrideRequirements -contains 'capacity.validation' -and $record.OverrideRequirements -contains 'graphics.adapter') 'Finding IDs were not preserved.'
        Assert-True ($record.NonInteractive -and $record.ConsentUnattended -and $record.AutologonPath -eq 'C:\fixture\Autologon.exe') 'Startup choices were not preserved.'
        Assert-True ($record.InstallDir -eq '' -and $record.TargetUser -eq 'WTG-FIXTURE\OTHER') 'Another target user received the launching user default directory.'
        $explicit=Join-Path $testRoot 'explicit destination'
        $process=Start-Process -FilePath $installer.Path -ArgumentList ($baseArguments+@('/OVERRIDEREQUIREMENTS=capacity.validation',('/D='+$explicit))) -WindowStyle Hidden -PassThru
        try {
            if (-not $process.WaitForExit(60000)) { throw 'Explicit directory forwarding timed out.' }
            Assert-True ($process.ExitCode -eq 0) 'Explicit destination was refused.'
        } finally { $process.Dispose() }
        $record=Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-True ($record.InstallDir -eq $explicit) 'Explicit /D directory was not retained for another target user.'
        Assert-True (-not $record.ConsentUnattended) 'Unattended consent was invented.'
        $process=Start-Process -FilePath $installer.Path -ArgumentList $baseArguments -WindowStyle Hidden -PassThru
        try {
            if (-not $process.WaitForExit(60000)) { throw 'Default refusal fixture timed out.' }
            Assert-True ($process.ExitCode -eq 23) 'Missing warning consent did not preserve target refusal.'
        } finally { $process.Dispose() }
        $process=Start-Process -FilePath $installer.Path -ArgumentList ($baseArguments+@('/OVERRIDEREQUIREMENTS=*')) -WindowStyle Hidden -PassThru
        try {
            if (-not $process.WaitForExit(60000)) { throw 'Invalid finding fixture timed out.' }
            Assert-True ($process.ExitCode -eq 1) 'Wildcard finding override was accepted.'
        } finally { $process.Dispose() }
    }
    Write-Output ('Build/package checks passed: '+$script:checks)
} finally {
    # Retain fixtures for inspection; never recursively remove an inferred path.
    Remove-Module Build -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Get-WtgSha256 -ErrorAction SilentlyContinue
}
