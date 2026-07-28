# Build warden.exe (CW-16) — a single self-contained PyInstaller binary, so guard
# boxes need no Python. Called by CI (windows.yml) after the app build; output
# lands in the deploy dist so both the portable zip and the NSIS installer pick
# it up wholesale (installer.nsi does File /r on the dist).
#   pwsh packaging/windows/build-warden.ps1 -Dist build-windows/dist
param([string]$Dist = "build-windows/dist")
$ErrorActionPreference = "Stop"

python -m pip install --quiet --disable-pip-version-check pyinstaller
python -m PyInstaller --onefile --noconfirm --clean --log-level WARN `
    --name warden --distpath "$Dist\warden" --workpath build-windows\pyi `
    --specpath build-windows\pyi warden\warden.py
if (-not (Test-Path "$Dist\warden\warden.exe")) { throw "warden.exe missing after PyInstaller" }

# The station-side install script + config reference travel with the exe.
Copy-Item warden\install-windows.ps1   "$Dist\warden\"
Copy-Item warden\warden.conf.example   "$Dist\warden\"
Write-Host "warden.exe + install script staged into $Dist\warden"
