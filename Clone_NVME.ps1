# Requires: Administrator
# PURPOSE: Clone entire SOURCE disk to TARGET disk (raw, sector-by-sector).
# CONFIGURE THESE TWO LINES ONLY:
$SourceDiskNumber = 1   # e.g., 1
$TargetDiskNumber = 2   # e.g., 2

# ---------- Do not edit below ----------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "Run this script from an elevated PowerShell (Run as Administrator)." }
}

function Get-DiskInfo {
    param([Parameter(Mandatory)][uint32] $DiskNumber)
    $d = Get-Disk -Number $DiskNumber -ErrorAction Stop
    [pscustomobject]@{
        Number         = [uint32]$d.Number
        Size           = [int64]$d.Size
        LogicalSector  = [int]$d.LogicalSectorSize
        PhysicalSector = [int]$d.PhysicalSectorSize
        PartitionStyle = $d.PartitionStyle
        IsOffline      = [bool]$d.IsOffline
        IsReadOnly     = [bool]$d.IsReadOnly
    }
}

function Set-DiskState {
    param(
        [Parameter(Mandatory)][uint32] $DiskNumber,
        [bool] $IsOffline,
        [bool] $IsReadOnly
    )
    try { Set-Disk -Number $DiskNumber -IsOffline:$IsOffline -ErrorAction Stop } catch {}
    try { Set-Disk -Number $DiskNumber -IsReadOnly:$IsReadOnly -ErrorAction Stop } catch {}
}

function Open-RawDiskStream {
    param([Parameter(Mandatory)][uint32] $DiskNumber, [Parameter(Mandatory)][System.IO.FileAccess] $Access)
    $path = "\\.\PhysicalDrive$DiskNumber"
    [System.IO.File]::Open($path, [System.IO.FileMode]::Open, $Access, [System.IO.FileShare]::ReadWrite)
}

Assert-Admin

if ($SourceDiskNumber -eq $TargetDiskNumber) { throw "Source and Target disk numbers must be different." }

$src = Get-DiskInfo -DiskNumber $SourceDiskNumber
$dst = Get-DiskInfo -DiskNumber $TargetDiskNumber

Write-Host "Source Disk : #$($src.Number)  Size: $([math]::Round($src.Size/1GB,2)) GB  Style: $($src.PartitionStyle)"
Write-Host "Target Disk : #$($dst.Number)  Size: $([math]::Round($dst.Size/1GB,2)) GB  Style: $($dst.PartitionStyle)"

if ($dst.Size -lt $src.Size) {
    throw "Target is smaller than source. Target=$([math]::Round($dst.Size/1GB,2))GB, Source=$([math]::Round($src.Size/1GB,2))GB."
}

Write-Warning "This will ERASE disk #$($dst.Number) by overwriting it with a clone of disk #$($src.Number)."
$confirm = Read-Host "Type 'CLONE' to proceed"
if ($confirm.ToUpper() -ne 'CLONE') { throw "Aborted by user." }

# Remember original states to restore later
$srcOrig = $src.PSObject.Copy()
$dstOrig = $dst.PSObject.Copy()

# Prepare disks: keep source read-only; offline both to avoid automount churn
Write-Host "Offlining/locking disks for cloning..."
Set-DiskState -DiskNumber $src.Number -IsOffline $true  -IsReadOnly $true
Set-DiskState -DiskNumber $dst.Number -IsOffline $true  -IsReadOnly $false

# Buffer tuning (aligned to larger sector size)
$bufferSize = 64MB
$align = [Math]::Max($src.LogicalSector, $src.PhysicalSector)
if ($bufferSize % $align -ne 0) {
    $bufferSize = [int64]([Math]::Ceiling($bufferSize / $align) * $align)
}
# Ensure array length is Int32
if ($bufferSize -gt [int]::MaxValue) { throw "Buffer too large. Reduce `\$bufferSize` (current: $bufferSize bytes)." }
$buffer = [byte[]]::new([int]$bufferSize)

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$bytesCopied = 0L
$lastReport = 0L

try {
    Write-Host "Opening raw disk handles..."
    $srcStream = Open-RawDiskStream -DiskNumber $src.Number -Access ([System.IO.FileAccess]::Read)
    $dstStream = Open-RawDiskStream -DiskNumber $dst.Number -Access ([System.IO.FileAccess]::ReadWrite)

    Write-Host "Cloning... Do NOT disconnect drives."
    while ($bytesCopied -lt $src.Size) {
        $remaining = $src.Size - $bytesCopied              # Int64
        # --- FIX: compute Min in Int64 space, then cast to Int32 for .Read/.Write ---
        $toRead64 = [Math]::Min([int64]$buffer.LongLength, [int64]$remaining)
        $toRead   = [int]$toRead64
        if ($toRead -le 0) { break }

        $read = $srcStream.Read($buffer, 0, $toRead)
        if ($read -le 0) { break }
        $dstStream.Write($buffer, 0, $read)
        $bytesCopied += $read

        if (($bytesCopied - $lastReport) -ge 268435456 -or $bytesCopied -eq $src.Size) {
            $percent   = [int](($bytesCopied * 100.0) / $src.Size)
            $speedMBs  = if ($sw.Elapsed.TotalSeconds -gt 0) { [Math]::Round(($bytesCopied/1MB)/$sw.Elapsed.TotalSeconds, 1) } else { 0 }
            Write-Progress -Activity "Cloning PhysicalDrive$($src.Number) → PhysicalDrive$($dst.Number)" `
                           -Status "$percent%  ($([math]::Round($bytesCopied/1GB,2)) / $([math]::Round($src.Size/1GB,2)) GB) @ ${speedMBs}MB/s" `
                           -PercentComplete $percent
            $lastReport = $bytesCopied
        }
    }

    $dstStream.Flush()
}
finally {
    if ($srcStream) { $srcStream.Dispose() }
    if ($dstStream) { $dstStream.Dispose() }

    # Restore disks (bring target online; restore source to its original state)
    Write-Host "Restoring disk states..."
    Set-DiskState -DiskNumber $src.Number -IsOffline:$srcOrig.IsOffline -IsReadOnly:$srcOrig.IsReadOnly
    Set-DiskState -DiskNumber $dst.Number -IsOffline:$false -IsReadOnly:$dstOrig.IsReadOnly

    $sw.Stop()
}

Write-Host ""
Write-Host "Clone complete."
Write-Host ("Copied: {0:N2} GB in {1:g}  (~{2:N1} MB/s)" -f ($bytesCopied/1GB), $sw.Elapsed, (($bytesCopied/1MB)/[Math]::Max($sw.Elapsed.TotalSeconds,1)))
Write-Host "IMPORTANT: Disconnect the original before first boot of the clone to avoid duplicate disk ID conflicts."
