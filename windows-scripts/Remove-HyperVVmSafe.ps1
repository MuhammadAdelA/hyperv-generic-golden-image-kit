[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [ValidateSet('Preview', 'Delete')]
    [string]$Action = 'Preview',

    [string[]]$AllowedRoot = @(),

    [switch]$CleanupOrphans
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-SafePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-PathWithinRoot {
    param([string]$Path, [string]$Root)
    $candidate = Resolve-SafePath $Path
    $boundary = (Resolve-SafePath $Root) + '\'
    return $candidate.Equals($boundary.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($boundary, [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-DedicatedVmRoot {
    param([Parameter(Mandatory = $true)][string]$Root)
    $resolved = Resolve-SafePath $Root
    if ($resolved -eq [System.IO.Path]::GetPathRoot($resolved).TrimEnd('\')) {
        throw "Volume roots cannot be authorized: $resolved"
    }
    if (-not (Split-Path -Leaf $resolved).Equals($VmName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "AllowedRoot must be a dedicated per-VM folder whose leaf matches '$VmName': $resolved"
    }
    return $resolved
}

function Remove-EmptyDirectoryTree {
    param([Parameter(Mandatory = $true)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }

    $directories = @(
        Get-ChildItem -LiteralPath $Root -Directory -Force -Recurse -ErrorAction Stop |
            Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
            Select-Object -ExpandProperty FullName
    )
    $directories += $Root

    foreach ($directory in ($directories | Sort-Object { $_.Length } -Descending -Unique)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        $remaining = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop | Select-Object -First 1)
        if ($remaining.Count -gt 0) {
            Write-Warning "Preserving non-empty authorized folder: $directory"
            continue
        }
        Write-Host "Deleting empty authorized folder: $directory" -ForegroundColor DarkYellow
        Remove-Item -LiteralPath $directory -Force
    }
}

$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if (-not $vm) {
    if (-not $CleanupOrphans) {
        throw "VM '$VmName' is not registered. Use -CleanupOrphans with explicit -AllowedRoot values to preview or remove known residual files and empty folders."
    }
    if ($AllowedRoot.Count -eq 0) { throw '-CleanupOrphans requires at least one explicit AllowedRoot.' }

    $orphanRoots = @($AllowedRoot | ForEach-Object { Resolve-DedicatedVmRoot $_ } | Sort-Object -Unique)
    $knownOrphanFiles = @(
        foreach ($root in $orphanRoots) {
            $summaryPath = Join-Path $root ("{0}-seed.vhdx.rescue.txt" -f $VmName)
            if (Test-Path -LiteralPath $summaryPath -PathType Leaf) { Get-Item -LiteralPath $summaryPath }
        }
    )
    $unexpectedFiles = @(
        foreach ($root in $orphanRoots) {
            if (Test-Path -LiteralPath $root -PathType Container) {
                Get-ChildItem -LiteralPath $root -File -Force -Recurse -ErrorAction Stop |
                    Where-Object { $_.FullName -notin $knownOrphanFiles.FullName }
            }
        }
    )

    Write-Host "`nOrphan cleanup for VM: $VmName" -ForegroundColor Cyan
    Write-Host "Action               : $Action" -ForegroundColor Cyan
    Write-Host 'Dedicated roots:' -ForegroundColor Cyan
    $orphanRoots | ForEach-Object { Write-Host "  $_" }
    if ($knownOrphanFiles.Count -gt 0) {
        Write-Host 'Known removable residual files:' -ForegroundColor Cyan
        $knownOrphanFiles | Select-Object FullName, Length | Format-Table -AutoSize
    }
    if ($unexpectedFiles.Count -gt 0) {
        Write-Warning 'Unexpected files were found and will be preserved.'
        $unexpectedFiles | Select-Object FullName, Length | Format-Table -AutoSize
    }
    if ($Action -eq 'Preview') {
        Write-Host 'Preview only. Nothing was deleted.' -ForegroundColor Green
        return
    }

    foreach ($file in $knownOrphanFiles) {
        Write-Host "Deleting known residual file: $($file.FullName)" -ForegroundColor DarkYellow
        Remove-Item -LiteralPath $file.FullName -Force
    }
    foreach ($root in ($orphanRoots | Sort-Object { $_.Length } -Descending)) {
        Remove-EmptyDirectoryTree -Root $root
    }
    Write-Host 'Known orphan files and empty dedicated folders were cleaned successfully.' -ForegroundColor Green
    return
}
if ($CleanupOrphans) { throw '-CleanupOrphans can be used only after the VM is no longer registered.' }

$vmRoot = Resolve-SafePath $vm.Path
$volumeRoot = [System.IO.Path]::GetPathRoot($vmRoot).TrimEnd('\')
if ($vmRoot -eq $volumeRoot) { throw "Unsafe VM root resolved to a volume root: $vmRoot" }
if (-not (Split-Path -Leaf $vmRoot).Equals($VmName, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Delete refused because the VM root leaf does not match the VM name. VM: '$VmName'; root: '$vmRoot'."
}

$allowedRoots = @($vmRoot)
foreach ($root in $AllowedRoot) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    $resolved = Resolve-DedicatedVmRoot $root
    $allowedRoots += $resolved
}
$allowedRoots = @($allowedRoots | Sort-Object -Unique)

$allAttachedDisks = @(
    foreach ($knownVm in @(Get-VM)) {
        Get-VMHardDiskDrive -VMName $knownVm.Name
    }
)
$hardDisks = @(Get-VMHardDiskDrive -VMName $VmName)
$dvdDrives = @(Get-VMDvdDrive -VMName $VmName | Where-Object { $_.Path })
$rawCandidates = @($hardDisks | Select-Object -ExpandProperty Path)
foreach ($diskPath in @($hardDisks | Select-Object -ExpandProperty Path)) {
    $summaryPath = "$diskPath.rescue.txt"
    if (Test-Path -LiteralPath $summaryPath -PathType Leaf) { $rawCandidates += $summaryPath }
}
$rawCandidates += @($vm.Path, $vm.ConfigurationLocation, $vm.SnapshotFileLocation, $vm.SmartPagingFilePath)
$rawCandidates = $rawCandidates |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique

$candidates = foreach ($path in $rawCandidates) {
    $resolvedPath = Resolve-SafePath $path
    $isDirectory = Test-Path -LiteralPath $resolvedPath -PathType Container
    $matchingRoots = @($allowedRoots | Where-Object { Test-PathWithinRoot -Path $resolvedPath -Root $_ })
    $otherOwners = @($allAttachedDisks | Where-Object {
        if ($_.VMName -eq $VmName -or -not $_.Path) { return $false }
        $otherPath = Resolve-SafePath $_.Path
        return $otherPath -eq $resolvedPath -or
            ($isDirectory -and $otherPath.StartsWith(($resolvedPath + '\'), [System.StringComparison]::OrdinalIgnoreCase))
    } | Select-Object -ExpandProperty VMName -Unique)

    $reason = if ($otherOwners.Count -gt 0) {
        "Disk is also attached to VM(s): $($otherOwners -join ', ')"
    }
    elseif ($matchingRoots.Count -eq 0) {
        'Path is outside the authorized roots'
    }
    else { '' }

    [PSCustomObject]@{
        Allowed = [string]::IsNullOrWhiteSpace($reason)
        Exists  = Test-Path -LiteralPath $resolvedPath
        IsDirectory = $isDirectory
        Path    = $resolvedPath
        Reason  = $reason
    }
}

Write-Host "`nTarget VM: $VmName" -ForegroundColor Cyan
Write-Host "Action   : $Action" -ForegroundColor Cyan
Write-Host 'Allowed roots:' -ForegroundColor Cyan
$allowedRoots | ForEach-Object { Write-Host "  $_" }
$candidates | Format-Table Allowed, Exists, IsDirectory, Path, Reason -AutoSize

Write-Host "`nDVD / ISO paths (display only):" -ForegroundColor Cyan
$dvdDrives | Select-Object VMName, Path | Format-Table -AutoSize

if ($Action -eq 'Preview') {
    Write-Host 'Preview only. Nothing was deleted.' -ForegroundColor Green
    return
}

$blocked = @($candidates | Where-Object { -not $_.Allowed })
if ($blocked.Count -gt 0) {
    throw 'Delete refused because one or more candidate paths are shared or outside the authorized roots. Add only verified roots with -AllowedRoot.'
}

if ($vm.State -ne 'Off') {
    Stop-VM -Name $VmName -TurnOff -Force
}
Remove-VM -Name $VmName -Force

foreach ($candidate in ($candidates | Where-Object { $_.Exists -and -not $_.IsDirectory })) {
    if (Test-Path -LiteralPath $candidate.Path) {
        Write-Host "Deleting authorized file: $($candidate.Path)" -ForegroundColor DarkYellow
        Remove-Item -LiteralPath $candidate.Path -Force
    }
}

foreach ($root in ($allowedRoots | Sort-Object { $_.Length } -Descending)) {
    Remove-EmptyDirectoryTree -Root $root
}

Write-Host 'VM and authorized owned files were removed; non-empty folders, if any, were preserved.' -ForegroundColor Green
