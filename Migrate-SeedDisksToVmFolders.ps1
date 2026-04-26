<# 
Migrate-SeedDisksToVmFolders.ps1

Purpose:
- Move old root-level seed VHDX files into per-VM folders.
- Update existing Hyper-V VM hard disk attachments to the new seed paths.
- Safe by default: dry-run unless -Apply is used.

Example:
  .\Migrate-SeedDisksToVmFolders.ps1 -SeedRoot "D:\HyperV\Seeds"

Apply:
  .\Migrate-SeedDisksToVmFolders.ps1 -SeedRoot "D:\HyperV\Seeds" -Apply
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$SeedRoot = "D:\HyperV\Seeds",

    [Parameter()]
    [switch]$Apply,

    [Parameter()]
    [bool]$RequireVmOff = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-Plan {
    param([string]$Message)
    if ($Apply) {
        Write-Host "[APPLY] $Message" -ForegroundColor Green
    }
    else {
        Write-Host "[DRY-RUN] $Message" -ForegroundColor Yellow
    }
}

function Normalize-Path {
    param([string]$Path)
    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\')
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

Write-Host "Hyper-V Seed Disk Folder Migrator" -ForegroundColor Cyan
Write-Host "SeedRoot: $SeedRoot"

if (-not (Test-Admin)) {
    throw "Please run PowerShell as Administrator."
}

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw "Hyper-V PowerShell module was not found."
}

if (-not (Test-Path -LiteralPath $SeedRoot)) {
    throw "SeedRoot does not exist: $SeedRoot"
}

$seedRootFull = Normalize-Path $SeedRoot

Write-Step "Loading Hyper-V VM information"

$vms = @(Get-VM)
$vmByName = @{}

foreach ($vm in $vms) {
    $vmByName[$vm.Name.ToLowerInvariant()] = $vm
}

$allDrives = @(
    foreach ($vm in $vms) {
        Get-VMHardDiskDrive -VMName $vm.Name | ForEach-Object {
            [PSCustomObject]@{
                VMName             = $vm.Name
                VMState            = $vm.State
                ControllerType     = $_.ControllerType
                ControllerNumber   = $_.ControllerNumber
                ControllerLocation = $_.ControllerLocation
                Path               = $_.Path
            }
        }
    }
)

$seedAttachedDrives = @(
    $allDrives | Where-Object {
        $_.Path -and (Normalize-Path $_.Path).StartsWith($seedRootFull, [System.StringComparison]::OrdinalIgnoreCase)
    }
)

Write-Host "VMs found: $($vms.Count)"
Write-Host "Seed-related VM disk attachments found: $($seedAttachedDrives.Count)"

Write-Step "Finding old root-level seed disks"

$rootSeedFiles = @(
    Get-ChildItem -LiteralPath $SeedRoot -File -Filter "*-seed.vhdx" |
        Where-Object {
            (Normalize-Path $_.DirectoryName) -eq $seedRootFull
        }
)

if ($rootSeedFiles.Count -eq 0) {
    Write-Host "No root-level *-seed.vhdx files found. Nothing to migrate." -ForegroundColor Green
    return
}

Write-Host "Root-level seed disks found: $($rootSeedFiles.Count)"

$results = New-Object System.Collections.Generic.List[object]

foreach ($seedFile in $rootSeedFiles) {
    $oldSeedPath = $seedFile.FullName
    $seedFileName = $seedFile.Name
    $seedBaseName = [System.IO.Path]::GetFileNameWithoutExtension($seedFileName)

    if (-not $seedBaseName.EndsWith("-seed", [System.StringComparison]::OrdinalIgnoreCase)) {
        $results.Add([PSCustomObject]@{
            File   = $oldSeedPath
            Status = "Skipped"
            Reason = "File does not end with -seed.vhdx"
        })
        continue
    }

    $derivedVmName = $seedBaseName.Substring(0, $seedBaseName.Length - 5)

    $matchingDrives = @(
        $seedAttachedDrives | Where-Object {
            $_.Path -and ((Normalize-Path $_.Path) -eq (Normalize-Path $oldSeedPath))
        }
    )

    if ($matchingDrives.Count -gt 1) {
        $results.Add([PSCustomObject]@{
            File   = $oldSeedPath
            Status = "Skipped"
            Reason = "More than one VM is attached to this seed disk"
        })
        continue
    }

    $drive = $null
    $vmName = $derivedVmName
    $vmState = $null

    if ($matchingDrives.Count -eq 1) {
        $drive = $matchingDrives[0]
        $vmName = $drive.VMName
        $vmState = $drive.VMState
    }

    $relatedAvhdx = @(
        Get-ChildItem -LiteralPath $SeedRoot -File -Filter "$seedBaseName*.avhdx" -ErrorAction SilentlyContinue
    )

    if ($relatedAvhdx.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            File   = $oldSeedPath
            Status = "Skipped"
            Reason = "Related AVHDX checkpoint/differencing file exists. Resolve checkpoints first before moving this seed."
        })
        continue
    }

    if ($RequireVmOff -and $drive -and $vmState -ne "Off") {
        $results.Add([PSCustomObject]@{
            File   = $oldSeedPath
            Status = "Skipped"
            Reason = "VM '$vmName' is not Off. Current state: $vmState"
        })
        continue
    }

    $targetFolder = Join-Path $SeedRoot $vmName
    $newSeedPath = Join-Path $targetFolder $seedFileName
    $oldRescuePath = "$oldSeedPath.rescue.txt"
    $newRescuePath = "$newSeedPath.rescue.txt"

    if (Test-Path -LiteralPath $newSeedPath) {
        $results.Add([PSCustomObject]@{
            File   = $oldSeedPath
            Status = "Skipped"
            Reason = "Target seed already exists: $newSeedPath"
        })
        continue
    }

    Write-Host ""
    Write-Host "VM/Seed: $vmName" -ForegroundColor Cyan
    Write-Plan "Create folder: $targetFolder"
    Write-Plan "Move seed: $oldSeedPath -> $newSeedPath"

    if (Test-Path -LiteralPath $oldRescuePath) {
        Write-Plan "Move rescue note: $oldRescuePath -> $newRescuePath"
    }

    if ($drive) {
        Write-Plan "Update VM '$vmName' disk attachment to: $newSeedPath"
    }
    else {
        Write-Host "[INFO] No existing VM attachment found for this seed. File will be moved only." -ForegroundColor DarkYellow
    }

    if ($Apply) {
        if (-not (Test-Path -LiteralPath $targetFolder)) {
            New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
        }

        Move-Item -LiteralPath $oldSeedPath -Destination $newSeedPath

        $movedRescue = $false
        if (Test-Path -LiteralPath $oldRescuePath) {
            Move-Item -LiteralPath $oldRescuePath -Destination $newRescuePath
            $movedRescue = $true
        }

        if ($drive) {
            try {
                Set-VMHardDiskDrive `
                    -VMName $vmName `
                    -ControllerType $drive.ControllerType `
                    -ControllerNumber $drive.ControllerNumber `
                    -ControllerLocation $drive.ControllerLocation `
                    -Path $newSeedPath
            }
            catch {
                Write-Warning "Failed to update VM attachment. Rolling back moved seed file."

                if (Test-Path -LiteralPath $newSeedPath) {
                    Move-Item -LiteralPath $newSeedPath -Destination $oldSeedPath -Force
                }

                if ($movedRescue -and (Test-Path -LiteralPath $newRescuePath)) {
                    Move-Item -LiteralPath $newRescuePath -Destination $oldRescuePath -Force
                }

                throw
            }
        }
    }

    $results.Add([PSCustomObject]@{
        VMName  = $vmName
        OldPath = $oldSeedPath
        NewPath = $newSeedPath
        Status  = if ($Apply) { "Migrated" } else { "Planned" }
        Reason  = ""
    })
}

Write-Step "Migration summary"

$results | Format-Table -AutoSize

if (-not $Apply) {
    Write-Host ""
    Write-Host "Dry-run only. No files were moved and no VM settings were changed." -ForegroundColor Yellow
    Write-Host "Run again with -Apply to perform the migration." -ForegroundColor Yellow
}
else {
    Write-Host ""
    Write-Host "Migration completed." -ForegroundColor Green
}