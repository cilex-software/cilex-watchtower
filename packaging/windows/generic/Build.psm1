# Windows PowerShell 5.1-compatible generic build and packaging. No live install reads.
Set-StrictMode -Version Latest
$script:WtgBuildRoot = $PSScriptRoot

function Stop-WtgBuild {
    param($Context, [string]$English, [string]$Russian)
    if ($Context.Language -eq 'ru') { throw $Russian }
    throw $English
}

function Assert-WtgBuildPath {
    param([string]$Path, [switch]$Container)
    $kind = if ($Container) { 'Container' } else { 'Leaf' }
    if (-not [IO.Path]::IsPathRooted($Path) -or -not (Test-Path -LiteralPath $Path -PathType $kind)) {
        throw "Required build input is missing: $Path"
    }
    $ancestor = [IO.Path]::GetFullPath($Path)
    while ($ancestor) {
        $item = Get-Item -LiteralPath $ancestor -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked build input is not allowed.' }
        $next = Split-Path -Parent $ancestor
        if ($next -eq $ancestor) { break }; $ancestor=$next
    }
}

function Copy-WtgBuildFile {
    param([string]$Source, [string]$Destination)
    Assert-WtgBuildPath $Source
    if (Test-Path -LiteralPath $Destination) {
        if ((Get-WtgSha256 $Source) -ne (Get-WtgSha256 $Destination)) { throw 'Conflicting runtime files have the same destination.' }
        return
    }
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Destination))
    [IO.File]::Copy($Source, $Destination, $false)
    if ((Get-WtgSha256 $Source) -ne (Get-WtgSha256 $Destination)) { throw 'Runtime copy verification failed.' }
}

function Copy-WtgBuildTree {
    param([string]$Source, [string]$Destination)
    Assert-WtgBuildPath $Source -Container
    $root = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    foreach ($item in Get-ChildItem -LiteralPath $root -Force -Recurse) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked runtime paths are not allowed.' }
        if (-not $item.PSIsContainer) {
            Copy-WtgBuildFile $item.FullName (Join-Path $Destination $item.FullName.Substring($root.Length + 1))
        }
    }
}

function Get-WtgSourceVersion {
    param([string]$Path)
    $cmake = Get-Content -LiteralPath (Join-Path $Path 'CMakeLists.txt') -Raw -Encoding UTF8
    $warden = Get-Content -LiteralPath (Join-Path $Path 'warden\warden.py') -Raw -Encoding UTF8
    $appVersion = [regex]::Match($cmake, 'project\s*\([^)]*?VERSION\s+(\d+\.\d+\.\d+)', 'Singleline').Groups[1].Value
    $wardenVersion = [regex]::Match($warden, '(?m)^WARDEN_VERSION\s*=\s*"(\d+\.\d+\.\d+)"').Groups[1].Value
    if (-not $appVersion -or -not $wardenVersion) { throw 'The selected source has no supported product version.' }
    [pscustomobject]@{ Version = $appVersion; WardenVersion = $wardenVersion }
}

function Get-WtgBuildEnvironment {
    param($Context)
    $tools = $Context.Tools
    foreach ($key in @('Git','CMake','Ninja','VsDevCmd','Python','PkgConfig')) { Assert-WtgBuildPath ([string]$tools[$key]) }
    foreach ($key in @('QtRoot','GStreamerRoot')) { Assert-WtgBuildPath ([string]$tools[$key]) -Container }
    # cmd is used only for the vendor environment batch file. Never interpolate credentials.
    $batch = [string]$tools.VsDevCmd
    if ($batch -match '[%"&|<>^!\r\n]') { throw 'Unsupported characters in the compiler setup path.' }
    $extra = if ([IO.Path]::GetFileName($batch) -ieq 'VsDevCmd.bat') { ' -arch=x64 -host_arch=x64' } else { '' }
    # cmd.exe has different quoting rules from CRT executables. Construct its
    # one trusted command explicitly and keep `set` output out of diagnostics.
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$env:ComSpec;$psi.Arguments='/d /s /c ""'+$batch+'"'+$extra+' >nul 2>&1 && set"'
    $psi.WorkingDirectory=$Context.RunDir;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach ($name in @($psi.EnvironmentVariables.Keys)) {
        if ($name -match '(?i)TOKEN|PASSWORD|SECRET|CREDENTIAL|AUTHORIZATION|BEARER|API.?KEY|^WT_|^WTG_|^CV_|^GH_|^GITHUB_|^GIT_|^QT_|^QML_|^GST_') { $psi.EnvironmentVariables.Remove($name) }
    }
    $process=New-Object Diagnostics.Process;$process.StartInfo=$psi
    try {
        $null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill();throw 'Compiler environment preparation timed out.' }
        if (-not $stdout.Wait(5000) -or -not $stderr.Wait(5000) -or $process.ExitCode -ne 0) { throw 'Compiler environment preparation failed.' }
        $vendorEnvironment=$stdout.Result
    } finally { $process.Dispose() }
    $buildEnv = @{}
    foreach ($line in ($vendorEnvironment -split '\r?\n')) {
        if ($line -match '^([^=]+)=(.*)$') { $buildEnv[$matches[1]] = $matches[2] }
    }
    if (-not $buildEnv.ContainsKey('VCToolsInstallDir')) { throw 'Compiler environment preparation did not succeed.' }
    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys)+@($buildEnv.Keys)) {
        if ($name -match '(?i)TOKEN|PASSWORD|SECRET|CREDENTIAL|AUTHORIZATION|BEARER|API.?KEY|^WT_|^WTG_|^CV_|^GH_|^GITHUB_|^GIT_|^QT_|^QML_|^GST_') { $buildEnv[$name]=$null }
    }
    $buildEnv['PATH'] = @((Join-Path $tools.QtRoot 'bin'), (Split-Path $tools.CMake), (Split-Path $tools.Ninja), (Split-Path $tools.Python), (Split-Path $tools.Git), $buildEnv['PATH']) -join ';'
    $buildEnv['QT_ROOT_DIR'] = $tools.QtRoot
    $buildEnv['GSTREAMER_ROOT'] = $tools.GStreamerRoot
    $buildEnv['PKG_CONFIG_PATH'] = Join-Path $tools.GStreamerRoot 'lib\pkgconfig'
    $buildEnv['PYTHONUTF8'] = '1'
    $buildEnv['PYTHONIOENCODING'] = 'utf-8'
    $buildEnv['PYTHONDONTWRITEBYTECODE'] = '1'
    return $buildEnv
}

function Invoke-WtgBuildStep {
    param($Context,[string]$Name,[string]$Exe,[string[]]$Arguments,[string]$Directory,[hashtable]$Environment,[int]$Seconds = 3600)
    $result = Invoke-WtgProcess -FilePath $Exe -Arguments $Arguments -WorkingDirectory $Directory -Environment $Environment -TimeoutSeconds $Seconds -LogPath (Join-Path $Context.RunDir ($Name+'.log'))
    return $result
}

function Copy-WtgPackagedRuntimeLicenses {
    param($Context,[string]$Payload,[hashtable]$Environment)
    $pythonCode='import importlib.metadata as m,json,pathlib,sys; d=m.distribution("pyinstaller"); print(json.dumps({"python":str(pathlib.Path(sys.base_prefix)/"LICENSE.txt"),"pyinstaller":[str(d.locate_file(p)) for p in d.files if p.name.lower() in ("copying.txt","license.txt","license") and "dist-info" in str(p)]}))'
    $record=Invoke-WtgBuildStep $Context 'runtime-licenses' $Context.Tools.Python @('-I','-c',$pythonCode) $Context.RunDir $Environment 30
    $paths=$record.StdOut|ConvertFrom-Json
    Copy-WtgBuildFile $paths.python (Join-Path $Payload 'licenses\Python-LICENSE.txt')
    if (@($paths.pyinstaller).Count -ne 1) { throw 'The exact PyInstaller redistribution license could not be identified.' }
    Copy-WtgBuildFile $paths.pyinstaller[0] (Join-Path $Payload 'licenses\PyInstaller-COPYING.txt')
    $ffmpegRoot=Split-Path -Parent (Split-Path -Parent $Context.Tools.FFmpeg)
    Copy-WtgBuildFile (Join-Path $ffmpegRoot 'LICENSE.txt') (Join-Path $Payload 'licenses\FFmpeg-vendor-LICENSE.txt')
}

function Get-WtgBuildVersions {
    param($Context,[hashtable]$Environment)
    $tools=$Context.Tools
    $versions=[ordered]@{}
    foreach ($entry in @(@('Qt',(Join-Path $tools.QtRoot 'bin\qmake.exe'),'-query','QT_VERSION'),@('CMake',$tools.CMake,'--version'),@('Ninja',$tools.Ninja,'--version'),@('Python',$tools.Python,'--version'),@('PyInstaller',$tools.Python,'-I','-m','PyInstaller','--version'),@('FFmpeg',$tools.FFmpeg,'-version'))) {
        $v=Invoke-WtgBuildStep $Context ('version-'+$entry[0]) $entry[1] $entry[2..($entry.Count-1)] $Context.RunDir $Environment 30
        $versions[$entry[0]]=($v.StdOut -split '\r?\n')[0]
        if (-not $versions[$entry[0]]) { throw ('Dependency version is unavailable: '+$entry[0]) }
    }
    # Official GStreamer DLLs do not necessarily have Windows version resources.
    $pc=Join-Path $tools.GStreamerRoot 'lib\pkgconfig\gstreamer-1.0.pc'
    Assert-WtgBuildPath $pc
    $versions['GStreamer']=[regex]::Match([IO.File]::ReadAllText($pc),'(?m)^Version:\s*(\d+\.\d+\.\d+)\s*$').Groups[1].Value
    $versions['MSVCTools']=[string]$Environment['VCToolsVersion']
    $versions['WindowsSDK']=([string]$Environment['WindowsSDKVersion']).TrimEnd('\')
    $versions['VCRedist']=(Get-Item -LiteralPath $tools.VCRedist).VersionInfo.FileVersion
    foreach ($name in @('GStreamer','MSVCTools','WindowsSDK','VCRedist')) {
        if (-not $versions[$name]) { throw ('Dependency version is unavailable: '+$name) }
    }
    return $versions
}

function Get-WtgPayloadFiles {
    param([string]$Root)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    Assert-WtgBuildPath $rootPath -Container
    $all = @(Get-ChildItem -LiteralPath $rootPath -Force -Recurse)
    if (@($all | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count) { throw 'Package links are not allowed.' }
    $items = @($all | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName)
    foreach ($file in $items) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Package links are not allowed.' }
        [pscustomobject]@{ path = $file.FullName.Substring($rootPath.Length + 1).Replace('\','/'); sha256 = Get-WtgSha256 $file.FullName; size = $file.Length }
    }
}

function Build-WtgLauncher {
    param($Context,[string]$Payload,[hashtable]$Environment)
    $source=Join-Path $script:WtgBuildRoot 'warden-launcher.cpp'
    $sourceText=Get-Content -LiteralPath $source -Raw -Encoding UTF8
    $version=[regex]::Match($sourceText,'(?m)^#define WTG_LAUNCHER_VERSION "(\d+\.\d+\.\d+)"').Groups[1].Value
    if(-not $version){throw 'Deployment launcher source version is missing.'}
    $binary=Join-Path $Payload 'warden\warden-launcher.exe'
    $null=[IO.Directory]::CreateDirectory((Split-Path -Parent $binary))
    $compiler=Join-Path $Environment.VCToolsInstallDir 'bin\Hostx64\x64\cl.exe'
    Assert-WtgBuildPath $compiler
    $null=Invoke-WtgBuildStep $Context 'build-launcher' $compiler @('/nologo','/std:c++17','/W4','/WX','/O2','/MT','/EHsc','/utf-8','/guard:cf','/DUNICODE','/D_UNICODE',$source,('/Fe:'+$binary),('/Fo:'+(Join-Path $Context.RunDir 'warden-launcher.obj')),'/link','/SUBSYSTEM:WINDOWS','/DYNAMICBASE','/NXCOMPAT','/HIGHENTROPYVA','/guard:cf','shell32.lib') $Context.RunDir $Environment 120
    $testResult=Join-Path $Context.RunDir 'launcher-tests.json'
    $null=Invoke-WtgBuildStep $Context 'launcher-tests' (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile','-NonInteractive','-File',(Join-Path $script:WtgBuildRoot 'tests\test-launcher.ps1'),'-LauncherPath',$binary,'-VsDevCmdPath',$Context.Tools.VsDevCmd,'-ResultPath',$testResult) $Context.RunDir $Environment 180
    $tested=Get-Content -LiteralPath $testResult -Raw -Encoding UTF8|ConvertFrom-Json
    if(-not $tested.Passed -or $tested.LauncherSHA256 -ne (Get-WtgSha256 $binary)){throw 'Deployment launcher lifecycle verification failed.'}
    Copy-WtgBuildFile $source (Join-Path $Payload 'licenses\warden-launcher.cpp')
    return [pscustomobject]@{version=$version;sourcePath='packaging/windows/generic/warden-launcher.cpp';sourceSha256=Get-WtgSha256 $source;sourcePayloadPath='licenses/warden-launcher.cpp';binaryPath='warden/warden-launcher.exe';binarySha256=Get-WtgSha256 $binary;lifecycleChecks=$tested.Checks}
}

function Test-WtgArtifact {
    param([Parameter(Mandatory=$true)][string]$PackagePath)
    $manifestPath = Join-Path $PackagePath 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.product -ne 'CilexWatchtower' -or $manifest.architecture -ne 'x64' -or $manifest.sourceCommit -notmatch '^[0-9a-fA-F]{40}$') { throw 'Invalid package identity.' }
    if ($manifest.version -notmatch '^\d+\.\d+\.\d+$' -or $manifest.wardenVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid package version.' }
    foreach ($set in @(@('files','payload'),@('helpers','helpers'))) {
        $root = Join-Path $PackagePath $set[1]
        $seen = @{}
        foreach ($file in @($manifest.($set[0]))) {
            $relative = [string]$file.path
            if (-not $relative -or $relative -match '(^[\\/]|[:\\]|(^|/)\.\.?(/|$)|[\x00-\x1f])' -or $seen.ContainsKey($relative.ToLowerInvariant())) { throw 'Unsafe or duplicate package path.' }
            $seen[$relative.ToLowerInvariant()] = $true
            $path = Join-Path $root $relative
            Assert-WtgBuildPath $path
            if ([long]$file.size -ne (Get-Item -LiteralPath $path).Length -or $file.sha256 -notmatch '^[0-9A-Fa-f]{64}$' -or (Get-WtgSha256 $path) -ne $file.sha256) { throw 'Package integrity verification failed.' }
        }
        $actual = @(Get-WtgPayloadFiles $root)
        if ($actual.Count -ne $seen.Count) { throw 'Package has unexpected files.' }
    }
    foreach ($required in @('watchtower.exe','warden/warden.exe','warden/warden-launcher.exe','licenses/warden-launcher.cpp','platforms/qwindows.dll','multimedia/ffmpegmediaplugin.dll','ffmpeg.exe','prerequisites/vc_redist.x64.exe')) {
        if (@($manifest.files | Where-Object { $_.path -ieq $required }).Count -ne 1) { throw 'Required runtime component is missing from the package.' }
    }
    if(-not $manifest.PSObject.Properties['deploymentLauncher']){throw 'Deployment launcher provenance is missing.'}
    $launcher=$manifest.deploymentLauncher
    if($launcher.version -notmatch '^\d+\.\d+\.\d+$' -or $launcher.sourcePath -ne 'packaging/windows/generic/warden-launcher.cpp' -or $launcher.sourcePayloadPath -ne 'licenses/warden-launcher.cpp' -or $launcher.binaryPath -ne 'warden/warden-launcher.exe' -or $launcher.sourceSha256 -ne (Get-WtgSha256 (Join-Path $PackagePath 'payload\licenses\warden-launcher.cpp')) -or $launcher.binarySha256 -ne (Get-WtgSha256 (Join-Path $PackagePath 'payload\warden\warden-launcher.exe'))){throw 'Deployment launcher provenance differs from package contents.'}
    $allPackageFiles = @(Get-WtgPayloadFiles $PackagePath)
    if ($allPackageFiles.Count -ne (1+@($manifest.files).Count+@($manifest.helpers).Count)) { throw 'Package contains unexpected top-level files.' }
    return $manifest
}

function Build-WtgArtifact {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)]$Source)
    $sourceRoot = [IO.Path]::GetFullPath([string]$Source.Path)
    Assert-WtgBuildPath $sourceRoot -Container
    if ([string]$Source.Commit -notmatch '^[0-9A-Fa-f]{40}$') { throw 'Build source is not pinned to a full commit.' }
    $version = Get-WtgSourceVersion $sourceRoot
    $hook = Get-Content -LiteralPath (Join-Path $sourceRoot 'src\main.cpp') -Raw -Encoding UTF8
    $position = $hook.IndexOf('const QString testSettingsDir = qEnvironmentVariable("WT_SETTINGS_DIR")')
    if ($position -lt 0 -or $hook.IndexOf('auth->restoreSession()') -lt $position -or -not $hook.Contains('QSettings::setDefaultFormat(QSettings::IniFormat)') -or -not $hook.Contains('/.startup-settings.json')) {
        Stop-WtgBuild $Context 'This source version cannot be tested without reading existing app settings. Select a newer version.' 'Эту версию нельзя проверить без чтения настроек установленного приложения. Выберите более новую версию.'
    }
    $tools = $Context.Tools
    $environment = Get-WtgBuildEnvironment $Context
    foreach ($tool in @('FFmpeg','VCRedist')) { Assert-WtgBuildPath ([string]$tools[$tool]) }
    $status = Invoke-WtgBuildStep $Context 'source-clean' $tools.Git @('-C',$sourceRoot,'status','--porcelain') $sourceRoot $environment
    if ($status.StdOut.Trim()) { throw 'Build requires a clean source checkout.' }
    $head = Invoke-WtgBuildStep $Context 'source-head' $tools.Git @('-C',$sourceRoot,'rev-parse','HEAD') $sourceRoot $environment
    if ($head.StdOut.Trim() -ne $Source.Commit) { throw 'Source revision changed before building.' }
    $package = Join-Path $Context.RunDir 'package'
    $payload = Join-Path $package 'payload'
    if (Test-Path -LiteralPath $package) { throw 'This run already has package output. Start a new run.' }
    $null = [IO.Directory]::CreateDirectory($payload)
    $buildDir = Join-Path $Context.RunDir 'build'
    $jobs = [Math]::Max(1,[Math]::Min([int]$Context.BuildJobs,64))
    $null = Invoke-WtgBuildStep $Context 'configure' $tools.CMake @('--preset','windows','-B',$buildDir,('-DPKG_CONFIG_EXECUTABLE='+$tools.PkgConfig.Replace('\','/')),('-DCMAKE_MAKE_PROGRAM='+$tools.Ninja.Replace('\','/'))) $sourceRoot $environment
    $null = Invoke-WtgBuildStep $Context 'build' $tools.CMake @('--build',$buildDir,'--parallel',[string]$jobs) $sourceRoot $environment 14400
    $app = Join-Path $buildDir 'watchtower.exe'
    $pdb = Join-Path $buildDir 'watchtower.pdb'
    Assert-WtgBuildPath $app
    Assert-WtgBuildPath $pdb
    if ((Get-Item -LiteralPath $app).VersionInfo.FileVersion -ne ($version.Version+'.0')) { throw 'Built application version differs from the selected source.' }
    Copy-WtgBuildFile $app (Join-Path $payload 'watchtower.exe')
    $symbols = Join-Path $Context.RunDir 'symbols'
    Copy-WtgBuildFile $pdb (Join-Path $symbols 'watchtower.pdb')
    $wardenSource = Join-Path $sourceRoot 'warden\warden.py'
    $null = Invoke-WtgBuildStep $Context 'build-warden' $tools.Python @('-B','-m','PyInstaller','--onefile','--noconfirm','--clean','--log-level','WARN','--name','warden','--distpath',(Join-Path $payload 'warden'),'--workpath',(Join-Path $Context.RunDir 'pyi'),'--specpath',(Join-Path $Context.RunDir 'pyi'),$wardenSource) $sourceRoot $environment
    $warden = Join-Path $payload 'warden\warden.exe'
    Assert-WtgBuildPath $warden
    $verifyWarden = Join-Path $script:WtgBuildRoot '..\deploy\verify-warden.py'
    $match = Invoke-WtgBuildStep $Context 'warden-source-match' $tools.Python @('-B',$verifyWarden,'--exe',$warden,'--source',$wardenSource) $sourceRoot $environment 120
    if (-not ($match.StdOut | ConvertFrom-Json).matches) { throw 'Packaged Warden differs from selected source.' }
    $launcher=Build-WtgLauncher $Context $payload $environment
    $windep = Join-Path $tools.QtRoot 'bin\windeployqt.exe'
    Assert-WtgBuildPath $windep
    # Watchtower's current database is SQLite. windeployqt otherwise copies
    # every SQL plugin, including Oracle/PostgreSQL clients absent on fresh PCs.
    foreach ($cpp in Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'src') -Filter '*.cpp' -File -Recurse) {
        foreach ($driver in [regex]::Matches([IO.File]::ReadAllText($cpp.FullName),'\bQSQL[A-Z0-9]+\b')) {
            if ($driver.Value -ne 'QSQLITE') { throw 'This source requires another SQL driver. Update the runtime dependency profile before packaging.' }
        }
    }
    $null = Invoke-WtgBuildStep $Context 'qt-runtime' $windep @('--release','--qmldir',(Join-Path $sourceRoot 'qml'),'--no-compiler-runtime','--skip-plugin-types','sqldrivers','--dir',$payload,(Join-Path $payload 'watchtower.exe')) $sourceRoot $environment 600
    Copy-WtgBuildFile (Join-Path $tools.QtRoot 'plugins\sqldrivers\qsqlite.dll') (Join-Path $payload 'sqldrivers\qsqlite.dll')
    # The private offscreen launch must use the same package, not developer DLLs.
    Copy-WtgBuildFile (Join-Path $tools.QtRoot 'plugins\platforms\qoffscreen.dll') (Join-Path $payload 'platforms\qoffscreen.dll')
    $crt = Join-Path $environment['VCToolsRedistDir'] 'x64\Microsoft.VC143.CRT'
    Assert-WtgBuildPath $crt -Container
    foreach ($file in Get-ChildItem -LiteralPath $crt -Filter '*.dll' -File) { Copy-WtgBuildFile $file.FullName (Join-Path $payload $file.Name) }
    $plugins = @('coreelements','playback','typefindfunctions','videoconvertscale','videoparsersbad','app','rtp','rtsp','rtpmanager','udp','tcp','autodetect','d3d11')
    foreach ($plugin in $plugins) { Copy-WtgBuildFile (Join-Path $tools.GStreamerRoot ('lib\gstreamer-1.0\gst'+$plugin+'.dll')) (Join-Path $payload ('lib\gstreamer-1.0\gst'+$plugin+'.dll')) }
    Copy-WtgBuildFile (Join-Path $tools.GStreamerRoot 'libexec\gstreamer-1.0\gst-plugin-scanner.exe') (Join-Path $payload 'libexec\gstreamer-1.0\gst-plugin-scanner.exe')
    Copy-WtgBuildFile $tools.FFmpeg (Join-Path $payload 'ffmpeg.exe')
    # FFmpeg's documented runtime DLL set may differ from Qt's. A name/hash
    # collision is an incompatibility, never an overwrite of a Qt dependency.
    foreach ($file in Get-ChildItem -LiteralPath (Split-Path $tools.FFmpeg) -Filter '*.dll' -File) { Copy-WtgBuildFile $file.FullName (Join-Path $payload $file.Name) }
    Copy-WtgBuildFile $tools.VCRedist (Join-Path $payload 'prerequisites\vc_redist.x64.exe')
    Copy-WtgBuildTree (Join-Path $sourceRoot 'packaging\windows\licenses') (Join-Path $payload 'licenses')
    Copy-WtgBuildTree (Join-Path $tools.GStreamerRoot 'share\licenses') (Join-Path $payload 'licenses\gstreamer-vendor')
    Copy-WtgPackagedRuntimeLicenses $Context $payload $environment
    $closurePath = Join-Path $Context.RunDir 'runtime-closure.json'
    $null = Invoke-WtgBuildStep $Context 'runtime-closure' $tools.Python @('-B',(Join-Path $script:WtgBuildRoot 'runtime-closure.py'),'--payload',$payload,'--root',(Join-Path $tools.GStreamerRoot 'bin'),'--root',(Join-Path $tools.QtRoot 'bin'),'--root',(Split-Path $tools.FFmpeg),'--root',$crt,'--result',$closurePath) $sourceRoot $environment 600
    $closure = Get-Content -LiteralPath $closurePath -Raw | ConvertFrom-Json
    if (-not $closure.passed) { throw 'Runtime dependency closure did not pass.' }
    $runtimeEnv = @{ PATH = ($payload+';'+$env:SystemRoot+'\System32;'+$env:SystemRoot); QT_PLUGIN_PATH=$payload; QML2_IMPORT_PATH=(Join-Path $payload 'qml'); GST_PLUGIN_SYSTEM_PATH_1_0=(Join-Path $payload 'lib\gstreamer-1.0'); GST_PLUGIN_PATH_1_0=''; GST_REGISTRY_1_0=(Join-Path $Context.RunDir 'gst-test-registry.bin'); GST_PLUGIN_SCANNER=(Join-Path $payload 'libexec\gstreamer-1.0\gst-plugin-scanner.exe'); PYTHONUTF8='1'; PYTHONIOENCODING='utf-8' }
    $ffmpegVersion = Invoke-WtgBuildStep $Context 'ffmpeg-version' (Join-Path $payload 'ffmpeg.exe') @('-hide_banner','-version') $payload $runtimeEnv 30
    if ($ffmpegVersion.StdOut -match '--enable-(gpl|nonfree)') { throw 'The supplied FFmpeg build enables incompatible GPL/nonfree components.' }
    $fixture = Join-Path $Context.RunDir 'export-fixture.mp4'
    $null = Invoke-WtgBuildStep $Context 'export-fixture' (Join-Path $payload 'ffmpeg.exe') @('-hide_banner','-nostdin','-loglevel','error','-f','lavfi','-i','testsrc=size=320x180:rate=10','-t','1','-vf','format=yuv420p','-c:v','libopenh264','-b:v','800k','-an',$fixture) $payload $runtimeEnv 90
    if (-not (Test-Path -LiteralPath $fixture) -or (Get-Item -LiteralPath $fixture).Length -lt 100) { throw 'The packaged video exporter did not produce the test clip.' }
    $null = Invoke-WtgBuildStep $Context 'decode-fixture' (Join-Path $payload 'ffmpeg.exe') @('-hide_banner','-nostdin','-loglevel','error','-i',$fixture,'-f','null','-') $payload $runtimeEnv 90
    $monitor = Join-Path $script:WtgBuildRoot '..\deploy\isolated-startup.py'
    $startupResult = Join-Path $Context.RunDir 'startup-result.json'
    $null = Invoke-WtgBuildStep $Context 'isolated-startup' $tools.Python @('-B',$monitor,'--exe',(Join-Path $payload 'watchtower.exe'),'--home',(Join-Path $Context.RunDir 'startup-home'),'--flightrec',(Join-Path $Context.RunDir 'startup-flightrec'),'--result',$startupResult,'--seconds','40','--symbols',$symbols) $Context.RunDir $runtimeEnv 100
    $startup = Get-Content -LiteralPath $startupResult -Raw | ConvertFrom-Json
    if (-not $startup.Passed -or -not $startup.NativeSettingsIsolated -or $startup.SHA256 -ne (Get-WtgSha256 $app)) { throw 'Private application startup verification failed.' }
    $wardenHome = Join-Path $Context.RunDir 'warden-test-profile'
    $null = [IO.Directory]::CreateDirectory($wardenHome)
    $wardenEnv = @{}; foreach ($key in $runtimeEnv.Keys) { $wardenEnv[$key] = $runtimeEnv[$key] }
    foreach ($key in @('USERPROFILE','HOME','APPDATA','LOCALAPPDATA','WT_WARDEN_WARDEN_DIR','WT_WARDEN_DATA_DIR')) { $wardenEnv[$key] = $wardenHome }
    $wardenEnv['WT_WARDEN_BACKEND_URL']=''
    $wardenStatus = Invoke-WtgBuildStep $Context 'warden-status' $warden @('status') $wardenHome $wardenEnv 60
    if ($wardenStatus.StdOut -notmatch ('(?m)^warden '+[regex]::Escape($version.WardenVersion)+'\s')) { throw 'Packaged Warden did not report its expected version.' }
    $helpers = Join-Path $package 'helpers'
    foreach ($name in @('Common.psm1','Install.psm1','install-target.ps1','installer-entry.ps1')) { Copy-WtgBuildFile (Join-Path $script:WtgBuildRoot $name) (Join-Path $helpers $name) }
    foreach ($name in @('Requirements.psm1','requirements.json','messages.json')) { if (Test-Path -LiteralPath (Join-Path $script:WtgBuildRoot $name)) { Copy-WtgBuildFile (Join-Path $script:WtgBuildRoot $name) (Join-Path $helpers $name) } }
    Copy-WtgBuildFile (Join-Path $script:WtgBuildRoot '..\deploy\StationVideoHealth.psm1') (Join-Path $helpers 'StationVideoHealth.psm1')
    $toolVersions = Get-WtgBuildVersions $Context $environment
    $tests = [ordered]@{ sourceMatched=$true; wardenMatched=$true; launcherLifecycle=$true; launcherLifecycleChecks=$launcher.lifecycleChecks; staticRuntimeClosure=$true; privateSettingsStartup=$true; privateStartupSeconds=$startup.MonitoredSeconds; wardenStatus=$true; fixtureEncode=$true; fixtureDecode=$true; cleanMachine='Unverified'; qtMultimediaPlayback='Unverified'; liveVideo='Deferred'; rebootStartup='Unverified' }
    $manifest = [ordered]@{ schemaVersion=1; product='CilexWatchtower'; version=$version.Version; wardenVersion=$version.WardenVersion; sourceCommit=$Source.Commit; sourceTag=$Source.Tag; repository=$Source.Repository; architecture='x64'; minimumOsBuild=17763; osValidation='DependencyBaselineOnly'; createdUtc=[DateTime]::UtcNow.ToString('o'); buildConfiguration='RelWithDebInfo'; dependencies=$toolVersions; deploymentLauncher=$launcher; tests=$tests; files=@(Get-WtgPayloadFiles $payload); helpers=@(Get-WtgPayloadFiles $helpers); prerequisites=@([ordered]@{path='prerequisites/vc_redist.x64.exe';sha256=Get-WtgSha256 $tools.VCRedist;size=(Get-Item -LiteralPath $tools.VCRedist).Length;arguments=@('/install','/quiet','/norestart');allowedExitCodes=@(0,1638,3010);publisher='Microsoft Corporation'}) }
    Write-WtgJson -Path (Join-Path $payload 'licenses\generic-build-provenance.json') -Value ([ordered]@{ sourceCommit=$Source.Commit; deploymentLauncher=$launcher; dependencies=$toolVersions; gstreamerPlugins=$plugins; note='Application and Warden use sourceCommit. The Windows deployment launcher is a separate helper identified by its own source and binary hashes. Older source-offer text describing a rolling FFmpeg download does not describe this build.' })
    $manifest.files = @(Get-WtgPayloadFiles $payload)
    Write-WtgJson -Path (Join-Path $package 'manifest.json') -Value $manifest
    $null = Test-WtgArtifact $package
    $finalStatus = Invoke-WtgBuildStep $Context 'source-final-clean' $tools.Git @('-C',$sourceRoot,'status','--porcelain') $sourceRoot $environment
    if ($finalStatus.StdOut.Trim()) { throw 'The build modified its source checkout.' }
    return [pscustomobject]@{ PackagePath=$package; ManifestPath=(Join-Path $package 'manifest.json'); Version=$version.Version; WardenVersion=$version.WardenVersion; SourceCommit=$Source.Commit; Tests=$tests; SymbolsPath=$symbols }
}

function New-WtgInstaller {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)][string]$PackagePath)
    $manifest = Test-WtgArtifact $PackagePath
    Assert-WtgBuildPath ([string]$Context.Tools.Makensis)
    $null = [IO.Directory]::CreateDirectory($Context.OutputDir)
    $output = Join-Path $Context.OutputDir ('CilexWatchtower-'+$manifest.version+'-'+$manifest.sourceCommit.Substring(0,8)+'-windows-x64-setup.exe')
    if (Test-Path -LiteralPath $output) { throw 'Installer output already exists; choose another output directory.' }
    foreach ($text in @($PackagePath,$output,$script:WtgBuildRoot)) { if ($text -match '["$\r\n]') { throw 'The installer compiler cannot safely use this path.' } }
    $args = @('/V2',('/DPACKAGE_DIR='+$PackagePath),('/DOUTPUT_FILE='+$output),('/DVERSION='+$manifest.version),('/DMANIFEST_SHA256='+(Get-WtgSha256 (Join-Path $PackagePath 'manifest.json'))),(Join-Path $script:WtgBuildRoot 'installer.nsi'))
    $null = Invoke-WtgBuildStep $Context 'installer-compile' $Context.Tools.Makensis $args $script:WtgBuildRoot @{} 1800
    Assert-WtgBuildPath $output
    $signatureState = 'Unsigned'
    if ($Context.PSObject.Properties.Name -contains 'SigningThumbprint' -and $Context.SigningThumbprint) {
        $thumb = ([string]$Context.SigningThumbprint).Replace(' ','')
        if ($thumb -notmatch '^[0-9A-Fa-f]{40}$') { throw 'Invalid signing certificate thumbprint.' }
        $cert = Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$thumb)
        if (-not $cert.HasPrivateKey) { throw 'Signing certificate has no accessible private key.' }
        $parameters = @{FilePath=$output;Certificate=$cert;HashAlgorithm='SHA256'}
        if ($Context.PSObject.Properties.Name -contains 'TimestampUrl' -and $Context.TimestampUrl) {
            if ($Context.PSObject.Properties.Name -contains 'DependencyMode' -and $Context.DependencyMode -eq 'Offline') { throw 'Timestamping requires network access; omit the timestamp URL in offline mode.' }
            if ([string]$Context.TimestampUrl -notmatch '^https://') { throw 'The timestamp service must use HTTPS.' }; $parameters.TimestampServer=$Context.TimestampUrl
        }
        $signature = Set-AuthenticodeSignature @parameters
        if ($signature.Status -ne 'Valid') { throw 'Installer signature verification failed.' }
        $signatureState='SignedAndVerified'
    }
    $record = [pscustomobject]@{Path=$output;SHA256=Get-WtgSha256 $output;Version=$manifest.version;SourceCommit=$manifest.sourceCommit;Signature=$signatureState;CleanOfflineMachine='Unverified'}
    Write-WtgJson -Path ($output+'.json') -Value $record
    return $record
}

function New-WtgBootstrapBundle {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Context)
    $null=[IO.Directory]::CreateDirectory($Context.OutputDir)
    $bundle=Join-Path $Context.RunDir 'bootstrap'
    if (Test-Path -LiteralPath $bundle) { throw 'Bootstrap output already exists. Use a new run.' }
    $generic=Join-Path $bundle 'packaging\windows\generic'
    foreach ($name in @('Common.psm1','Source.psm1','Dependencies.psm1','Requirements.psm1','Build.psm1','Install.psm1','Remote.psm1','install-target.ps1','installer-entry.ps1','installer.nsi','runtime-closure.py','git-askpass.ps1','dependencies.json','requirements.json','warden-launcher.cpp')) {
        Copy-WtgBuildFile (Join-Path $script:WtgBuildRoot $name) (Join-Path $generic $name)
    }
    Copy-WtgBuildFile (Join-Path $script:WtgBuildRoot '..\deploy-watchtower.ps1') (Join-Path $bundle 'packaging\windows\deploy-watchtower.ps1')
    foreach ($name in @('isolated-startup.py','verify-warden.py','StationVideoHealth.psm1')) {
        Copy-WtgBuildFile (Join-Path $script:WtgBuildRoot ('..\deploy\'+$name)) (Join-Path $bundle ('packaging\windows\deploy\'+$name))
    }
    foreach ($name in @('run-tests.ps1','test-requirements.ps1','test-dependencies.ps1','test-common-source.ps1','test-entry.ps1','test-install.ps1','test-remote.ps1','test-build.ps1','test-runtime-closure.py','test-launcher.ps1','launcher-fixture.cpp')) {
        Copy-WtgBuildFile (Join-Path $script:WtgBuildRoot ('tests\'+$name)) (Join-Path $generic ('tests\'+$name))
    }
    $readmePath=Join-Path $script:WtgBuildRoot 'README.md'
    Assert-WtgBuildPath $readmePath
    $readme=[IO.File]::ReadAllText($readmePath)
    # The station-specific updater is intentionally not part of this bundle.
    $readme=$readme.Replace('](../deploy/build-and-update.ps1)','](https://github.com/romayankin/cilex-watchtower/blob/main/packaging/windows/deploy/build-and-update.ps1)')
    $readme=$readme.Replace('](../../../docs/plans/2026-10-13-generic-windows-deployment-specification.md)','](https://github.com/romayankin/cilex-watchtower/blob/main/docs/plans/2026-10-13-generic-windows-deployment-specification.md)')
    $readme=$readme.Replace('](../../../docs/verification/2026-10-13-generic-deployment/README.md)','](https://github.com/romayankin/cilex-watchtower/blob/main/docs/verification/2026-10-13-generic-deployment/README.md)')
    [IO.File]::WriteAllText((Join-Path $generic 'README.md'),$readme,(New-Object Text.UTF8Encoding($false)))
    $start=@'
# Cilex Watchtower deployment bootstrap

Verify this archive's SHA-256 using the value received from its trusted distributor.
Extract the complete archive; keep the folder structure together.

Open 64-bit Windows PowerShell in `packaging\windows` and first run:

```powershell
.\deploy-watchtower.ps1 -Mode Check -CheckRole Build
```

Read [the usage guide](packaging/windows/generic/README.md) before building or
installing. The package contains deployment tools, not a prebuilt Watchtower
installer. Hardware limits, clean-machine installation and reboot behavior
must be assessed using the guide's validation status.

The bundled `packaging/windows/generic/tests/run-tests.ps1` runs safe fixture
checks. Optional `-PythonPath` and `-MakensisPath` add runtime-analysis and
installer-wrapper checks. `-VsDevCmdPath` also builds and tests the native
startup helper. These checks do not install or reboot a station.
'@
    [IO.File]::WriteAllText((Join-Path $bundle 'README.md'),$start,(New-Object Text.UTF8Encoding($false)))
    Write-WtgJson -Path (Join-Path $bundle 'bootstrap-manifest.json') -Value ([ordered]@{schemaVersion=1;createdUtc=[DateTime]::UtcNow.ToString('o');entry='packaging/windows/deploy-watchtower.ps1';files=@(Get-WtgPayloadFiles $bundle);note='Verify the archive hash from the trusted distribution channel before extracting or running the bootstrap.'})
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=Join-Path $Context.OutputDir ('CilexWatchtower-bootstrap-'+$Context.RunId+'.zip')
    if (Test-Path -LiteralPath $zip) { throw 'Bootstrap archive already exists.' }
    [IO.Compression.ZipFile]::CreateFromDirectory($bundle,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
    $result=[pscustomobject]@{Path=$zip;SHA256=Get-WtgSha256 $zip;Entry='packaging/windows/deploy-watchtower.ps1'}
    Write-WtgJson -Path ($zip+'.json') -Value $result
    return $result
}

Export-ModuleMember -Function Build-WtgArtifact,New-WtgInstaller,New-WtgBootstrapBundle,Test-WtgArtifact,Get-WtgSourceVersion
