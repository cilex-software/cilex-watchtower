#requires -Version 5.1
<#
.SYNOPSIS
Creates the readable, package-pinned Office CMD launcher after packaging finishes.
.DESCRIPTION
The launcher verifies its entry point, wrapper and manifest before running any
update code. Only an unmanaged Restricted execution policy offers a local,
explicitly approved exception in the child process. Other policies are honored.
Saved policies, account settings, services and applications are never changed by
this factory. Include the generated CMD beside the two pinned PS1 files.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DistributionPath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$EntrySha256,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$WrapperSha256,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ManifestSha256
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = [IO.Path]::GetFullPath($DistributionPath)
if ($root.StartsWith('\\') -or -not (Test-Path -LiteralPath $root -PathType Container)) {
    throw 'A local, existing distribution folder is required.'
}
$pins = @($EntrySha256.ToUpperInvariant(),$WrapperSha256.ToUpperInvariant(),$ManifestSha256.ToUpperInvariant())
$relative = @('Update-Office.ps1','update-local-package.ps1','package\manifest.json')
for ($i=0; $i -lt $relative.Count; $i++) {
    $path = Join-Path $root $relative[$i]
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $pins[$i]) {
        throw ('Finalized package pin does not match: '+$relative[$i])
    }
}
$gate = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'office-launcher-gate.ps1'))
$gate = $gate.Replace('__ENTRY_SHA256__',$pins[0]).Replace('__WRAPPER_SHA256__',$pins[1]).Replace('__MANIFEST_SHA256__',$pins[2])
$command = ($gate -split '\r?\n' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) -join ' '
if ($command -match '["%\r\n]' -or $command -match '[^\x20-\x7E]' -or $command.Length -gt 7400) {
    throw 'Launcher gate is not safe for a readable CMD command line.'
}
$tokens=$null; $errors=$null
$null = [Management.Automation.Language.Parser]::ParseInput($command,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Launcher gate syntax did not parse.' }
$lines = @(
    '@echo off',
    'setlocal DisableDelayedExpansion',
    'set "CILEX_OFFICE_UPDATE_ROOT=%~dp0"',
    ('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "'+$command+'"'),
    'exit /b %ERRORLEVEL%'
)
$destination = Join-Path $root 'Update-Office.cmd'
[IO.File]::WriteAllText($destination,($lines -join "`r`n")+"`r`n",[Text.Encoding]::ASCII)
Write-Output $destination
