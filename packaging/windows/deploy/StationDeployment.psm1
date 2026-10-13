Set-StrictMode -Version 2.0
$script:StationCopyOverride = $null
$script:StationVerifyOverride = $null

function Resolve-StationFilePath {
    param([Parameter(Mandatory=$true)][string]$Path)
    if ($Path -notmatch '\A(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+[\\/])') { throw 'An absolute file path is required.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ([string]::IsNullOrWhiteSpace([IO.Path]::GetFileName($full))) { throw 'A file path is required.' }
    if ([IO.Directory]::Exists($full)) { throw 'The file path identifies a directory.' }
    if ([IO.File]::Exists($full)) {
        if (([IO.File]::GetAttributes($full) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Reparse-point files are not allowed.'
        }
    }
    return $full
}

function Convert-StationHash {
    param([Parameter(Mandatory=$true)][string]$SHA256)
    if ($SHA256 -notmatch '\A[0-9a-fA-F]{64}\z') { throw 'A SHA256 file hash is required.' }
    return $SHA256.ToUpperInvariant()
}

function Invoke-StationFileOperation {
    param([Parameter(Mandatory=$true)][scriptblock]$Action)
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try { return (& $Action) }
        catch {
            $errorValue = $_.Exception
            while ($errorValue.InnerException) { $errorValue = $errorValue.InnerException }
            $code = $errorValue.HResult -band 65535
            if ($errorValue -isnot [IO.IOException] -or $code -notin @(32,33) -or $attempt -eq 4) { throw }
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }
}

function Get-StationFileHashValue {
    param([Parameter(Mandatory=$true)][string]$Path)
    return (Invoke-StationFileOperation {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '') }
        finally { $algorithm.Dispose(); $stream.Dispose() }
    })
}

function Test-StationFileHash {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$SHA256)
    $file = Resolve-StationFilePath $Path
    $expected = Convert-StationHash $SHA256
    if (-not [IO.File]::Exists($file)) { return $false }
    return ((Get-StationFileHashValue $file) -eq $expected)
}

function Verify-Hash {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$SHA256)
    if ($script:StationVerifyOverride) { & $script:StationVerifyOverride $Path $SHA256 }
    if (-not (Test-StationFileHash -Path $Path -SHA256 $SHA256)) { throw 'File is missing or its SHA256 hash differs.' }
}

function Get-StationAppVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    $file = Resolve-StationFilePath $Path
    if (-not [IO.File]::Exists($file)) { throw 'Application file is missing.' }
    return [Diagnostics.FileVersionInfo]::GetVersionInfo($file).FileVersion
}

function Copy-StationContent {
    param([string]$Source, [string]$TemporaryPath)
    # Private override is used only by disposable-file failure-injection tests.
    if ($script:StationCopyOverride) { & $script:StationCopyOverride $Source $TemporaryPath }
    else { [IO.File]::Copy($Source, $TemporaryPath, $false) }
}

function Remove-StationTemporaryFile {
    param([string]$Path)
    if ([IO.File]::Exists($Path)) { Invoke-StationFileOperation { [IO.File]::Delete($Path) } }
}

function Install-StationFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination,
        [Parameter(Mandatory=$true)][string]$SHA256
    )
    $sourceFile = Resolve-StationFilePath $Source
    $destinationFile = Resolve-StationFilePath $Destination
    $expected = Convert-StationHash $SHA256
    Verify-Hash -Path $sourceFile -SHA256 $expected
    $existed = [IO.File]::Exists($destinationFile)
    if ($existed -and (Test-StationFileHash -Path $destinationFile -SHA256 $expected)) {
        return [pscustomobject]@{ Destination=$destinationFile; SHA256=$expected; Action='Unchanged'; ExistedBefore=$true }
    }
    $parent = [IO.Path]::GetDirectoryName($destinationFile)
    if (-not [IO.Directory]::Exists($parent)) { throw 'Destination directory is missing.' }
    $originalHash = if ($existed) { Get-StationFileHashValue $destinationFile } else { $null }
    $nonce = [Guid]::NewGuid().ToString('N')
    $leaf = [IO.Path]::GetFileName($destinationFile)
    $temporary = [IO.Path]::Combine($parent, ('.' + $leaf + '.wt-stage.' + $nonce + '.tmp'))
    $rollback = [IO.Path]::Combine($parent, ('.' + $leaf + '.wt-rollback.' + $nonce + '.tmp'))
    $rejected = [IO.Path]::Combine($parent, ('.' + $leaf + '.wt-rejected.' + $nonce + '.tmp'))
    $changed = $false
    $restored = $false
    $committed = $false
    try {
        Invoke-StationFileOperation { Copy-StationContent $sourceFile $temporary }
        Verify-Hash -Path $temporary -SHA256 $expected
        # Refuse an unexpected concurrent destination change before replacement.
        if ($existed) {
            Verify-Hash -Path $destinationFile -SHA256 $originalHash
            Invoke-StationFileOperation { [IO.File]::Replace($temporary, $destinationFile, $rollback, $false) }
        } else {
            if ([IO.File]::Exists($destinationFile)) { throw 'Destination appeared during installation.' }
            Invoke-StationFileOperation { [IO.File]::Move($temporary, $destinationFile) }
        }
        $changed = $true
        Verify-Hash -Path $destinationFile -SHA256 $expected
        if ($existed) { Verify-Hash -Path $rollback -SHA256 $originalHash }
        $committed = $true
        return [pscustomobject]@{ Destination=$destinationFile; SHA256=$expected; Action='Installed'; ExistedBefore=$existed }
    } catch {
        $failure = $_
        if ($changed) {
            try {
                if ($existed) {
                    Verify-Hash -Path $rollback -SHA256 $originalHash
                    if ([IO.File]::Exists($destinationFile)) {
                        Invoke-StationFileOperation { [IO.File]::Replace($rollback, $destinationFile, $rejected, $false) }
                    } else { Invoke-StationFileOperation { [IO.File]::Move($rollback, $destinationFile) } }
                    Verify-Hash -Path $destinationFile -SHA256 $originalHash
                    $restored = $true
                } elseif (Test-StationFileHash -Path $destinationFile -SHA256 $expected) {
                    Remove-StationTemporaryFile $destinationFile
                    $restored = $true
                } elseif (-not [IO.File]::Exists($destinationFile)) { $restored = $true }
                else { throw 'New destination differs from the installed manifest; refusing removal.' }
            } catch { throw ('Installation failed; recovery file retained at ' + $rollback + '. Rollback could not be verified.') }
        }
        throw $failure
    } finally {
        # Only the unique paths allocated by this invocation are cleaned up.
        try { Remove-StationTemporaryFile $temporary } catch { Write-Warning 'Owned staging residue could not be removed.' }
        if ($restored -or $committed) {
            try { Remove-StationTemporaryFile $rollback } catch { Write-Warning 'Owned rollback residue could not be removed.' }
            try { Remove-StationTemporaryFile $rejected } catch { Write-Warning 'Owned rejected-file residue could not be removed.' }
        }
    }
}

function Restore-StationFile {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Backup,
        [Parameter(Mandatory=$true)][string]$Destination,
        [AllowNull()][AllowEmptyString()][string]$SHA256,
        [Parameter(Mandatory=$true)][bool]$Existed,
        [AllowNull()][AllowEmptyString()][string]$InstalledSHA256
    )
    $destinationFile = Resolve-StationFilePath $Destination
    if ($Existed) {
        $originalHash = Convert-StationHash $SHA256
        if (Test-StationFileHash -Path $destinationFile -SHA256 $originalHash) {
            return [pscustomobject]@{ Destination=$destinationFile; SHA256=$originalHash; Action='Unchanged' }
        }
        if ([string]::IsNullOrWhiteSpace($Backup)) { throw 'Originally existing file requires a backup.' }
        if ([IO.File]::Exists($destinationFile) -and -not [string]::IsNullOrWhiteSpace($InstalledSHA256)) {
            Verify-Hash -Path $destinationFile -SHA256 $InstalledSHA256
        }
        $null = Install-StationFile -Source $Backup -Destination $destinationFile -SHA256 $originalHash
        return [pscustomobject]@{ Destination=$destinationFile; SHA256=$originalHash; Action='Restored' }
    }
    if (-not [IO.File]::Exists($destinationFile)) {
        return [pscustomobject]@{ Destination=$destinationFile; SHA256=$null; Action='Absent' }
    }
    if ([string]::IsNullOrWhiteSpace($InstalledSHA256)) { throw 'Removal requires the installed manifest SHA256 hash.' }
    $installedHash = Convert-StationHash $InstalledSHA256
    Verify-Hash -Path $destinationFile -SHA256 $installedHash
    # Move atomically to an invocation-owned path before the final ownership check.
    # An unexpected concurrent replacement is restored, never deleted.
    $parent = [IO.Path]::GetDirectoryName($destinationFile)
    $tombstone = [IO.Path]::Combine($parent, ('.' + [IO.Path]::GetFileName($destinationFile) + '.wt-remove.' + [Guid]::NewGuid().ToString('N') + '.tmp'))
    Invoke-StationFileOperation { [IO.File]::Move($destinationFile, $tombstone) }
    try {
        Verify-Hash -Path $tombstone -SHA256 $installedHash
        Remove-StationTemporaryFile $tombstone
    } catch {
        if ([IO.File]::Exists($tombstone) -and -not [IO.File]::Exists($destinationFile)) {
            Invoke-StationFileOperation { [IO.File]::Move($tombstone, $destinationFile) }
        }
        throw 'Owned file removal failed; unknown content was not deleted.'
    }
    if ([IO.File]::Exists($destinationFile)) { throw 'Destination changed during owned-file removal.' }
    return [pscustomobject]@{ Destination=$destinationFile; SHA256=$null; Action='Removed' }
}

Export-ModuleMember -Function Install-StationFile,Restore-StationFile,Test-StationFileHash,Verify-Hash,Get-StationAppVersion
