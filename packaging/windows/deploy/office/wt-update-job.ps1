# wt-update-job.ps1 - one-shot job run as SYSTEM on wt-office-01 via a temporary service.
# Swaps watchtower.exe AND warden\warden.exe for the versions staged in
# C:\Users\Public\Downloads\wt-stage\, restarts Warden through its own task, verifies by
# PARENTAGE, and ROLLS BACK by itself if the new version does not come up supervised
# (an unattended wall must not be left dark by a build Windows refuses).
# STRICTLY ASCII: the profile there is Cyrillic, so every path is discovered at run time.
$ErrorActionPreference = 'Continue'
$log = 'C:\Users\Public\Downloads\wt-update.log'
function L($m) { ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) | Out-File -FilePath $log -Append -Encoding utf8 }
L "=== start, running as $(whoami) ==="

$stage     = 'C:\Users\Public\Downloads\wt-stage'
$newExe    = Join-Path $stage 'watchtower.exe'
$newWarden = Join-Path $stage 'warden.exe'
if (-not (Test-Path $newExe) -or -not (Test-Path $newWarden)) { L "ABORT: staged files missing in $stage"; exit 1 }

$inst = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'AppData\Local\Programs\Cilex Watchtower' } |
        Where-Object { Test-Path (Join-Path $_ 'watchtower.exe') } | Select-Object -First 1
if (-not $inst) { L "ABORT: no Watchtower install found under C:\Users"; exit 1 }
$exe    = Join-Path $inst 'watchtower.exe'
$wd     = Join-Path $inst 'warden\warden.exe'
$oldVer = (Get-Item $exe).VersionInfo.FileVersion
$newVer = (Get-Item $newExe).VersionInfo.FileVersion
L "install: $inst"
L "app: $oldVer -> $newVer"
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bkExe = "$exe.$oldVer.bak"
$bkWd  = "$wd.$stamp.bak"

function Wait-Supervised($label) {
    # Poll up to 45 s: a single early look could roll back a build that was merely slow.
    for ($i = 0; $i -lt 9; $i++) {
        Start-Sleep -Seconds 5
        $w = @(Get-Process -Name warden -ErrorAction SilentlyContinue)
        $a = @(Get-Process -Name watchtower -ErrorAction SilentlyContinue)
        foreach ($p in $a) {
            $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue
            if ($ci -and ($w.Id -contains $ci.ParentProcessId)) {
                L ("  ($label) after {0} s: warden procs {1}, app pid {2} parent {3} supervised, version {4}" -f (5 * ($i + 1)), $w.Count, $p.Id, $ci.ParentProcessId, (Get-Item $ci.ExecutablePath).VersionInfo.FileVersion)
                return $true
            }
        }
    }
    $w = @(Get-Process -Name warden -ErrorAction SilentlyContinue)
    $a = @(Get-Process -Name watchtower -ErrorAction SilentlyContinue)
    L ("  ($label) after 45 s: warden procs {0}, app procs {1}, none supervised" -f $w.Count, $a.Count)
    return $false
}

# 1. Stop the supervisor FIRST (it would respawn the app mid-swap), then the app.
#    Start-ScheduledTask/schtasks /run is a NO-OP while an instance runs, so this is
#    also what makes the restart below actually start the NEW warden.
taskkill /F /IM warden.exe /T 2>&1 | ForEach-Object { L "taskkill warden : $_" }
Start-Sleep -Seconds 2
taskkill /F /IM watchtower.exe /T 2>&1 | ForEach-Object { L "taskkill app    : $_" }
Start-Sleep -Seconds 3

# 2. Back up, then swap both binaries.
Copy-Item $exe $bkExe -Force
Copy-Item $wd  $bkWd  -Force
L "backups: $bkExe ; $bkWd"
Copy-Item $newExe    $exe -Force
Copy-Item $newWarden $wd  -Force
L ("swapped: app file version {0}, warden.exe {1} bytes" -f (Get-Item $exe).VersionInfo.FileVersion, (Get-Item $wd).Length)

# 3. Restart through the user's own task (the app must come up in THAT session).
schtasks /run /tn wt-warden 2>&1 | ForEach-Object { L "schtasks run   : $_" }
if (Wait-Supervised 'new') { L "=== done: $newVer running, supervised ==="; exit 0 }

# 4. ROLL BACK.
L "!!! $newVer did NOT come up supervised -- rolling back to $oldVer"
taskkill /F /IM warden.exe /T 2>&1 | ForEach-Object { L "taskkill warden : $_" }
taskkill /F /IM watchtower.exe /T 2>&1 | ForEach-Object { L "taskkill app    : $_" }
Start-Sleep -Seconds 3
Copy-Item $bkExe $exe -Force
Copy-Item $bkWd  $wd  -Force
L ("restored: app file version {0}" -f (Get-Item $exe).VersionInfo.FileVersion)
schtasks /run /tn wt-warden 2>&1 | ForEach-Object { L "schtasks run   : $_" }
if (Wait-Supervised 'rollback') { L "=== done: ROLLED BACK to $oldVer, supervised ===" }
else { L "=== FAILED: nothing supervised even after rollback ===" }
