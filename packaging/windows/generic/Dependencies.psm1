# Pinned build prerequisites. Windows PowerShell 5.1; no global PATH changes.
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -ErrorAction Stop

function Get-WtgDependencyText($Context,[string]$En,[string]$Ru) { if ($Context.Language -eq 'ru') {return $Ru}; return $En }
function Get-WtgDependencyCatalog { Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dependencies.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function Get-WtgDependencyCachePath($Context,$Package) {
    # Content-addressing prevents a package-name collision across versions/retries.
    $file=[IO.Path]::GetFileName(([uri]$Package.url).AbsolutePath)
    if (-not $file -or $file -match '[<>:"|?*]') { throw 'Invalid dependency filename.' }
    $null=Resolve-WtgSafeDirectory -Path $Context.CacheDir -AllowExisting
    return (Join-Path $Context.CacheDir ($Package.sha256.Substring(0,16)+'-'+$file))
}
function Assert-WtgDependencyFile {
    param([Parameter(Mandatory)]$Package,[Parameter(Mandatory)][string]$Path,[switch]$Offline)
    if ($Package.sha256 -notmatch '^[a-fA-F0-9]{64}$') {throw 'Dependency is missing a pinned SHA-256 digest.'}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {throw 'Dependency package is missing.'}
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Package.sha256) {throw 'Dependency integrity check failed; obtain the exact file from its official link.'}
    # Offline mode uses the already pinned digest, avoiding online certificate revocation lookups.
    if ($Package.publisher -and -not $Offline) {
        $signature=Get-AuthenticodeSignature -LiteralPath $Path
        if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch ([regex]::Escape($Package.publisher))) {throw 'Dependency publisher signature could not be verified.'}
    }
}
function Assert-WtgDependencySpace {
    param([string]$Path,[long]$RequiredBytes)
    $root=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    $drive=New-Object IO.DriveInfo($root)
    if (-not $drive.IsReady -or $drive.AvailableFreeSpace -lt $RequiredBytes) {throw 'There is insufficient space for the actual dependency payload and extraction. Free space and retry.'}
}
function Get-WtgDownloadFailure {
    param([Exception]$Exception)
    $current=$Exception
    while ($current.InnerException) {$current=$current.InnerException}
    if ($current -is [Net.WebException]) {
        if ($current.Response) {switch ([int]$current.Response.StatusCode) {401{return 'Authorization'} 403{return 'AccessDenied'} 404{return 'PackageUnavailable'} 407{return 'ProxyAuthentication'} default{return 'HTTP'}}}
        switch ($current.Status.ToString()) {'NameResolutionFailure'{return 'DNS'} 'ProxyNameResolutionFailure'{return 'Proxy'} 'TrustFailure'{return 'TLS'} 'SecureChannelFailure'{return 'TLS'} 'Timeout'{return 'Timeout'}}
    }
    return 'ConnectionOrDisk'
}
function Receive-WtgPinnedFile {
    param([string]$Url,[string]$Destination,[long]$MaximumBytes)
    $uri=[uri]$Url
    if ($uri.Scheme -ne 'https' -or $uri.UserInfo) {throw 'Dependency downloads require HTTPS without embedded credentials.'}
    # Explicit redirect handling prevents HTTPS -> HTTP downgrade. No credentials
    # or authorization headers are ever supplied to these public downloads.
    $partial=$Destination+'.partial'; $response=$null; $inputStream=$null; $outputStream=$null
    $oldTls=[Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol=$oldTls -bor [Net.SecurityProtocolType]::Tls12
        for ($redirect=0;$redirect -le 8;$redirect++) {
            $request=[Net.HttpWebRequest]::Create($uri);$request.AllowAutoRedirect=$false;$request.Timeout=30000;$request.ReadWriteTimeout=30000;$request.UserAgent='CilexWatchtower-Deployment/1'
            $response=$request.GetResponse()
            if ([int]$response.StatusCode -ge 300 -and [int]$response.StatusCode -lt 400) {
                $next=New-Object Uri($uri,$response.Headers['Location']);$response.Dispose();$response=$null
                if ($next.Scheme -ne 'https' -or $next.UserInfo) {throw 'Unsafe dependency download redirect was refused.'};$uri=$next;continue
            }
            break
        }
        if (-not $response -or [int]$response.StatusCode -ne 200) {throw 'Dependency download could not be resolved.'}
        if ($response.ContentLength -gt $MaximumBytes) {throw 'Dependency exceeds the allowed download size.'}
        Assert-WtgDependencySpace $Destination $MaximumBytes
        $inputStream=$response.GetResponseStream();$outputStream=New-Object IO.FileStream($partial,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer=New-Object byte[] 1048576; $count=0L; $deadline=[DateTime]::UtcNow.AddMinutes(30)
        while (($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $count+=$read; if ($count -gt $MaximumBytes -or [DateTime]::UtcNow -gt $deadline) {throw 'Dependency download size or time limit was reached.'}; $outputStream.Write($buffer,0,$read)
        }
        if ($response.ContentLength -ge 0 -and $count -ne $response.ContentLength) {throw 'Dependency download was incomplete.'}
        $outputStream.Dispose();$outputStream=$null
        return $partial
    } finally {
        if ($outputStream) {$outputStream.Dispose()};if ($inputStream) {$inputStream.Dispose()};if ($response) {$response.Dispose()}
        [Net.ServicePointManager]::SecurityProtocol=$oldTls
    }
}
function Show-WtgDependencyManual {
    param($Context,$Package,[string]$CachePath)
    $instruction=$Package.manual.en; if ($Context.Language -eq 'ru') {$instruction=$Package.manual.ru}
    Write-Host ($Package.id+' '+$Package.version+': '+$instruction)
    Write-Host $Package.page
    Write-Host $Package.url
    Write-Host ((Get-WtgDependencyText $Context 'Offline cache file: ' 'Файл в кэше: ')+$CachePath)
}
function Save-WtgDependencyFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Package)
    $path=Get-WtgDependencyCachePath $Context $Package
    if (Test-Path -LiteralPath $path -PathType Leaf) {Assert-WtgDependencyFile $Package $path -Offline:($Context.DependencyMode -eq 'Offline');return $path}
    $mode=$Context.DependencyMode
    while ($true) {
        if ($mode -eq 'Auto') {
            $null=[IO.Directory]::CreateDirectory($Context.CacheDir)
            $failure=''
            for ($attempt=1;$attempt -le 3;$attempt++) {
                try {
                    $partial=Receive-WtgPinnedFile $Package.url $path ([Math]::Max([long]$Package.downloadBytes*2,16MB))
                    Assert-WtgDependencyFile $Package $partial
                    if (Test-Path -LiteralPath $path) {Assert-WtgDependencyFile $Package $path;Remove-Item -LiteralPath $partial} else {[IO.File]::Move($partial,$path)}
                    return $path
                } catch {
                    $failure=Get-WtgDownloadFailure $_.Exception
                    if ($_.Exception.Message -match 'integrity|publisher|Unsafe|HTTPS|space|allowed download') {throw}
                    if ($failure -in @('PackageUnavailable','Authorization','AccessDenied','ProxyAuthentication','TLS')) {break}
                    if ($attempt -lt 3) {Start-Sleep -Seconds $attempt}
                }
            }
            Write-Host ((Get-WtgDependencyText $Context 'Download unavailable: ' 'Загрузка недоступна: ')+$Package.id+' ('+$failure+').')
        }
        Show-WtgDependencyManual $Context $Package $path
        if ($Context.NonInteractive) {throw (Get-WtgDependencyText $Context ('Missing dependency '+$Package.id+'. Supply its verified cache file and rerun.') ('Нет зависимости '+$Package.id+'. Добавьте проверенный файл в кэш и повторите запуск.'))}
        $prompt=Get-WtgDependencyText $Context 'Restore the connection and retry [R], supply the cache file manually [M], or cancel [C]?' 'Восстановить сеть и повторить [R], добавить файл в кэш вручную [M] или отменить [C]?'
        if ($Context.DependencyMode -eq 'Offline') {$prompt=Get-WtgDependencyText $Context 'Supply the cache file and press M, or cancel [C]. Offline mode will not use the network.' 'Добавьте файл в кэш и нажмите M или отмените [C]. В автономном режиме сеть не используется.'}
        $answer=Read-Host $prompt
        if ($answer -match '^(?i)c$' -or -not $answer) {throw 'Cancelled.'}
        if ($answer -match '^(?i)m$') {if (Test-Path -LiteralPath $path -PathType Leaf) {Assert-WtgDependencyFile $Package $path -Offline:($Context.DependencyMode -eq 'Offline');return $path};$mode='Manual'}
        elseif ($answer -match '^(?i)r$' -and $Context.DependencyMode -ne 'Offline') {$mode='Auto'}
    }
}
function Expand-WtgDependencyZip {
    param([string]$Archive,[string]$Destination,[long]$MaximumExpandedBytes=20GB)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root=[IO.Path]::GetFullPath($Destination).TrimEnd('\')+'\';$zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $size=0L
        foreach ($entry in $zip.Entries) {
            $full=[IO.Path]::GetFullPath((Join-Path $root $entry.FullName))
            if (-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or $entry.FullName.Contains(':') -or $entry.FullName -match '(^|[/\\])\.\.([/\\]|$)') {throw 'Archive path traversal was refused.'}
            $size+=$entry.Length;if ($size -gt $MaximumExpandedBytes) {throw 'Archive extraction size exceeds its budget.'}
        }
        Assert-WtgDependencySpace $Destination ($size+64MB)
        $null=[IO.Directory]::CreateDirectory($root)
        foreach ($entry in $zip.Entries) {
            $full=[IO.Path]::GetFullPath((Join-Path $root $entry.FullName))
            if (-not $entry.Name) {$null=[IO.Directory]::CreateDirectory($full);continue}
            $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full));[IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$full,$false)
        }
    } finally {$zip.Dispose()}
}
function Find-WtgVsTools {
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {return $null}
    $r=Invoke-WtgProcess -FilePath $vswhere -Arguments @('-latest','-products','*','-version','[17.14,18.0)','-requires','Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-property','installationPath') -TimeoutSeconds 20
    $path=$r.StdOut.Trim();if ($path -and (Test-Path -LiteralPath (Join-Path $path 'Common7\Tools\VsDevCmd.bat'))) {return (Join-Path $path 'Common7\Tools\VsDevCmd.bat')};return $null
}
function Test-WtgWindowsSdk {
    param([string]$Root='')
    if (-not $Root) {
        try {$Root=[string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -Name KitsRoot10 -ErrorAction Stop).KitsRoot10}catch{return $false}
    }
    if(-not $Root -or -not(Test-Path -LiteralPath (Join-Path $Root 'Include'))){return $false}
    foreach($directory in @(Get-ChildItem -LiteralPath (Join-Path $Root 'Include') -Directory -ErrorAction SilentlyContinue)) {
        $version=$null;if(-not[version]::TryParse($directory.Name,[ref]$version) -or $version -lt [version]'10.0.26100.0'){continue}
        $paths=@(('Include\'+$directory.Name+'\um\Windows.h'),('Include\'+$directory.Name+'\ucrt\stdio.h'),('Lib\'+$directory.Name+'\um\x64\kernel32.lib'),('Lib\'+$directory.Name+'\ucrt\x64\ucrt.lib'),('bin\'+$directory.Name+'\x64\rc.exe'))
        $complete=$true;foreach($relative in $paths){if(-not(Test-Path -LiteralPath (Join-Path $Root $relative) -PathType Leaf)){$complete=$false;break}}
        if($complete){return $true}
    }
    return $false
}
function Test-WtgExistingTool {
    param([string]$Id,[string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {return $false}
    try {
        switch ($Id) {
            'QtRoot' { $f=Join-Path $Path 'lib\cmake\Qt6\Qt6ConfigVersionImpl.cmake';if (-not(Test-Path $f)) {$f=Join-Path $Path 'lib\cmake\Qt6\Qt6ConfigVersion.cmake'};return ((Get-Content $f -Raw) -match '6\.12\.0' -and (Test-Path (Join-Path $Path 'bin\windeployqt.exe')) -and (Test-Path (Join-Path $Path 'lib\cmake\Qt6Multimedia\Qt6MultimediaConfig.cmake'))) }
            'GStreamerRoot' {return ((Get-Content (Join-Path $Path 'lib\pkgconfig\gstreamer-1.0.pc') -Raw) -match '(?m)^Version:\s*1\.26\.11\s*$' -and (Test-Path (Join-Path $Path 'bin\gstreamer-1.0-0.dll')) -and (Test-Path (Join-Path $Path 'include\gstreamer-1.0\gst\gst.h'))) }
            'VsDevCmd' {
                if([IO.Path]::GetFileName($Path) -ine 'VsDevCmd.bat' -or [IO.File]::ReadAllText($Path) -notmatch 'VisualStudioVersion=17\.0'){return $false}
                $vsRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($Path)) '..\..'))
                $versionFile=Join-Path $vsRoot 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
                if(-not(Test-Path -LiteralPath $versionFile -PathType Leaf)){return $false}
                $versionText=[IO.File]::ReadAllText($versionFile).Trim();$version=$null
                if(-not[version]::TryParse($versionText,[ref]$version) -or $version -lt [version]'14.44' -or $version -ge [version]'14.50'){return $false}
                $compiler=Join-Path $vsRoot ('VC\Tools\MSVC\'+$versionText+'\bin\Hostx64\x64\cl.exe')
                return ((Test-Path -LiteralPath $compiler -PathType Leaf) -and (Test-WtgWindowsSdk))
            }
            'VCRedist' {return ((Get-Item -LiteralPath $Path).VersionInfo.ProductName -match 'Microsoft.*Visual C\+\+' -and [version]((Get-Item -LiteralPath $Path).VersionInfo.FileVersion -replace ' .*$', '') -ge [version]'14.44') }
            'SevenZip' {return $true}
            'FFmpeg' {$r=Invoke-WtgProcess $Path @('-version') -TimeoutSeconds 15;return ($r.StdOut -match 'ffmpeg version.*(?:n)?8\.1\.' -and $r.StdOut -notmatch '--enable-(gpl|nonfree)' -and $r.StdOut -match '--enable-shared')}
            default {
                $args=@('--version');if ($Id -eq 'Makensis') {$args=@('/VERSION')}
                $r=Invoke-WtgProcess $Path $args -TimeoutSeconds 15
                switch ($Id) {
                    'Python' {return ($r.StdOut -match '^Python 3\.12\.')}
                    'Git' {if ($r.StdOut -match 'git version (\d+\.\d+\.\d+)') {return ([version]$Matches[1] -ge [version]'2.51.1')};return $false}
                    'CMake' {if ($r.StdOut -match 'cmake version (\d+\.\d+\.\d+)') {return ([version]$Matches[1] -ge [version]'3.24')};return $false}
                    'Ninja' {if ($r.StdOut.Trim() -match '^(\d+\.\d+\.\d+)') {return ([version]$Matches[1] -ge [version]'1.11')};return $false}
                    'Makensis' {return ($r.StdOut -match 'v3\.(1[3-9]|[2-9][0-9])')}
                    'PkgConfig' {return ($r.StdOut -match '\d+\.\d+')}
                    default {return $false}
                }
            }
        }
    } catch {return $false}
}
function Get-WtgExistingTools {
    param($Context,[switch]$ForInstaller)
    $tools=@{};foreach ($key in $Context.Tools.Keys) {$tools[$key]=$Context.Tools[$key]}
    $commands=@{Git='git.exe';CMake='cmake.exe';Ninja='ninja.exe';Python='python.exe';PkgConfig='pkg-config.exe';Makensis='makensis.exe';FFmpeg='ffmpeg.exe'}
    foreach ($id in $commands.Keys) {if (-not $tools[$id]) {$cmd=Get-Command $commands[$id] -ErrorAction SilentlyContinue;if ($cmd -and $cmd.Source -notmatch '\\WindowsApps\\') {$tools[$id]=$cmd.Source}}}
    if (-not $tools['Python']) {$python=Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe';if (Test-Path $python) {$tools.Python=$python}}
    if (-not $tools['QtRoot'] -and $env:QTDIR) {$tools.QtRoot=$env:QTDIR}
    if (-not $tools['GStreamerRoot'] -and $env:GSTREAMER_1_0_ROOT_MSVC_X86_64) {$tools.GStreamerRoot=$env:GSTREAMER_1_0_ROOT_MSVC_X86_64}
    if (-not $tools['GStreamerRoot']) {foreach($root in @((Join-Path $env:ProgramFiles 'gstreamer\1.0\msvc_x86_64'),(Join-Path $env:LOCALAPPDATA 'Programs\gstreamer\1.0\msvc_x86_64'))) {if(Test-WtgExistingTool GStreamerRoot $root){$tools.GStreamerRoot=$root;break}}}
    if (-not $tools['VsDevCmd']) {$tools.VsDevCmd=Find-WtgVsTools}
    foreach ($id in @($tools.Keys)) {if (-not (Test-WtgExistingTool $id $tools[$id])) {$tools.Remove($id)}}
    return $tools
}
function New-WtgDependencyRestartRequired($Context) {
    $message=Get-WtgDependencyText $Context 'A build prerequisite requires a Windows restart. Restart manually, then rerun the same command; its saved installation will be checked before reuse.' 'Для установленного компонента нужна перезагрузка Windows. Перезагрузите компьютер вручную и повторите команду; сохранённая установка будет проверена перед использованием.'
    $failure=New-Object InvalidOperationException $message
    $failure.Data['WtgRestartRequired']=$true
    return $failure
}
function Get-WtgDependencyBootUTC {
    return (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime()
}
function Set-WtgDependencyRestartReceipt($Context,$Package,[string]$Destination) {
    Write-WtgJson -Path (Join-Path $Destination '.wtg-dependency.json') -Value @{Id=$Package.id;Version=$Package.version;Sha256=$Package.sha256;State='RestartRequired';RequestedUTC=[DateTime]::UtcNow.ToString('o')}
    throw (New-WtgDependencyRestartRequired $Context)
}
function Get-WtgCachedDependencyTool($Context,$Package,[string]$Destination,[string]$ToolId) {
    $receipt=Join-Path $Destination '.wtg-dependency.json'
    if(-not(Test-Path -LiteralPath $receipt -PathType Leaf)){return $null}
    $null=Resolve-WtgSafeDirectory -Path $Destination -AllowExisting
    $saved=Get-Content -LiteralPath $receipt -Raw -Encoding UTF8|ConvertFrom-Json
    if($saved.Id -ne $Package.id -or $saved.Version -ne $Package.version -or $saved.Sha256 -ne $Package.sha256){throw 'Cached dependency receipt differs from the selected package. Use another cache or inspect the retained files.'}
    $state=if($saved.PSObject.Properties['State']){[string]$saved.State}else{'Installed'}
    if($state -notin @('Installed','Verified','RestartRequired')){throw 'Cached dependency receipt has an unknown state. Inspect the retained files.'}
    if($state -eq 'RestartRequired'){
        $requested=[DateTime]::MinValue
        if(-not $saved.PSObject.Properties['RequestedUTC'] -or -not [DateTime]::TryParse([string]$saved.RequestedUTC,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$requested)){throw 'Cached dependency restart evidence is invalid. Inspect the retained files.'}
        $boot=$null;try{$boot=Get-WtgDependencyBootUTC}catch{}
        if(-not $boot -or $boot -le $requested.ToUniversalTime()){throw (New-WtgDependencyRestartRequired $Context)}
    }
    $expected=Join-Path $Destination $Package.relativePath
    if(-not(Test-WtgExistingTool $ToolId $expected)){throw 'Cached dependency did not pass its version/path check. Inspect the retained files or choose another cache.'}
    # A restart receipt alone never proves that the tool is usable.
    Write-WtgJson -Path $receipt -Value @{Id=$Package.id;Version=$Package.version;Sha256=$Package.sha256;State='Verified';VerifiedUTC=[DateTime]::UtcNow.ToString('o')}
    return $expected
}
function Install-WtgCachedDependency {
    param($Context,$Package,[string]$Archive,[string]$Destination,[hashtable]$Tools)
    $null=Resolve-WtgSafeDirectory -Path $Destination -AllowExisting
    Assert-WtgDependencySpace $Destination ([long]$Package.expandedBytes+64MB)
    if (Test-Path -LiteralPath $Destination) {throw 'Dependency extraction directory already exists without a completed receipt. Use a new cache directory or inspect the partial operation.'}
    $null=[IO.Directory]::CreateDirectory($Destination)
    $log=Join-Path $Context.RunDir ('dependency-'+$Package.id+'.log')
    switch ($Package.kind) {
        'Zip' {Expand-WtgDependencyZip $Archive $Destination ([long]$Package.expandedBytes)}
        'File' {Copy-Item -LiteralPath $Archive -Destination (Join-Path $Destination $Package.relativePath)}
        'PythonInstaller' {
            $r=Invoke-WtgProcess $Archive @('/quiet','InstallAllUsers=0',('TargetDir='+$Destination),'PrependPath=0','Include_launcher=0','InstallLauncherAllUsers=0','Include_test=0','Include_pip=1','Include_doc=0','Include_tcltk=0','Shortcuts=0') -TimeoutSeconds 1200 -LogPath $log -AllowedExitCodes @(0,3010)
            if ($r.ExitCode -eq 3010) {Set-WtgDependencyRestartReceipt $Context $Package $Destination}
        }
        'VisualStudio' {
            $arguments=@('--quiet','--wait','--norestart','--nocache','--installPath',$Destination,'--add','Microsoft.VisualStudio.Workload.VCTools','--add','Microsoft.VisualStudio.Component.VC.Tools.x86.x64','--add','Microsoft.VisualStudio.Component.Windows11SDK.26100','--add','Microsoft.VisualStudio.Component.VC.Redist.14.Latest')
            if ($Context.DependencyMode -eq 'Offline') {throw 'Visual Studio requires a complete official offline layout. Install it manually, then rerun with Tools.VsDevCmd.'}
            if (-not (Test-WtgElevation)) {
                if ($Context.NonInteractive) {throw 'Visual Studio requires elevation. Run its official installer as administrator, then retry.'}
                Write-Host (Get-WtgDependencyText $Context 'Windows will request administrator permission for C++ build tools.' 'Windows запросит права администратора для инструментов C++.')
                $argumentLine=@($arguments|ForEach-Object {ConvertTo-WtgArgument $_}) -join ' '
                $process=Start-Process -FilePath $Archive -ArgumentList $argumentLine -Verb RunAs -WindowStyle Hidden -PassThru
                try {if (-not $process.WaitForExit(3600000)) {throw 'Build-tools setup has not finished. Inspect Windows Installer before retrying.'};$exitCode=$process.ExitCode} finally {$process.Dispose()}
            } else {$r=Invoke-WtgProcess $Archive $arguments -TimeoutSeconds 3600 -KeepOnTimeout -LogPath $log -AllowedExitCodes @(0,3010);$exitCode=$r.ExitCode}
            if ($exitCode -eq 3010) {Set-WtgDependencyRestartReceipt $Context $Package $Destination};if ($exitCode -ne 0) {throw ('Build-tools setup failed with exit '+$exitCode+'.')}
        }
        default {throw 'Unknown dependency extraction method.'}
    }
    Write-WtgJson -Path (Join-Path $Destination '.wtg-dependency.json') -Value @{Id=$Package.id;Version=$Package.version;Sha256=$Package.sha256;State='Installed';CompletedUTC=[DateTime]::UtcNow.ToString('o')}
}
function Initialize-WtgDependenciesInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[switch]$ForInstaller)
    $catalog=Get-WtgDependencyCatalog;$tools=Get-WtgExistingTools $Context -ForInstaller:$ForInstaller
    $packages=@($catalog.packages|Where-Object { $_.group -ne 'Installer' -or $ForInstaller })
    $downloadTotal=0L;$expandedTotal=0L
    foreach($p in $packages){if(-not(Test-Path -LiteralPath (Get-WtgDependencyCachePath $Context $p))) {$downloadTotal+=$p.downloadBytes};if($p.PSObject.Properties['additionalDownloadBytes']){$downloadTotal+=$p.additionalDownloadBytes};$expandedTotal+=$p.expandedBytes}
    Write-Host (Get-WtgDependencyText $Context ('Dependency upper estimate: '+[Math]::Round($downloadTotal/1GB,1)+' GiB downloads and '+[Math]::Round($expandedTotal/1GB,1)+' GiB extracted. Existing compatible tools are reused.') ('Верхняя оценка: загрузки '+[Math]::Round($downloadTotal/1GB,1)+' ГиБ, распаковка '+[Math]::Round($expandedTotal/1GB,1)+' ГиБ. Совместимые инструменты используются повторно.'))
    if (-not $Context.AcceptLicenses) {
        foreach($p in $packages|Group-Object license|ForEach-Object{$_.Group[0]}) {Write-Host ($p.license+': '+$p.page)}
        if ($Context.NonInteractive) {throw 'Dependency licenses require explicit acceptance. Review dependencies.json and supply -AcceptLicenses.'}
        $answer=Read-Host (Get-WtgDependencyText $Context 'Accept these dependency licenses and prepare missing tools? [y/N]' 'Принять лицензии зависимостей и подготовить недостающие инструменты? [y/N]')
        if ($answer -notmatch '^(?i:y|yes|д|да)$') {throw 'Cancelled.'}
    }
    $toolRoot=Join-Path $Context.CacheDir 'tools';$null=[IO.Directory]::CreateDirectory($toolRoot)
    foreach($id in @('Git','CMake','Ninja','SevenZip','PythonBase','MSVC','FFmpeg','Makensis')) {
        if ($id -eq 'Makensis' -and -not $ForInstaller) {continue}
        $key=$id;if($id -eq 'PythonBase'){$key='Python'};if($id -eq 'MSVC'){$key='VsDevCmd'}
        $p=$packages|Where-Object id -eq $id;$destination=Join-Path $toolRoot ($id+'-'+$p.version)
        $expected=Join-Path $destination $p.relativePath
        $cachedTool=Get-WtgCachedDependencyTool $Context $p $destination $key
        if(-not $tools[$key] -and $cachedTool){$tools[$key]=$cachedTool}
        if ($tools[$key]) {continue}
        $archive=Save-WtgDependencyFile $Context $p;Install-WtgCachedDependency $Context $p $archive $destination $tools
        $tools[$key]=Get-WtgCachedDependencyTool $Context $p $destination $key
    }
    if (-not $tools['QtRoot']) {
        $destination=Join-Path $toolRoot 'Qt-6.12.0';$expected=Join-Path $destination '6.12.0\msvc2022_64';$receipt=Join-Path $destination '.wtg-dependency.json'
        $null=Resolve-WtgSafeDirectory -Path $destination -AllowExisting
        if (-not(Test-Path $receipt)) {
            if (Test-Path $destination) {throw 'Qt extraction is incomplete. Inspect it or choose a new cache before retrying.'}
            $null=[IO.Directory]::CreateDirectory($destination)
            foreach($p in $packages|Where-Object group -eq Qt) {
                $archive=Save-WtgDependencyFile $Context $p;Assert-WtgDependencySpace $destination ([long]$p.expandedBytes+64MB)
                $null=Invoke-WtgProcess $tools.SevenZip @('x',$archive,('-o'+$destination),'-y','-bso0','-bsp0') -TimeoutSeconds 600 -LogPath (Join-Path $Context.RunDir ($p.id+'.log'))
            }
            # Qt online installers normally write this relocation configuration.
            $conf=Join-Path $expected 'bin\qt.conf';[IO.File]::WriteAllText($conf,"[Paths]`r`nPrefix=..`r`n",[Text.Encoding]::ASCII)
            Write-WtgJson $receipt @{Profile=$catalog.profile;CompletedUTC=[DateTime]::UtcNow.ToString('o')}
        }
        if (-not(Test-WtgExistingTool QtRoot $expected)) {throw 'Qt is incomplete or does not match 6.12.0 MSVC 2022 x64.'};$tools.QtRoot=$expected
    }
    if (-not $tools['GStreamerRoot']) {
        $destination=Join-Path $toolRoot 'GStreamer-1.26.11';$expected=Join-Path $destination 'PFiles64\gstreamer\1.0\msvc_x86_64';$receipt=Join-Path $destination '.wtg-dependency.json'
        $null=Resolve-WtgSafeDirectory -Path $destination -AllowExisting
        if (-not(Test-Path $receipt)) {
            if(Test-Path $destination){throw 'GStreamer extraction is incomplete. Inspect it or choose a new cache before retrying.'}
            $null=[IO.Directory]::CreateDirectory($destination)
            foreach($p in $packages|Where-Object group -eq GStreamer) {
                $archive=Save-WtgDependencyFile $Context $p;Assert-WtgDependencySpace $destination ([long]$p.expandedBytes+64MB)
                $null=Invoke-WtgProcess (Join-Path $env:SystemRoot 'System32\msiexec.exe') @('/a',$archive,'/qn','/norestart',('TARGETDIR='+$destination),'/L*v',(Join-Path $Context.RunDir ($p.id+'-msi.log'))) -TimeoutSeconds 1200 -AllowedExitCodes @(0)
            }
            Write-WtgJson $receipt @{Profile=$catalog.profile;CompletedUTC=[DateTime]::UtcNow.ToString('o')}
        }
        if(-not(Test-WtgExistingTool GStreamerRoot $expected)){throw 'GStreamer runtime/development extraction did not pass verification.'};$tools.GStreamerRoot=$expected
    }
    if(-not $tools['PkgConfig']){$tools.PkgConfig=Join-Path $tools.GStreamerRoot 'bin\pkg-config.exe'}
    if(-not(Test-WtgExistingTool PkgConfig $tools.PkgConfig)){throw 'The GStreamer SDK pkg-config tool is missing or cannot run.'}
    if(-not $tools['VCRedist']) {
        $vsRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($tools.VsDevCmd)) '..\..'))
        $redist=Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Redist\MSVC') -Filter vc_redist.x64.exe -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if($redist -and (Test-WtgExistingTool VCRedist $redist.FullName)) {$tools.VCRedist=$redist.FullName}
        else {throw 'The Microsoft Visual C++ x64 redistributable installer is required for the offline bundle. Add the VC Redistributable component to Visual Studio or supply Tools.VCRedist. https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist'}
    }
    # Separate environment: never pip-install into an existing user Python.
    $venv=Join-Path $Context.RunDir 'python-build';$python=Join-Path $venv 'Scripts\python.exe'
    if(Test-Path $venv){throw 'The build Python directory already exists. Use a new run directory.'}
    $null=Invoke-WtgProcess $tools.Python @('-I','-m','venv',$venv) -TimeoutSeconds 180 -LogPath (Join-Path $Context.RunDir 'python-venv.log')
    $wheelFiles=@();foreach($p in $packages|Where-Object group -eq PythonWheels){$wheelFiles+=Save-WtgDependencyFile $Context $p}
    # pip requires wheel basenames, whereas cache files are content-addressed.
    $wheelDir=Join-Path $Context.RunDir 'wheels';$null=[IO.Directory]::CreateDirectory($wheelDir);$args=@('-I','-m','pip','install','--isolated','--disable-pip-version-check','--no-index','--no-deps')
    foreach($p in $packages|Where-Object group -eq PythonWheels){$target=Join-Path $wheelDir $p.relativePath;Copy-Item -LiteralPath (Get-WtgDependencyCachePath $Context $p) -Destination $target;$args+=$target}
    $null=Invoke-WtgProcess $python $args -TimeoutSeconds 300 -LogPath (Join-Path $Context.RunDir 'python-wheels.log')
    $r=Invoke-WtgProcess $python @('-I','-c','import PyInstaller, pefile, struct; assert PyInstaller.__version__ == "6.16.0"; assert struct.calcsize("P") == 8; print("verified")') -TimeoutSeconds 30 -LogPath (Join-Path $Context.RunDir 'python-check.log')
    $tools.Python=$python
    $Context.Tools=$tools
    Write-WtgJson (Join-Path $Context.RunDir 'dependencies-result.json') @{Profile=$catalog.profile;Tools=$tools;Packages=@($packages|Select-Object id,version,sha256);Validation='Tools detected and pinned packages verified; clean-machine installation remains separately tested.'}
    return $tools
}
function Initialize-WtgDependencies {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[switch]$ForInstaller)
    $null=Resolve-WtgSafeDirectory -Path $Context.CacheDir -AllowExisting
    $null=[IO.Directory]::CreateDirectory($Context.CacheDir)
    $lock=$null
    try {
        try {$lock=New-Object IO.FileStream((Join-Path $Context.CacheDir 'dependencies.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch {throw (Get-WtgDependencyText $Context 'Another dependency preparation is using this cache. Wait for it to finish.' 'Другая подготовка зависимостей использует этот кэш. Дождитесь завершения.')}
        return (Initialize-WtgDependenciesInternal $Context -ForInstaller:$ForInstaller)
    } catch {
        if ($_.Exception.Data.Contains('WtgRestartRequired') -and $_.Exception.Data['WtgRestartRequired'] -eq $true) {throw}
        if ($Context.Language -ne 'ru' -or $_.Exception.Message -match '[А-Яа-яЁё]') {throw}
        $reason=$_.Exception.Message
        $message='Подготовка зависимостей не завершена. Проверьте запись диагностики и повторите запуск после устранения причины.'
        switch -Regex ($reason) {
            'Cancelled' {$message='Отменено. Подготовленные файлы сохранены.';break}
            'WtgRestartRequired' {$message='WtgRestartRequired: Установщик требует перезапуска Windows. Перезапустите компьютер самостоятельно и повторите запуск.';break}
            'license' {$message='Сначала ознакомьтесь с лицензиями в dependencies.json. Для автоматического запуска укажите -AcceptLicenses.';break}
            'integrity|SHA-256|publisher signature' {$message='Проверка файла или издателя не пройдена. Получите точный пакет по официальной ссылке; проверка не может быть отключена.';break}
            'insufficient space' {$message='Недостаточно места для файлов зависимости. Освободите место или выберите другой кэш и повторите запуск.';break}
            'Visual Studio requires elevation' {$message='Для инструментов C++ нужны права администратора. Установите их официальным установщиком от имени администратора и повторите запуск.';break}
            'offline layout' {$message='Для C++ нужен полный автономный пакет Visual Studio. Установите его вручную и укажите Tools.VsDevCmd.';break}
            'incomplete|already exists' {$message='Обнаружена незавершённая подготовка. Проверьте сохранённый результат либо выберите новый кэш; повторная установка поверх незавершённой не выполняется.';break}
            'redistributable' {$message='Для автономного установщика нужен пакет Microsoft Visual C++ x64. Добавьте VC Redistributable в Visual Studio или укажите Tools.VCRedist. https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist';break}
        }
        $exception=New-Object InvalidOperationException($message,$_.Exception)
        throw $exception
    } finally {if($lock){$lock.Dispose()}}
}
Export-ModuleMember -Function Get-WtgDependencyCatalog,Get-WtgExistingTools,Initialize-WtgDependencies,Save-WtgDependencyFile,Assert-WtgDependencyFile,Expand-WtgDependencyZip,Get-WtgDependencyCachePath,Test-WtgExistingTool
