# Numeric-only checks of the existing Watchtower flight-recorder log.
# No processes, registry values, camera URLs or application settings are read.
Set-StrictMode -Version 2

function ConvertTo-VideoUtc([DateTime]$Value) {
    if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
        return [TimeZoneInfo]::ConvertTimeToUtc($Value, [TimeZoneInfo]::Local)
    }
    return $Value.ToUniversalTime()
}

function ConvertFrom-VideoTimestamp([string]$Value) {
    $parsed = [DateTime]::MinValue
    if ($Value -match '(?:Z|[+-]\d{2}:\d{2})$') {
        if ([DateTime]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
            return ConvertTo-VideoUtc $parsed
        }
        return $null
    }
    if ([DateTime]::TryParseExact($Value, [string[]]@('yyyy-MM-ddTHH:mm:ss.fff','yyyy-MM-ddTHH:mm:ss'),
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return ConvertTo-VideoUtc $parsed
    }
    return $null
}

function New-UnknownVideoSnapshot([int]$ProcessId, [string]$Reason) {
    return [pscustomobject]@{
        Known=$false; Reason=$Reason; ProcessId=$ProcessId; SessionStartUTC=$null
        HasVideo=$false; ExpectedVideo=$false; Healthy=$false; Latest=$null; Samples=@()
    }
}

function ConvertFrom-StationVideoTelemetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$ProcessId,
        [Parameter(Mandatory=$true)][DateTime]$CreatedUTC,
        [DateTime]$Now=[DateTime]::UtcNow,
        [ValidateRange(30,300)][int]$MaxAgeSeconds=75
    )
    $created = ConvertTo-VideoUtc $CreatedUTC
    $clock = ConvertTo-VideoUtc $Now
    $marker = $null
    $markerPid = 0
    $badMarker = $false
    $samples = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in $Lines) {
        if ($line -match '=== watchtower start ') {
            # Every boundary invalidates the preceding session, even a malformed one.
            $marker=$null; $markerPid=0; $badMarker=$true; $samples.Clear()
            if ($line -match '^(\S+)\s+[DIWCF]\s+.*=== watchtower start v\S+ pid=(\d+) build=\S+') {
                $marker = ConvertFrom-VideoTimestamp $matches[1]
                $number = 0
                if ([int]::TryParse($matches[2], [ref]$number)) { $markerPid=$number }
                $badMarker = ($null -eq $marker -or $markerPid -lt 1)
            }
            continue
        }
        if ($null -eq $marker -or $markerPid -ne $ProcessId -or $line -notmatch '\[MEMTEL\] up=') { continue }
        if ($line -notmatch '^(\S+)\s+[DIWCF]\s+') { continue }
        $stamp = ConvertFrom-VideoTimestamp $matches[1]
        if ($null -eq $stamp -or $stamp -lt $marker -or $stamp -gt $clock.AddSeconds(5)) { continue }
        $numbers = @{}
        $valid = $true
        foreach ($name in @('up','active','livePipes','frames','framesIn','dec','lit','err')) {
            $suffix=if($name -eq 'up'){'s'}else{''}
            $hits = [regex]::Matches($line, ('(?<![A-Za-z0-9_])' + $name + '=(\d+)' + $suffix + '(?=[^A-Za-z0-9_]|$)'))
            $value = [long]0
            if ($hits.Count -ne 1 -or -not [long]::TryParse($hits[0].Groups[1].Value, [ref]$value)) { $valid=$false; break }
            $numbers[$name]=$value
        }
        if (-not $valid) { continue }
        # lit is explicitly recent delivered camera video; active is playback, not a live-feed count.
        $samples.Add([pscustomobject]@{
            TimestampUTC=$stamp; UptimeSeconds=$numbers.up; Frames=$numbers.frames
            FramesIn=$numbers.framesIn; Decoders=$numbers.dec; Lit=$numbers.lit
            Pipelines=$numbers.livePipes; ActivePlayback=$numbers.active; Errors=$numbers.err
        })
    }
    if ($badMarker) { return New-UnknownVideoSnapshot $ProcessId 'VIDEO_START_MARKER_INVALID' }
    if ($null -eq $marker) { return New-UnknownVideoSnapshot $ProcessId 'VIDEO_START_MARKER_MISSING' }
    if ($markerPid -ne $ProcessId) { return New-UnknownVideoSnapshot $ProcessId 'VIDEO_LOG_BELONGS_TO_OTHER_PROCESS' }
    if ($marker -lt $created.AddSeconds(-2) -or $marker -gt $created.AddSeconds(30) -or $marker -gt $clock.AddSeconds(5)) {
        return New-UnknownVideoSnapshot $ProcessId 'VIDEO_START_TIME_MISMATCH'
    }
    $recent = @($samples | Where-Object { $_.TimestampUTC -ge $clock.AddSeconds(-$MaxAgeSeconds) } |
        Sort-Object TimestampUTC,UptimeSeconds -Unique)
    if ($recent.Count -eq 0) { return New-UnknownVideoSnapshot $ProcessId 'VIDEO_TELEMETRY_MISSING_OR_STALE' }
    $latest = $recent[-1]
    $expectedVideo=($latest.Pipelines -gt 0 -or $latest.Decoders -gt 0 -or $latest.Lit -gt 0 -or $latest.ActivePlayback -gt 0)
    $snapshot=[pscustomobject]@{
        Known=$true; Reason='VIDEO_TELEMETRY_CURRENT'; ProcessId=$ProcessId; SessionStartUTC=$marker
        HasVideo=($latest.Lit -gt 0 -and $latest.Decoders -gt 0)
        ExpectedVideo=$expectedVideo; Healthy=$false; Latest=$latest; Samples=$recent
    }
    try { $proof=Assert-StationVideoProgress -Before $snapshot -After $snapshot; $snapshot.Healthy=[bool]$proof.Passed } catch { $snapshot.Healthy=$false }
    return $snapshot
}

function Assert-VideoLogPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') { throw 'VIDEO_LOG_PATH_NOT_LOCAL_ABSOLUTE' }
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetFileName($full) -ne 'watchtower.log') { throw 'VIDEO_LOG_FILENAME_UNEXPECTED' }
    $cursor=$full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'VIDEO_LOG_REPARSE_PATH_REFUSED' }
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor=$parent
    }
    return $full
}

function Get-StationVideoSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$LogPath,
        [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$ProcessId,
        [Parameter(Mandatory=$true)][DateTime]$CreatedUTC,
        [DateTime]$Now=[DateTime]::UtcNow,
        [ValidateRange(30,300)][int]$MaxAgeSeconds=75
    )
    $full=Assert-VideoLogPath $LogPath
    $directory=[IO.Path]::GetDirectoryName($full)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return New-UnknownVideoSnapshot $ProcessId 'VIDEO_LOG_MISSING' }
    $selected=New-Object 'System.Collections.Generic.List[string]'
    try {
        # Rotation is current -> .1 -> .2. Read oldest first so the newest startup boundary wins.
        # Limits cover the shipped 8 MiB x 5 configuration without an unbounded log search.
        $files=@(Get-ChildItem -LiteralPath $directory -File -Force -ErrorAction Stop |
            Where-Object { $_.Name -match '^watchtower\.log(?:\.([1-9]\d?))?$' -and
                ($_.Name -eq 'watchtower.log' -or [int]$matches[1] -le 50) } |
            Sort-Object @{Expression={if($_.Name -eq 'watchtower.log'){0}else{[int]($_.Name.Substring(15))}};Descending=$true})
        $total=[long]0
        foreach ($file in $files) {
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'VIDEO_ROTATED_LOG_REPARSE_REFUSED' }
            $total+=$file.Length
            if ($file.Length -gt 16MB -or $total -gt 64MB) { return New-UnknownVideoSnapshot $ProcessId 'VIDEO_LOG_READ_LIMIT_EXCEEDED' }
            $stream=$null; $reader=$null
            try {
                $stream=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,
                    ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
                while (($line=$reader.ReadLine()) -ne $null) {
                    if ($line -match '=== watchtower start |\[MEMTEL\] up=') { $selected.Add($line) }
                    if ($stream.Position -gt 16MB) { return New-UnknownVideoSnapshot $ProcessId 'VIDEO_LOG_READ_LIMIT_EXCEEDED' }
                }
            } finally {
                if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
            }
        }
    } catch {
        # Never return a raw log line or exception containing paths or application data.
        return New-UnknownVideoSnapshot $ProcessId 'VIDEO_LOG_READ_FAILED'
    }
    return ConvertFrom-StationVideoTelemetry -Lines $selected.ToArray() -ProcessId $ProcessId -CreatedUTC $CreatedUTC -Now $Now -MaxAgeSeconds $MaxAgeSeconds
}

function Assert-StationVideoProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Before,
        [Parameter(Mandatory=$true)]$After,
        [bool]$RequireVideo,
        [ValidateRange(20,120)][int]$MinimumSampleSeconds=25
    )
    if (-not $Before.Known) { throw 'VIDEO_BASELINE_UNVERIFIED' }
    if (-not $After.Known) { throw 'VIDEO_AFTER_UPDATE_UNVERIFIED' }
    if ($Before.Latest.Errors -gt 0) { throw 'VIDEO_BASELINE_HAS_STREAM_ERRORS' }
    if ($After.Latest.Errors -gt 0) { throw 'VIDEO_AFTER_UPDATE_HAS_STREAM_ERRORS' }
    # An explicit requirement can tighten the gate, never waive previously expected video.
    $required = [bool]$Before.ExpectedVideo -or [bool]$After.ExpectedVideo -or $RequireVideo
    if (-not $required) {
        return [pscustomobject]@{Passed=$true;VideoVerified=$false;Reason='NO_ACTIVE_VIDEO_BEFORE_UPDATE';ProcessId=$After.ProcessId;FrameDelta=$null;SampleSeconds=$null;FinalLit=$After.Latest.Lit}
    }
    $samples=@($After.Samples)
    if ($samples.Count -lt 2) { throw 'VIDEO_NEEDS_TWO_FRESH_SAMPLES' }
    $first=$samples[-2]; $last=$samples[-1]
    if ($first.Errors -gt 0 -or $last.Errors -gt 0) { throw 'VIDEO_FINAL_PAIR_HAS_STREAM_ERRORS' }
    $seconds=($last.TimestampUTC-$first.TimestampUTC).TotalSeconds
    if ($seconds -lt $MinimumSampleSeconds -or ($last.UptimeSeconds-$first.UptimeSeconds) -lt $MinimumSampleSeconds) { throw 'VIDEO_SAMPLE_INTERVAL_TOO_SHORT' }
    if ($last.Frames -lt $first.Frames -or $last.FramesIn -lt $first.FramesIn) { throw 'VIDEO_COUNTER_RESET_NEEDS_NEW_PAIR' }
    if ($first.Decoders -le 0 -or $last.Decoders -le 0 -or $first.Lit -le 0 -or $last.Lit -le 0) { throw 'VIDEO_NOT_RECENTLY_DELIVERING' }
    if ($last.Frames -le $first.Frames -or $last.FramesIn -le $first.FramesIn) { throw 'VIDEO_FRAMES_NOT_ADVANCING' }
    if ($Before.ExpectedVideo -and ($last.Lit -lt $Before.Latest.Lit -or $last.Decoders -lt $Before.Latest.Decoders)) { throw 'VIDEO_PREVIOUS_FEED_COUNT_NOT_RESTORED' }
    return [pscustomobject]@{Passed=$true;VideoVerified=$true;Reason='VIDEO_FRAMES_ADVANCED';ProcessId=$After.ProcessId;FrameDelta=($last.Frames-$first.Frames);SampleSeconds=$seconds;BaselineLit=$Before.Latest.Lit;BaselineDecoders=$Before.Latest.Decoders;FinalLit=$last.Lit;FinalDecoders=$last.Decoders;FinalErrors=$last.Errors}
}

function Assert-StationVideoBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Snapshot)
    if (-not $Snapshot.Known) { throw 'VIDEO_BASELINE_UNVERIFIED' }
    return Assert-StationVideoProgress -Before $Snapshot -After $Snapshot -RequireVideo ([bool]$Snapshot.ExpectedVideo)
}

Export-ModuleMember -Function Get-StationVideoSnapshot,ConvertFrom-StationVideoTelemetry,Assert-StationVideoBaseline,Assert-StationVideoProgress
