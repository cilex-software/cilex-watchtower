# Pure log fixtures only. No app/process, registry, camera, network or task operations.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot '..\StationVideoHealth.psm1') -Force -DisableNameChecking
$passed=0; $failed=0
$fixtureRoot=$null
$clock=[DateTime]::Parse('2026-10-13T09:00:00Z',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
$created=$clock.AddSeconds(-120)
function Assert-True($Condition) { if (-not $Condition) { throw 'Fixture assertion failed' } }
function Test-Case([string]$Name,[scriptblock]$Body) {
    try { & $Body; $script:passed++ }
    catch { $script:failed++; Write-Output ('FAIL: '+$Name) }
}
function Must-Fail([scriptblock]$Body,[string]$Code) {
    $rejected=$false
    try { $null=& $Body } catch { $rejected=($_.Exception.Message -eq $Code) }
    Assert-True $rejected
}
function Stamp([DateTime]$Time) { return $Time.ToLocalTime().ToString('yyyy-MM-ddTHH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture) }
function Marker([int]$Id=4242,[DateTime]$Time=$created.AddSeconds(1)) {
    return ((Stamp $Time)+' I [abc] === watchtower start v1.1.778 pid='+$Id+' build=fixture qt=6 os=fixture ===')
}
function Sample([int]$Ago,[long]$Frames,[long]$Decoded,[long]$Decoders=1,[long]$Lit=1,[long]$Pipelines=1,[long]$Playback=0,[long]$Up=-1,[long]$Errors=0) {
    if ($Up -lt 0) { $Up=120-$Ago }
    return ((Stamp $clock.AddSeconds(-$Ago))+' I [abc] [MEMTEL] up='+$Up+'s rss=100MB playSec=0 opens=0 active='+$Playback+' livePipes='+$Pipelines+' frames='+$Frames+' framesIn='+$Decoded+' coalesced=0 drop=0.0% dec='+$Decoders+' lit='+$Lit+' err='+$Errors+' swd=0 recon=0/0 anon=-1M')
}
function Snapshot([string[]]$Lines,[int]$Id=4242,[DateTime]$Start=$created) {
    return ConvertFrom-StationVideoTelemetry -Lines $Lines -ProcessId $Id -CreatedUTC $Start -Now $clock
}
$healthy=Snapshot @((Marker),(Sample 40 100 110),(Sample 10 500 510))
$idle=Snapshot @((Marker),(Sample 40 0 0 0 0 0),(Sample 10 0 0 0 0 0))
try {
    Test-Case 'moving camera frames pass baseline and update check' {
        Assert-True ($healthy.Known -and $healthy.Healthy -and $healthy.ExpectedVideo)
        $proof=Assert-StationVideoBaseline $healthy
        Assert-True ($proof.VideoVerified -and $proof.FrameDelta -eq 400 -and $proof.SampleSeconds -eq 30)
        $proof=Assert-StationVideoProgress -Before $healthy -After $healthy
        Assert-True $proof.Passed
    }
    Test-Case 'idle wall is reported without a camera pass' {
        Assert-True ($idle.Known -and $idle.Healthy -and -not $idle.ExpectedVideo)
        $proof=Assert-StationVideoBaseline $idle
        Assert-True ($proof.Passed -and -not $proof.VideoVerified)
    }
    Test-Case 'alive stalled source refuses baseline before stop' {
        $bad=Snapshot @((Marker),(Sample 40 1084 1189 0 0 1),(Sample 10 1084 1189 0 0 1))
        Assert-True ($bad.Known -and $bad.ExpectedVideo -and -not $bad.Healthy)
        Must-Fail { Assert-StationVideoBaseline $bad } 'VIDEO_NOT_RECENTLY_DELIVERING'
    }
    Test-Case 'previous camera video cannot be waived by an explicit false' {
        Must-Fail { Assert-StationVideoProgress -Before $healthy -After $idle -RequireVideo $false } 'VIDEO_NOT_RECENTLY_DELIVERING'
    }
    Test-Case 'playback alone remains expected and unverified' {
        $playback=Snapshot @((Marker),(Sample 40 0 0 0 0 0 1),(Sample 10 0 0 0 0 0 1))
        Assert-True ($playback.Known -and $playback.ExpectedVideo -and -not $playback.Healthy)
        Must-Fail { Assert-StationVideoBaseline $playback } 'VIDEO_NOT_RECENTLY_DELIVERING'
    }
    Test-Case 'idle baseline cannot waive a newly expected stalled source' {
        $stalled=Snapshot @((Marker),(Sample 40 0 0 0 0 1),(Sample 10 0 0 0 0 1))
        Must-Fail { Assert-StationVideoProgress $idle $stalled } 'VIDEO_NOT_RECENTLY_DELIVERING'
    }
    Test-Case 'partial wall recovery cannot pass with one surviving feed' {
        $wall=Snapshot @((Marker),(Sample 40 1000 1100 16 16 16),(Sample 10 6000 6100 16 16 16))
        Assert-True $wall.Healthy
        Must-Fail { Assert-StationVideoProgress $wall $healthy } 'VIDEO_PREVIOUS_FEED_COUNT_NOT_RESTORED'
    }
    Test-Case 'loss of a decoder cannot pass even if recent frame count persists' {
        $wall=Snapshot @((Marker),(Sample 40 1000 1100 2 2 2),(Sample 10 2000 2100 2 2 2))
        $partial=Snapshot @((Marker),(Sample 40 1000 1100 1 2 2),(Sample 10 2000 2100 1 2 2))
        Must-Fail { Assert-StationVideoProgress $wall $partial } 'VIDEO_PREVIOUS_FEED_COUNT_NOT_RESTORED'
    }
    Test-Case 'baseline stream errors refuse before stopping' {
        $bad=Snapshot @((Marker),(Sample 40 100 110),(Sample 10 500 510 -Errors 1))
        Assert-True (-not $bad.Healthy)
        Must-Fail { Assert-StationVideoBaseline $bad } 'VIDEO_BASELINE_HAS_STREAM_ERRORS'
    }
    Test-Case 'new stream error refuses despite advancing frames' {
        $bad=Snapshot @((Marker),(Sample 40 100 110),(Sample 10 500 510 -Errors 1))
        Must-Fail { Assert-StationVideoProgress $healthy $bad } 'VIDEO_AFTER_UPDATE_HAS_STREAM_ERRORS'
    }
    Test-Case 'error in the final sample pair needs another clean sample' {
        $bad=Snapshot @((Marker),(Sample 40 100 110 -Errors 1),(Sample 10 500 510))
        Must-Fail { Assert-StationVideoProgress $healthy $bad } 'VIDEO_FINAL_PAIR_HAS_STREAM_ERRORS'
        $clean=Snapshot @((Marker),(Sample 70 100 110 -Errors 1),(Sample 40 500 510),(Sample 10 900 910))
        Assert-True (Assert-StationVideoProgress $healthy $clean).VideoVerified
    }
    Test-Case 'healthy additional feeds can pass' {
        $more=Snapshot @((Marker),(Sample 40 1000 1100 2 2 2),(Sample 10 2000 2100 2 2 2))
        Assert-True (Assert-StationVideoProgress $healthy $more).VideoVerified
    }
    Test-Case 'no-video classification cannot hide a stream error' {
        $bad=Snapshot @((Marker),(Sample 40 0 0 0 0 0),(Sample 10 0 0 0 0 0 -Errors 1))
        Must-Fail { Assert-StationVideoProgress $idle $bad } 'VIDEO_AFTER_UPDATE_HAS_STREAM_ERRORS'
    }
    Test-Case 'wrong process log refuses' { Assert-True (-not (Snapshot @((Marker 999),(Sample 10 5 5))).Known) }
    Test-Case 'PID reuse with a different start time refuses' { Assert-True (-not (Snapshot @((Marker),(Sample 10 5 5)) 4242 $created.AddMinutes(-5)).Known) }
    Test-Case 'missing startup marker refuses' { Assert-True (-not (Snapshot @((Sample 40 1 1),(Sample 10 5 5))).Known) }
    Test-Case 'malformed newer startup boundary invalidates prior session' {
        Assert-True (-not (Snapshot @((Marker),(Sample 40 1 1),'2026-10-13T11:59:55.000 I === watchtower start invalid',(Sample 10 5 5))).Known)
    }
    Test-Case 'newer foreign process invalidates prior session' {
        Assert-True (-not (Snapshot @((Marker),(Sample 40 1 1),(Marker 999),(Sample 10 5 5))).Known)
    }
    Test-Case 'stale telemetry refuses' { Assert-True (-not (Snapshot @((Marker),(Sample 90 1 1))).Known) }
    Test-Case 'future telemetry refuses' { Assert-True (-not (Snapshot @((Marker),(Sample -10 1 1))).Known) }
    Test-Case 'one fresh sample is insufficient for active video' {
        $one=Snapshot @((Marker),(Sample 10 5 5))
        Must-Fail { Assert-StationVideoProgress $healthy $one } 'VIDEO_NEEDS_TWO_FRESH_SAMPLES'
    }
    Test-Case 'samples too close cannot establish sustained movement' {
        $short=Snapshot @((Marker),(Sample 30 1 1),(Sample 10 5 5))
        Must-Fail { Assert-StationVideoProgress $healthy $short } 'VIDEO_SAMPLE_INTERVAL_TOO_SHORT'
    }
    Test-Case 'exact minimum interval passes' {
        $pair=Snapshot @((Marker),(Sample 35 1 1),(Sample 10 5 5))
        Assert-True (Assert-StationVideoProgress $healthy $pair).VideoVerified
    }
    Test-Case 'uptime rollback cannot pass despite timestamps' {
        $pair=Snapshot @((Marker),(Sample 40 1 1 1 1 1 0 90),(Sample 10 5 5 1 1 1 0 60))
        Must-Fail { Assert-StationVideoProgress $healthy $pair } 'VIDEO_SAMPLE_INTERVAL_TOO_SHORT'
    }
    Test-Case 'fixed delivered counter refuses' {
        $pair=Snapshot @((Marker),(Sample 40 5 10),(Sample 10 5 20))
        Must-Fail { Assert-StationVideoProgress $healthy $pair } 'VIDEO_FRAMES_NOT_ADVANCING'
    }
    Test-Case 'fixed decoder input counter refuses' {
        $pair=Snapshot @((Marker),(Sample 40 5 10),(Sample 10 10 10))
        Must-Fail { Assert-StationVideoProgress $healthy $pair } 'VIDEO_FRAMES_NOT_ADVANCING'
    }
    Test-Case 'decoder loss at final sample refuses' {
        $pair=Snapshot @((Marker),(Sample 40 1 1),(Sample 10 5 5 0 0))
        Must-Fail { Assert-StationVideoProgress $healthy $pair } 'VIDEO_NOT_RECENTLY_DELIVERING'
    }
    Test-Case 'no recent frames despite a decoder refuses' {
        $pair=Snapshot @((Marker),(Sample 40 1 1),(Sample 10 5 5 1 0))
        Must-Fail { Assert-StationVideoProgress $healthy $pair } 'VIDEO_NOT_RECENTLY_DELIVERING'
    }
    Test-Case 'counter reset needs a third sample' {
        $pair=Snapshot @((Marker),(Sample 40 1000 1000),(Sample 10 5 5))
        Must-Fail { Assert-StationVideoProgress $healthy $pair } 'VIDEO_COUNTER_RESET_NEEDS_NEW_PAIR'
    }
    Test-Case 'third advancing sample after reset passes' {
        $pair=Snapshot @((Marker),(Sample 70 1000 1000),(Sample 40 5 5),(Sample 10 15 15))
        Assert-True (Assert-StationVideoProgress $healthy $pair).VideoVerified
    }
    Test-Case 'duplicate samples cannot make a fake interval' {
        $one=Sample 10 5 5
        $pair=Snapshot @((Marker),$one,$one)
        Must-Fail { Assert-StationVideoProgress $healthy $pair } 'VIDEO_NEEDS_TWO_FRESH_SAMPLES'
    }
    Test-Case 'integer overflow refuses' {
        Assert-True (-not (Snapshot @((Marker),((Sample 10 5 5)-replace 'frames=5','frames=999999999999999999999999'))).Known)
    }
    Test-Case 'missing required gauge refuses' {
        Assert-True (-not (Snapshot @((Marker),((Sample 10 5 5)-replace 'lit=1',''))).Known)
    }
    Test-Case 'negative counters refuse' {
        Assert-True (-not (Snapshot @((Marker),((Sample 10 5 5)-replace 'frames=5','frames=-1'))).Known)
    }
    Test-Case 'unknown baseline refuses even if new frames move' {
        $unknown=Snapshot @()
        Must-Fail { Assert-StationVideoProgress $unknown $healthy } 'VIDEO_BASELINE_UNVERIFIED'
    }
    Test-Case 'missing final log cannot silently pass idle baseline' {
        $unknown=Snapshot @()
        Must-Fail { Assert-StationVideoProgress $idle $unknown } 'VIDEO_AFTER_UPDATE_UNVERIFIED'
    }
    Test-Case 'explicit recovery requirement applies to idle baseline' {
        Must-Fail { Assert-StationVideoProgress $idle $idle -RequireVideo $true } 'VIDEO_NOT_RECENTLY_DELIVERING'
        Assert-True (Assert-StationVideoProgress $idle $healthy -RequireVideo $true).VideoVerified
    }
    Test-Case 'returned data contains only safe numeric evidence' {
        $data=Snapshot @((Marker),'private fixture token=DO_NOT_RETURN camera_url=DO_NOT_RETURN',(Sample 40 1 1),(Sample 10 5 5))
        Assert-True (($data|ConvertTo-Json -Depth 5) -notmatch 'DO_NOT_RETURN|camera_url|token=')
    }
    Test-Case 'UTC timestamp is accepted' {
        $utcMarker=(Marker)-replace '^\S+',$created.AddSeconds(1).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $utcSample=(Sample 10 5 5)-replace '^\S+',$clock.AddSeconds(-10).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Assert-True (Snapshot @($utcMarker,$utcSample)).Known
    }
    Test-Case 'relative log paths refuse before reads' {
        Must-Fail { Get-StationVideoSnapshot -LogPath '.\watchtower.log' -ProcessId 4242 -CreatedUTC $created -Now $clock } 'VIDEO_LOG_PATH_NOT_LOCAL_ABSOLUTE'
    }
    Test-Case 'network log paths refuse before reads' {
        Must-Fail { Get-StationVideoSnapshot -LogPath '\\fixture\share\watchtower.log' -ProcessId 4242 -CreatedUTC $created -Now $clock } 'VIDEO_LOG_PATH_NOT_LOCAL_ABSOLUTE'
    }
    Test-Case 'unexpected filename refuses before reads' {
        Must-Fail { Get-StationVideoSnapshot -LogPath 'C:\fixture\settings.conf' -ProcessId 4242 -CreatedUTC $created -Now $clock } 'VIDEO_LOG_FILENAME_UNEXPECTED'
    }
    # The reader tests use only disposable fixture files beside this test's own unique temp root.
    $fixtureBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $fixtureRoot=Join-Path $fixtureBase ('wt-video-fixture-'+[Guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $fixtureRoot
    $log=Join-Path $fixtureRoot 'watchtower.log'
    Test-Case 'missing log returns unverified' {
        Assert-True (-not (Get-StationVideoSnapshot $log 4242 $created -Now $clock).Known)
    }
    Test-Case 'startup marker survives log rotation and files stay unchanged' {
        [IO.File]::WriteAllLines(($log+'.1'),[string[]]@((Marker),(Sample 40 1 1)))
        [IO.File]::WriteAllLines($log,[string[]]@((Sample 10 5 5)))
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'unrelated.conf'),'DO_NOT_READ')
        $before=(Get-FileHash $log -Algorithm SHA256).Hash
        $data=Get-StationVideoSnapshot $log 4242 $created -Now $clock
        Assert-True ($data.Known -and $data.Healthy)
        Assert-True ((Get-FileHash $log -Algorithm SHA256).Hash -eq $before)
    }
    Test-Case 'new foreign session after rotated marker refuses' {
        [IO.File]::WriteAllLines($log,[string[]]@((Marker 999),(Sample 10 5 5)))
        Assert-True (-not (Get-StationVideoSnapshot $log 4242 $created -Now $clock).Known)
    }
    Test-Case 'oversized log is refused without unlimited reads' {
        $stream=[IO.File]::Open($log,[IO.FileMode]::Create,[IO.FileAccess]::Write)
        try { $stream.SetLength(16MB+1) } finally { $stream.Dispose() }
        $data=Get-StationVideoSnapshot $log 4242 $created -Now $clock
        Assert-True (-not $data.Known -and $data.Reason -eq 'VIDEO_LOG_READ_LIMIT_EXCEEDED')
    }
} finally {
    if ($fixtureRoot) {
        $resolved=[IO.Path]::GetFullPath($fixtureRoot)
        $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if (-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetFileName($resolved) -notmatch '^wt-video-fixture-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup refused' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Output ('Video health tests: '+$passed+' passed, '+$failed+' failed.')
if ($failed -gt 0) { exit 1 }
