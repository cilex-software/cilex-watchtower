# Offline NSIS entry: no downloads, no repository access, no developer tools.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackagePath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedManifestSha256,
    [string]$InstallDir, [string]$TargetUser, [string]$StartupMode,
    [string]$InstallScope, [string]$Language, [string]$ExtractOnly,
    [string]$Silent='False', [string]$ResultPath, [string]$BackendUrl,
    [string]$OverrideRequirements='', [string]$ConsentUnattended='False',
    [string]$AutologonPath='', [string]$UseTargetDefault='False'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if([Console]::IsOutputRedirected){[Console]::OutputEncoding=New-Object Text.UTF8Encoding $false}
# An installer launched from PowerShell 7 may inherit that engine's module
# search path. Use the native Windows PowerShell modules for this process only.
$env:PSModulePath=(Join-Path $PSHOME 'Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
try {
    $package = [IO.Path]::GetFullPath($PackagePath).TrimEnd('\')
    $manifestPath = Join-Path $package 'manifest.json'
    if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $ExpectedManifestSha256) { throw 'The installation package failed its integrity check.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # Helpers are executable code: validate every helper before importing it.
    $seen = @{}
    foreach ($helper in @($manifest.helpers)) {
        $relative = [string]$helper.path
        if (-not $relative -or $relative -match '(^[\\/]|[:\\]|(^|/)\.\.?(/|$)|[\x00-\x1f])' -or $seen.ContainsKey($relative.ToLowerInvariant())) { throw 'Invalid helper path.' }
        $seen[$relative.ToLowerInvariant()]=$true
        $path = Join-Path (Join-Path $package 'helpers') $relative
        if ((Get-Item -LiteralPath $path).Length -ne [long]$helper.size -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $helper.sha256) { throw 'The installation helper failed its integrity check.' }
    }
    foreach ($name in @('Common.psm1','Install.psm1','install-target.ps1','installer-entry.ps1')) { if (-not $seen.ContainsKey($name.ToLowerInvariant())) { throw 'Required installation helper is absent.' } }
    if ($ExtractOnly) {
        if (-not [IO.Path]::IsPathRooted($ExtractOnly) -or $ExtractOnly.StartsWith('\\')) { throw 'Extraction needs a new absolute local directory.' }
        $destination=[IO.Path]::GetFullPath($ExtractOnly).TrimEnd('\')
        if (Test-Path -LiteralPath $destination) { throw 'Extraction destination already exists; choose a new directory.' }
        $parent=Split-Path -Parent $destination
        while ($parent) {
            if ((Test-Path -LiteralPath $parent) -and ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Extraction through a linked directory is not supported.' }
            $next=Split-Path -Parent $parent
            if ($next -eq $parent) { break }; $parent=$next
        }
        $null=[IO.Directory]::CreateDirectory($destination)
        foreach ($file in Get-ChildItem -LiteralPath $package -File -Recurse -Force) {
            $relative=$file.FullName.Substring($package.Length+1)
            $target=Join-Path $destination $relative
            $null=[IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            [IO.File]::Copy($file.FullName,$target,$false)
            if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) { throw 'Extraction verification failed.' }
        }
        exit 0
    }
    if (-not $Language) {
        $Language=if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ru') {'ru'} else {'en'}
    }
    if ($Language -notin @('en','ru')) { throw 'Invalid language selection.' }
    if ($ConsentUnattended -notin @('True','False') -or $UseTargetDefault -notin @('True','False')) { throw 'Invalid installation choice.' }
    $acceptedFindings=@()
    if ($OverrideRequirements) {
        if ($OverrideRequirements -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*(,[A-Za-z0-9][A-Za-z0-9_.-]*)*$') { throw 'Use explicit comma-separated finding IDs.' }
        $acceptedFindings=@($OverrideRequirements.Split(',') | Select-Object -Unique)
    }
    if ($UseTargetDefault -eq 'True') { $InstallDir='' }
    if (-not $StartupMode) {
        if ($Silent -eq 'True') { throw 'A startup mode is required for silent installation.' }
        $prompt=if ($Language -eq 'ru') {'Автозапуск: 1 — после входа в Windows; 2 — без участия пользователя после перезагрузки. Выберите 1 или 2'} else {'Startup: 1 = after Windows sign-in; 2 = unattended after reboot. Choose 1 or 2'}
        $answer=Read-Host $prompt
        switch ($answer) { '1' {$StartupMode='AfterSignIn'} '2' {$StartupMode='UnattendedReboot'} default { throw 'Startup choice was not supplied.' } }
    }
    if ($StartupMode -notin @('AfterSignIn','UnattendedReboot')) { throw 'Invalid startup choice.' }
    if (-not $InstallScope) { $InstallScope='User' }
    if (-not $BackendUrl -and $Silent -ne 'True') {
        $prompt=if ($Language -eq 'ru') {'Адрес сервера или пустая строка для настройки позже'} else {'Backend address, or leave empty to configure later'}
        $BackendUrl=Read-Host $prompt
    }
    $arguments=@{PackagePath=$package;ExpectedManifestSha256=$ExpectedManifestSha256}
    foreach ($name in @('InstallDir','TargetUser','StartupMode','InstallScope','Language','ResultPath','BackendUrl','AutologonPath')) {
        $value=Get-Variable -Name $name -ValueOnly
        if ($value) { $arguments[$name]=$value }
    }
    if ($Silent -eq 'True') { $arguments.NonInteractive=$true }
    if ($acceptedFindings.Count -gt 0) { $arguments.OverrideRequirements=$acceptedFindings }
    if ($ConsentUnattended -eq 'True') { $arguments.ConsentUnattended=$true }
    & (Join-Path $PSScriptRoot 'install-target.ps1') @arguments
    if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
    exit 0
} catch {
    # Avoid an exception dump which can expose caller arguments.
    if ($Language -eq 'ru' -or (-not $Language -and [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ru')) {
        Write-Host 'Установка не завершена. Проверьте пакет и папку установки; используйте журнал результата для диагностики.'
    } else { Write-Host 'Installation did not complete. Check the package and destination; use the result log for details.' }
    exit 1
}
