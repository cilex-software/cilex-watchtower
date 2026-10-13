#requires -Version 5.1
param()
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\Dependencies.psm1') -Force
$script:passed=0
function Check([bool]$Condition,[string]$Label) {if(-not $Condition){throw ('FAIL: '+$Label)};$script:passed++}
function Fails([scriptblock]$Action,[string]$Pattern,[string]$Label) {try{&$Action|Out-Null}catch{Check ($_.Exception.Message -match $Pattern) $Label;return};throw ('FAIL: no refusal: '+$Label)}
$root=Join-Path ([IO.Path]::GetTempPath()) ('wtg-dependencies-fixture-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
try {
    $catalog=Get-WtgDependencyCatalog
    Check ($catalog.schemaVersion -eq 1) 'known catalog schema'
    Check (@($catalog.packages).Count -ge 20) 'full toolchain catalog'
    foreach($p in $catalog.packages){
        Check ($p.sha256 -match '^[a-f0-9]{64}$') ($p.id+' immutable digest')
        Check (([uri]$p.url).Scheme -eq 'https' -and -not ([uri]$p.url).UserInfo) ($p.id+' HTTPS public link')
        Check ($p.manual.en -and $p.manual.ru -and $p.page -and $p.license -and $p.downloadBytes -gt 0 -and $p.expandedBytes -gt 0) ($p.id+' usable offline instructions')
    }
    $context=[pscustomobject]@{Language='en';CacheDir=$root;DependencyMode='Offline';NonInteractive=$true}
    $fixture=Join-Path $root 'sample.bin';[IO.File]::WriteAllText($fixture,'fixture-only')
    $package=[pscustomobject]@{id='Fixture';version='1';url='https://example.invalid/file.zip';sha256=(Get-FileHash $fixture).Hash.ToLowerInvariant();publisher='';downloadBytes=12;manual=@{en='Supply file.';ru='Добавьте файл.'};page='https://example.invalid/'}
    Assert-WtgDependencyFile $package $fixture -Offline
    Check $true 'matching cached payload verifies offline'
    [IO.File]::WriteAllText($fixture,'different');Fails {Assert-WtgDependencyFile $package $fixture -Offline} 'integrity' 'corrupt payload refused'
    $cached=Get-WtgDependencyCachePath $context $package
    Check ([IO.Path]::GetFileName($cached) -match '^[a-f0-9]{16}-file.zip$') 'cache is content addressed'
    Fails {Save-WtgDependencyFile $context $package} 'Missing dependency' 'offline miss fails without network'
    [IO.File]::WriteAllText($cached,'fixture-only');$returned=Save-WtgDependencyFile $context $package
    Check ($returned -eq $cached) 'offline cache hit returned without download'
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=Join-Path $root 'valid.zip';$zip=[IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Create)
    try {$entry=$zip.CreateEntry('nested/item.txt');$writer=New-Object IO.StreamWriter($entry.Open());$writer.Write('valid');$writer.Dispose()}finally{$zip.Dispose()}
    $destination=Join-Path $root 'expanded';Expand-WtgDependencyZip $archive $destination 1MB
    Check ((Get-Content (Join-Path $destination 'nested\item.txt') -Raw) -eq 'valid') 'normal zip extracts'
    Fails {Expand-WtgDependencyZip $archive (Join-Path $root 'too-small') 1} 'budget' 'expanded-byte budget enforced before writes'
    Check (-not(Test-Path (Join-Path $root 'too-small'))) 'rejected archive writes no destination'
    $archive=Join-Path $root 'traversal.zip';$zip=[IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Create)
    try {$entry=$zip.CreateEntry('../escaped.txt');$writer=New-Object IO.StreamWriter($entry.Open());$writer.Write('bad');$writer.Dispose()}finally{$zip.Dispose()}
    Fails {Expand-WtgDependencyZip $archive (Join-Path $root 'traversal') 1MB} 'traversal' 'zip traversal refused'
    Check (-not(Test-Path (Join-Path $root 'escaped.txt'))) 'traversal never writes outside staging'
    $context.Language='ru';$package.url='https://example.invalid/absent.zip'
    Fails {Save-WtgDependencyFile $context $package} 'Нет зависимости' 'Russian offline actionable failure'
    $module=Get-Module Dependencies
    Fails {& $module {Receive-WtgPinnedFile 'http://example.invalid/file' 'C:\not-written' 1MB}} 'HTTPS' 'HTTP download refused before I/O'
    Fails {& $module {Receive-WtgPinnedFile 'https://user:secret@example.invalid/file' 'C:\not-written' 1MB}} 'HTTPS' 'embedded download credential refused'
    $failure=& $module {Get-WtgDownloadFailure (New-Object Net.WebException('fixture',[Net.WebExceptionStatus]::NameResolutionFailure))}
    Check ($failure -eq 'DNS') 'DNS distinguished from no internet'
    $failure=& $module {Get-WtgDownloadFailure (New-Object Net.WebException('fixture',[Net.WebExceptionStatus]::TrustFailure))}
    Check ($failure -eq 'TLS') 'TLS validation error distinguished'
    $sdk=Join-Path $root 'sdk'
    $sdkPaths=@('Include\10.0.26100.0\um\Windows.h','Include\10.0.26100.0\ucrt\stdio.h','Lib\10.0.26100.0\um\x64\kernel32.lib','Lib\10.0.26100.0\ucrt\x64\ucrt.lib','bin\10.0.26100.0\x64\rc.exe')
    foreach($relative in $sdkPaths){$file=Join-Path $sdk $relative;$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file));[IO.File]::WriteAllText($file,'fixture')}
    $ready=& $module {param($p)Test-WtgWindowsSdk $p} $sdk
    Check $ready 'complete SDK headers libraries and resource compiler detected'
    Remove-Item -LiteralPath (Join-Path $sdk 'Lib\10.0.26100.0\ucrt\x64\ucrt.lib')
    $ready=& $module {param($p)Test-WtgWindowsSdk $p} $sdk
    Check (-not $ready) 'partial SDK not accepted as ready'
    # Force the downloader to fail if an offline code path tries to call it.
    & $module {function script:Receive-WtgPinnedFile {throw 'NETWORK_MUST_NOT_BE_CALLED'}}
    $package.url='https://example.invalid/file.zip';$returned=Save-WtgDependencyFile $context $package
    Check ($returned -eq $cached) 'offline cache never invokes downloader'
    $package.url='https://example.invalid/missing.zip'
    Fails {Save-WtgDependencyFile $context $package} 'Нет зависимости' 'offline miss never invokes downloader'
    # A fake vendor process requests reboot; no real installer or reboot runs.
    $restartContext=[pscustomobject]@{Language='en';RunDir=$root;DependencyMode='Auto';NonInteractive=$true}
    $restartPackage=[pscustomobject]@{id='PythonBase';version='3.12.10';sha256=('a'*64);kind='PythonInstaller';relativePath='python.exe';expandedBytes=1}
    $restartDirectory=Join-Path $root 'restart-python'
    & $module {
        $script:fixtureInstallerCalls=0;$script:fixtureToolChecks=0;$script:fixtureToolReady=$false
        $script:fixtureBoot=[DateTime]::UtcNow.AddDays(-1)
        function script:Invoke-WtgProcess {$script:fixtureInstallerCalls++;return [pscustomobject]@{ExitCode=3010}}
        function script:Get-WtgDependencyBootUTC {return $script:fixtureBoot}
        function script:Test-WtgExistingTool {param($Id,$Path)$script:fixtureToolChecks++;return $script:fixtureToolReady}
    }
    $restartFailure=$null
    try{& $module {param($c,$p,$d)Install-WtgCachedDependency $c $p 'unused-fixture-installer.exe' $d @{}} $restartContext $restartPackage $restartDirectory}catch{$restartFailure=$_.Exception}
    Check ($restartFailure -and $restartFailure.Data['WtgRestartRequired'] -eq $true) 'vendor 3010 retains typed restart state'
    $restartReceipt=Join-Path $restartDirectory '.wtg-dependency.json'
    $saved=Get-Content -LiteralPath $restartReceipt -Raw|ConvertFrom-Json
    Check ($saved.State -eq 'RestartRequired' -and $saved.RequestedUTC -and $saved.Id -eq 'PythonBase' -and -not $saved.PSObject.Properties['VerifiedUTC']) '3010 writes pending receipt without claiming validation'
    Fails {& $module {param($c,$p,$d)Get-WtgCachedDependencyTool $c $p $d 'Python'} $restartContext $restartPackage $restartDirectory} 'requires a Windows restart' 'rerun before reboot remains restart-required'
    Check ((& $module {$script:fixtureToolChecks}) -eq 0) 'pending reboot does not accept a tool version probe'
    & $module {$script:fixtureBoot=$null}
    Fails {& $module {param($c,$p,$d)Get-WtgCachedDependencyTool $c $p $d 'Python'} $restartContext $restartPackage $restartDirectory} 'requires a Windows restart' 'unknown boot cannot clear pending restart'
    & $module {$script:fixtureBoot=[DateTime]::UtcNow.AddMinutes(1)}
    Fails {& $module {param($c,$p,$d)Get-WtgCachedDependencyTool $c $p $d 'Python'} $restartContext $restartPackage $restartDirectory} 'version/path check' 'new boot without a valid tool cannot clear pending receipt'
    $saved=Get-Content -LiteralPath $restartReceipt -Raw|ConvertFrom-Json
    Check ($saved.State -eq 'RestartRequired') 'failed post-reboot validation preserves pending receipt'
    & $module {$script:fixtureToolReady=$true}
    $found=& $module {param($c,$p,$d)Get-WtgCachedDependencyTool $c $p $d 'Python'} $restartContext $restartPackage $restartDirectory
    $saved=Get-Content -LiteralPath $restartReceipt -Raw|ConvertFrom-Json
    Check ($found -eq (Join-Path $restartDirectory 'python.exe') -and $saved.State -eq 'Verified' -and $saved.VerifiedUTC) 'post-reboot rerun discovers validated cached Python'
    Check ((& $module {$script:fixtureInstallerCalls}) -eq 1) 'post-reboot reuse never repeats the vendor installation'
    $restartPackage.sha256='b'*64
    Fails {& $module {param($c,$p,$d)Get-WtgCachedDependencyTool $c $p $d 'Python'} $restartContext $restartPackage $restartDirectory} 'differs from the selected package' 'receipt from another package is refused'
    $restartContext.Language='ru'
    $localized=& $module {param($c)New-WtgDependencyRestartRequired $c} $restartContext
    Check ($localized.Data['WtgRestartRequired'] -eq $true -and $localized.Message -match 'перезагрузка Windows') 'Russian restart guidance preserves the typed state'
    # Exercise the real preparation loop, stopping before its first build action.
    $pythonPackage=$catalog.packages|Where-Object id -eq 'PythonBase'
    $prepared=Join-Path $root ('tools\PythonBase-'+$pythonPackage.version)
    [IO.Directory]::CreateDirectory($prepared)|Out-Null
    $pending=@{Id=$pythonPackage.id;Version=$pythonPackage.version;Sha256=$pythonPackage.sha256;State='RestartRequired';RequestedUTC=[DateTime]::UtcNow.AddMinutes(-1).ToString('o')}
    [IO.File]::WriteAllText((Join-Path $prepared '.wtg-dependency.json'),($pending|ConvertTo-Json))
    $loopContext=[pscustomobject]@{Language='en';RunDir=$root;CacheDir=$root;DependencyMode='Offline';NonInteractive=$true;AcceptLicenses=$true;Tools=@{}}
    & $module {
        function script:Get-WtgExistingTools {return @{Git='fixture';CMake='fixture';Ninja='fixture';SevenZip='fixture';VsDevCmd='fixture';FFmpeg='fixture';QtRoot='fixture';GStreamerRoot='fixture';PkgConfig='fixture';VCRedist='fixture'}}
        function script:Install-WtgCachedDependency {throw 'FIXTURE_MUST_NOT_INSTALL'}
        function script:Save-WtgDependencyFile {throw 'FIXTURE_MUST_NOT_DOWNLOAD'}
        function script:Invoke-WtgProcess {param($FilePath,$Arguments)$stop=New-Object InvalidOperationException 'FIXTURE_REACHED_BUILD';$stop.Data['Python']=$FilePath;throw $stop}
    }
    $loopFailure=$null
    try{& $module {param($c)Initialize-WtgDependenciesInternal $c} $loopContext|Out-Null}catch{$loopFailure=$_.Exception}
    Check ($loopFailure -and $loopFailure.Message -eq 'FIXTURE_REACHED_BUILD' -and $loopFailure.Data['Python'] -eq (Join-Path $prepared $pythonPackage.relativePath)) 'real preparation resumes with cached Python without download or reinstall'
    $saved=Get-Content -LiteralPath (Join-Path $prepared '.wtg-dependency.json') -Raw|ConvertFrom-Json
    Check ($saved.State -eq 'Verified') 'preparation loop promotes only a post-reboot validated receipt'
} finally {
    $full=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -like 'wtg-dependencies-fixture-*'){Remove-Item -LiteralPath $full -Recurse -Force}
}
Write-Output ('Dependency fixtures: '+$script:passed+' passed.')
