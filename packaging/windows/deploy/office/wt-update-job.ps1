# wt-update-job.ps1 - one-shot job run as SYSTEM on wt-office-01 via a temporary service.
# Swaps watchtower.exe -- and warden\warden.exe ONLY if one is staged -- for the versions
# in C:\Users\Public\Downloads\wt-stage\, restarts Warden through its own task, verifies by
# PARENTAGE, and ROLLS BACK by itself if the new version does not come up supervised
# (an unattended wall must not be left dark by a build Windows refuses).
#
# 0. PROBE FIRST (2026-09-28): Smart App Control judges an unsigned exe by its hash, per
#    machine, and it went into a blocking phase on the booth that morning (12 fresh builds
#    refused in a row). So before touching the wall, the job starts the new exe from a
#    HARDLINKED copy of this install -- the same DLL files, so only the exe is new -- here in
#    the job's own session 0, which no one can see, and kills it. Refused at CreateProcess ->
#    ABORT with the wall untouched. The rollback below stays as the second net.
# Swap only what changed: Warden is PyInstaller-built and never byte-identical between
# builds, so re-shipping an unchanged Warden only adds a second new unsigned binary for SAC
# to judge. Leave warden.exe out of wt-stage unless Warden's source changed.
# STRICTLY ASCII: the profile there is Cyrillic, so every path is discovered at run time.
$ErrorActionPreference = 'Continue'
$log = 'C:\Users\Public\Downloads\wt-update.log'
function L($m) { ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) | Out-File -FilePath $log -Append -Encoding utf8 }
L "=== start, running as $(whoami) ==="

$stage     = 'C:\Users\Public\Downloads\wt-stage'
$newExe    = Join-Path $stage 'watchtower.exe'
$newWarden = Join-Path $stage 'warden.exe'
if (-not (Test-Path $newExe)) { L "ABORT: no watchtower.exe staged in $stage"; exit 1 }
$swapWarden = Test-Path $newWarden

$inst = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'AppData\Local\Programs\Cilex Watchtower' } |
        Where-Object { Test-Path (Join-Path $_ 'watchtower.exe') } | Select-Object -First 1
if (-not $inst) { L "ABORT: no Watchtower install found under C:\Users"; exit 1 }
$exe    = Join-Path $inst 'watchtower.exe'
$wd     = Join-Path $inst 'warden\warden.exe'
$oldVer = (Get-Item $exe).VersionInfo.FileVersion
$newVer = (Get-Item $newExe).VersionInfo.FileVersion
L "install: $inst"
L ("app: {0} -> {1}; warden: {2}" -f $oldVer, $newVer, $(if ($swapWarden) { 'swap the staged warden.exe' } else { 'unchanged (none staged)' }))
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bkExe = "$exe.$oldVer.bak"
$bkWd  = "$wd.$stamp.bak"

# 0. PROBE: will Windows run THIS exe on THIS machine?
$pf = 'C:\Users\Public\Downloads\wt-pf'
if (Test-Path $pf) { Remove-Item $pf -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $pf -Force | Out-Null
$n = 0
Get-ChildItem $inst -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -ne 'watchtower.exe' -and $_.Extension -ne '.bak' -and $_.FullName -notlike '*\warden\*' } |
  ForEach-Object {
    $dst = Join-Path $pf $_.FullName.Substring($inst.Length).TrimStart('\')
    $dir = Split-Path $dst
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    New-Item -ItemType HardLink -Path $dst -Target $_.FullName -ErrorAction SilentlyContinue | Out-Null
    $n++
  }
Copy-Item $newExe (Join-Path $pf 'watchtower.exe') -Force
L "probe: $n runtime files hardlinked into $pf; the new exe copied beside them"
$env:WT_FLIGHTREC_DIR = Join-Path $pf 'flightrec'
$blocked = $null
try {
    $pp = Start-Process -FilePath (Join-Path $pf 'watchtower.exe') -PassThru -ErrorAction Stop
    Start-Sleep -Seconds 8
    if ($pp.HasExited) { L ("probe: ALLOWED to start; it exited within 8 s, code {0} (a session-0 instance may do that -- the rollback still guards the swap)" -f $pp.ExitCode) }
    else { L "probe: ALLOWED -- pid $($pp.Id) running after 8 s; stopping it"; Stop-Process -Id $pp.Id -Force -ErrorAction SilentlyContinue }
} catch {
    $blocked = $_.Exception.Message
}
Start-Sleep -Seconds 2
Remove-Item $pf -Recurse -Force -ErrorAction SilentlyContinue     # links only; the install is untouched
Remove-Item Env:\WT_FLIGHTREC_DIR -ErrorAction SilentlyContinue
if ($blocked) {
    L "probe: BLOCKED at CreateProcess -- $blocked"
    L "=== ABORT: Windows will not run $newVer here; the wall was NOT touched ==="
    exit 2
}

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
#    also what makes the restart below actually start Warden afresh.
taskkill /F /IM warden.exe /T 2>&1 | ForEach-Object { L "taskkill warden : $_" }
Start-Sleep -Seconds 2
taskkill /F /IM watchtower.exe /T 2>&1 | ForEach-Object { L "taskkill app    : $_" }
Start-Sleep -Seconds 3

# 2. Back up, then swap what was staged.
Copy-Item $exe $bkExe -Force
if ($swapWarden) { Copy-Item $wd $bkWd -Force }
L ("backups: {0}{1}" -f $bkExe, $(if ($swapWarden) { " ; $bkWd" } else { '' }))
Copy-Item $newExe $exe -Force
if ($swapWarden) { Copy-Item $newWarden $wd -Force }
L ("swapped: app file version {0}{1}" -f (Get-Item $exe).VersionInfo.FileVersion, $(if ($swapWarden) { ", warden.exe $((Get-Item $wd).Length) bytes" } else { '' }))

# 3. Restart through the user's own task (the app must come up in THAT session).
schtasks /run /tn wt-warden 2>&1 | ForEach-Object { L "schtasks run   : $_" }
if (Wait-Supervised 'new') { L "=== done: $newVer running, supervised ==="; exit 0 }

# 4. ROLL BACK.
L "!!! $newVer did NOT come up supervised -- rolling back to $oldVer"
taskkill /F /IM warden.exe /T 2>&1 | ForEach-Object { L "taskkill warden : $_" }
taskkill /F /IM watchtower.exe /T 2>&1 | ForEach-Object { L "taskkill app    : $_" }
Start-Sleep -Seconds 3
Copy-Item $bkExe $exe -Force
if ($swapWarden) { Copy-Item $bkWd $wd -Force }
L ("restored: app file version {0}" -f (Get-Item $exe).VersionInfo.FileVersion)
schtasks /run /tn wt-warden 2>&1 | ForEach-Object { L "schtasks run   : $_" }
if (Wait-Supervised 'rollback') { L "=== done: ROLLED BACK to $oldVer, supervised ===" }
else { L "=== FAILED: nothing supervised even after rollback ===" }
