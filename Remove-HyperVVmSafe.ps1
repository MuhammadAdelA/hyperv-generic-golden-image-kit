param(
    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [ValidateSet("Preview", "Delete")]
    [string]$Action = "Preview"
)

$ErrorActionPreference = "Stop"

Write-Host "`nTarget VM: $VmName" -ForegroundColor Cyan
Write-Host "Action   : $Action" -ForegroundColor Cyan

# Verify that the VM exists
$vm = Get-VM -Name $VmName -ErrorAction Stop

# Collect VHD/VHDX disks
$hardDisks = Get-VMHardDiskDrive -VMName $VmName

# Collect DVD/ISO paths for display only; they are not deleted
$dvdDrives = Get-VMDvdDrive -VMName $VmName | Where-Object { $_.Path }

# Paths that may be deleted
$paths = @()

# VM disks
$paths += $hardDisks | Select-Object -ExpandProperty Path

# Hyper-V folders associated with the VM
$paths += $vm.Path
$paths += $vm.ConfigurationLocation
$paths += $vm.SnapshotFileLocation
$paths += $vm.SmartPagingFilePath

# Remove empty entries and duplicates
$paths = $paths |
    Where-Object { $_ } |
    Sort-Object -Unique

# VM parent folder
# Example:
# D:\HyperV\VMs\vm-dev-01
$vmParentFolder = Split-Path $vm.Path -Parent

# Safety guard: delete the parent folder only if its name matches the VM name
$canDeleteParentFolder = $false

if ($vmParentFolder -and ((Split-Path $vmParentFolder -Leaf) -eq $VmName)) {
    $canDeleteParentFolder = $true
}

Write-Host "`n========== VM INFO ==========" -ForegroundColor Yellow

$vm | Select-Object `
    Name,
    State,
    Generation,
    Path,
    ConfigurationLocation,
    SnapshotFileLocation,
    SmartPagingFilePath |
    Format-List

Write-Host "`n========== HARD DISKS TO DELETE ==========" -ForegroundColor Yellow

if ($hardDisks) {
    $hardDisks |
        Select-Object VMName, ControllerType, ControllerNumber, ControllerLocation, Path |
        Format-Table -AutoSize
} else {
    Write-Host "No hard disks found."
}

Write-Host "`n========== DVD / ISO ATTACHED - DISPLAY ONLY ==========" -ForegroundColor Yellow

if ($dvdDrives) {
    $dvdDrives |
        Select-Object VMName, ControllerType, ControllerNumber, ControllerLocation, Path |
        Format-Table -AutoSize
} else {
    Write-Host "No DVD/ISO attached."
}

Write-Host "`n========== DELETE CANDIDATE PATHS ==========" -ForegroundColor Red

$deleteList = foreach ($p in $paths) {
    [PSCustomObject]@{
        Exists = Test-Path -LiteralPath $p
        Path   = $p
    }
}

$deleteList | Format-Table -AutoSize

Write-Host "`n========== EMPTY PARENT FOLDER CANDIDATE ==========" -ForegroundColor Magenta

[PSCustomObject]@{
    Exists          = if ($vmParentFolder) { Test-Path -LiteralPath $vmParentFolder } else { $false }
    CanDeleteSafely = $canDeleteParentFolder
    DeleteCondition = "Only if empty after deleting VM files"
    Path            = $vmParentFolder
} | Format-Table -AutoSize

Write-Host "`n========== NOTE ==========" -ForegroundColor Cyan
Write-Host "This script does NOT delete VM-NAT, Virtual Switches, or NetNat." -ForegroundColor Cyan
Write-Host "DVD/ISO paths are displayed only and are NOT deleted directly." -ForegroundColor Cyan
Write-Host "Parent folder is deleted only if empty and its name matches the VM name." -ForegroundColor Cyan

# Preview mode only
if ($Action -eq "Preview") {
    Write-Host "`nPreview only. Nothing was deleted." -ForegroundColor Green
    Write-Host "To actually delete, run with: -Action Delete" -ForegroundColor Green
    exit
}

Write-Host "`nDeleting VM and related files..." -ForegroundColor Red

# Stop the VM if it is running
if ($vm.State -ne "Off") {
    Write-Host "Stopping VM: $VmName" -ForegroundColor DarkYellow
    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
}

# Remove the VM registration from Hyper-V
Write-Host "Removing VM from Hyper-V: $VmName" -ForegroundColor DarkYellow
Remove-VM -Name $VmName -Force

# Delete related files and folders
foreach ($p in $paths) {
    if (Test-Path -LiteralPath $p) {
        Write-Host "Deleting: $p" -ForegroundColor DarkYellow
        Remove-Item -LiteralPath $p -Recurse -Force
    }
}

# Delete the VM parent folder only if it becomes empty and its name matches the VM name
if ($canDeleteParentFolder) {
    if ((Test-Path -LiteralPath $vmParentFolder) -and -not (Get-ChildItem -LiteralPath $vmParentFolder -Force)) {
        Write-Host "Deleting empty parent folder: $vmParentFolder" -ForegroundColor DarkYellow
        Remove-Item -LiteralPath $vmParentFolder -Force
    } else {
        Write-Host "Parent folder was not deleted because it is not empty: $vmParentFolder" -ForegroundColor Cyan
    }
} else {
    Write-Host "Parent folder was not deleted for safety because its name does not match the VM name: $vmParentFolder" -ForegroundColor Yellow
}

Write-Host "`nDone. VM deleted successfully." -ForegroundColor Green