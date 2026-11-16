# Build warden.exe (CW-16) — a single self-contained PyInstaller binary, so guard
# boxes need no Python. Called by CI (windows.yml) after the app build; output
# lands in the deploy dist so both the portable zip and the NSIS installer pick
# it up wholesale (installer.nsi does File /r on the dist).
#   pwsh packaging/windows/build-warden.ps1 -Dist build-windows/dist
param([string]$Dist = "build-windows/dist",
      [ValidateSet('Yes','No')][string]$UpdateSource='Yes',
      [ValidateSet('Ask','Yes','No')][string]$Rebuild='Ask')
$ErrorActionPreference = "Stop"
$Dist=[IO.Path]::GetFullPath($Dist)
Import-Module (Join-Path $PSScriptRoot 'BuildState.psm1')
$repository=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$plan=Start-CilexBuild -Repository $repository -BuildProfile 'windows-warden' -Update $UpdateSource -Rebuild $Rebuild -ExistingBinary (Join-Path $Dist 'warden/warden.exe')
if(-not $plan.build){
    $runtime=@($plan.existing.outputs|Where-Object {$_.role -eq 'runtime'})[0].path
    $target=Join-Path $Dist 'warden'
    if([IO.Path]::GetFullPath($runtime) -ne [IO.Path]::GetFullPath($target)){
        $null=New-Item -ItemType Directory -Path $target -Force
        Get-ChildItem -LiteralPath $runtime -Force|Copy-Item -Destination $target -Recurse -Force
        Write-Host ('Existing Warden copied without recompiling. Binary: '+(Join-Path $target 'warden.exe'))
    }
    [IO.File]::Delete($plan.PlanPath);return
}
Set-Location $plan.source

python -m pip install --quiet --disable-pip-version-check pyinstaller
if($LASTEXITCODE -ne 0){throw 'PyInstaller preparation failed.'}
python -m PyInstaller --onefile --noconfirm --clean --log-level WARN `
    --name warden --distpath "$Dist\warden" --workpath build-windows\pyi `
    --specpath build-windows\pyi warden\warden.py
if($LASTEXITCODE -ne 0){throw 'Warden compilation failed.'}
if (-not (Test-Path "$Dist\warden\warden.exe")) { throw "warden.exe missing after PyInstaller" }

# The station-side install script + config reference travel with the exe.
Copy-Item warden\install-windows.ps1   "$Dist\warden\"
Copy-Item warden\warden.conf.example   "$Dist\warden\"
Write-Host "warden.exe + install script staged into $Dist\warden"
Complete-CilexBuild -Plan $plan -Outputs @{binary=(Join-Path $Dist 'warden/warden.exe');runtime=(Join-Path $Dist 'warden')}
