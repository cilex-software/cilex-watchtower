function Get-OfficeLauncherContext {
    $env:PSModulePath = (Join-Path $PSHOME 'Modules') + [IO.Path]::PathSeparator + (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules');
    Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop;
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent();
    $principal = New-Object Security.Principal.WindowsPrincipal $identity;
    $policies = Microsoft.PowerShell.Security\Get-ExecutionPolicy -List;
    return [pscustomobject]@{
        HostName = [Environment]::MachineName;
        Administrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);
        Interactive = [Environment]::UserInteractive;
        Session = [Diagnostics.Process]::GetCurrentProcess().SessionId;
        Policy = [string](Microsoft.PowerShell.Security\Get-ExecutionPolicy);
        Managed = @($policies | Where-Object { $_.Scope -in @('MachinePolicy','UserPolicy') -and $_.ExecutionPolicy -ne 'Undefined' }).Count -gt 0;
    };
};
function Get-OfficeLauncherHash {
    param([string]$Path);
    $stream = [IO.File]::OpenRead($Path);
    $sha = [Security.Cryptography.SHA256]::Create();
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-',''); }
    finally { $sha.Dispose(); $stream.Dispose(); };
};
function Test-OfficeLauncherFiles {
    param([string]$Root, [string[]]$Pins);
    $relative = @('Update-Office.ps1','update-local-package.ps1','package\manifest.json');
    for ($i = 0; $i -lt $relative.Count; $i++) {
        $path = Join-Path $Root $relative[$i];
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'A required update file is missing. Extract the complete package again.' };
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'An update file is redirected. Extract a fresh package into a normal folder.' };
        if ((Get-OfficeLauncherHash $path) -ne $Pins[$i]) { throw 'An update file has changed. Download and extract the approved package again.' };
    };
};
function Read-OfficeLauncherConsent {
    Write-Host 'Windows currently blocks PowerShell script files.';
    Write-Host 'This update can allow its verified scripts in one temporary process only.';
    Write-Host 'Saved Windows security settings will stay unchanged.';
    Write-Host 'Watchtower will close briefly. Continue only if the normal camera wall is already showing.';
    $answer = Read-Host 'Allow this one update? Type YES to continue; anything else cancels';
    return $answer -in @('YES','Y','1');
};
function Invoke-OfficeLauncherChild {
    param([string]$Entry, [bool]$TemporaryException);
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';
    if ($TemporaryException) { & $powershell -NoProfile -ExecutionPolicy Bypass -File $Entry | Out-Host; }
    else { & $powershell -NoProfile -File $Entry | Out-Host; };
    return [int]$LASTEXITCODE;
};
function Start-OfficePackageUpdate {
    param([string]$Root, [string[]]$Pins);
    try {
        if (-not $Root -or $Pins.Count -ne 3) { throw 'The update launcher is incomplete. Download the approved package again.' };
        $Root = [IO.Path]::GetFullPath($Root);
        if ($Root.StartsWith('\\')) { throw 'Copy and extract the package onto Office before running the update.' };
        Test-OfficeLauncherFiles $Root $Pins;
        $context = Get-OfficeLauncherContext;
        if ($context.HostName -ne 'WT-OFFICE-01') { throw 'This package updates WT-OFFICE-01 only.' };
        if (-not $context.Administrator -or -not $context.Interactive -or $context.Session -le 0) { throw 'Sign into Office normally and open PowerShell as administrator.' };
        $exception = $context.Policy -eq 'Restricted';
        if ($exception -and $context.Managed) { throw 'An organization policy blocks this update. Ask its administrator; no exception was applied.' };
        if ($exception -and -not (Read-OfficeLauncherConsent)) { Write-Host 'Update cancelled. Applications and saved settings were not changed.'; return 2; };
        Test-OfficeLauncherFiles $Root $Pins;
        $code = Invoke-OfficeLauncherChild (Join-Path $Root 'Update-Office.ps1') $exception;
        if ($code -ne 0) { Write-Host 'Update did not complete. Send the completion message to the deployment operator.'; };
        return [int]$code;
    } catch { Write-Host ('Update stopped: ' + $_.Exception.Message); return 1; };
};
exit (Start-OfficePackageUpdate $env:CILEX_OFFICE_UPDATE_ROOT @('__ENTRY_SHA256__','__WRAPPER_SHA256__','__MANIFEST_SHA256__'));
