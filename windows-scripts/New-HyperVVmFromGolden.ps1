param(
    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [Parameter(Mandatory = $true)]
    [string]$GoldenVhdxPath,

    [Parameter(Mandatory = $true)]
    [string]$VmRoot,

    [Parameter(Mandatory = $true)]
    [string]$SwitchName,

    [Parameter(Mandatory = $true)]
    [string]$SeedDiskPath,

    [Parameter(Mandatory = $true)]
    [string]$StaticMacAddress,

    [int64]$MemoryStartupBytes = 4GB,
    [int]$ProcessorCount = 2,
    [int64]$MinimumMemoryBytes = 2GB,
    [int64]$MaximumMemoryBytes = 8GB,
    [int]$SeedControllerLocation = 1,
    [switch]$StartAfterCreate
)

$ErrorActionPreference = 'Stop'

function Convert-ToHyperVMacAddress {
    param([string]$MacAddress)

    $normalized = ($MacAddress -replace '[:\-\.]', '').Trim().ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{12}$') {
        throw "StaticMacAddress must contain 12 hex digits. Examples: 00155D321001 or 00-15-5D-32-10-01. Got: $MacAddress"
    }

    return $normalized
}

function Grant-VmDiskAccess {
    param([Parameter(Mandatory = $true)][string]$VmName, [Parameter(Mandatory = $true)][string]$DiskPath)
    $vm = Get-VM -Name $VmName -ErrorAction Stop
    if (-not $vm.VMId) { throw "Could not resolve the VM ID for: $VmName" }
    $identity = "NT VIRTUAL MACHINE\$($vm.VMId)"
    $output = & icacls.exe $DiskPath /grant "${identity}:(F)" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to grant VM access to disk '$DiskPath'. icacls: $($output -join ' ')" }
}

function Test-SafeVmName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 128) { return $false }
    if ($Name -in @('.', '..') -or $Name.EndsWith('.') -or $Name.EndsWith(' ')) { return $false }
    if ($Name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $false }
    if ($Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') { return $false }
    return $true
}

if (-not (Test-Path $GoldenVhdxPath)) {
    throw "Golden VHDX not found: $GoldenVhdxPath"
}
if (-not (Test-Path $SeedDiskPath)) {
    throw "Seed disk not found: $SeedDiskPath"
}
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Hyper-V switch not found: $SwitchName"
}

if (-not (Test-SafeVmName $VmName)) { throw "Unsafe VM name: $VmName" }
$resolvedVmRoot = [System.IO.Path]::GetFullPath($VmRoot).TrimEnd('\')
$vmPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedVmRoot $VmName)).TrimEnd('\')
if (-not $vmPath.StartsWith(($resolvedVmRoot + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "VM path escapes VmRoot: $vmPath"
}
$osDiskPath = Join-Path $vmPath ("{0}.vhdx" -f $VmName)

if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
    throw "A VM with this name already exists: $VmName"
}
if (Test-Path $vmPath) {
    throw "VM path already exists: $vmPath"
}
if ($MinimumMemoryBytes -gt $MemoryStartupBytes -or $MemoryStartupBytes -gt $MaximumMemoryBytes) {
    throw 'Memory values must satisfy Minimum <= Startup <= Maximum.'
}

$createdVmPath = $false
$createdVm = $false
try {
    New-Item -ItemType Directory -Path $vmPath | Out-Null
    $createdVmPath = $true
    Copy-Item -LiteralPath $GoldenVhdxPath -Destination $osDiskPath

    New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $MemoryStartupBytes -VHDPath $osDiskPath -Path $vmPath -SwitchName $SwitchName | Out-Null
    $createdVm = $true
    Set-VMProcessor -VMName $VmName -Count $ProcessorCount
    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $true -MinimumBytes $MinimumMemoryBytes -StartupBytes $MemoryStartupBytes -MaximumBytes $MaximumMemoryBytes
    Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
    Set-VMNetworkAdapter -VMName $VmName -StaticMacAddress (Convert-ToHyperVMacAddress -MacAddress $StaticMacAddress)
    Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $SeedControllerLocation -Path $SeedDiskPath
    Grant-VmDiskAccess -VmName $VmName -DiskPath $SeedDiskPath

    Write-Host "Created VM: $VmName"
    Write-Host "OS disk : $osDiskPath"
    Write-Host "Seed disk: $SeedDiskPath"
    Write-Host "Static MAC: $(Convert-ToHyperVMacAddress -MacAddress $StaticMacAddress)"

    if ($StartAfterCreate) {
        Start-VM -Name $VmName | Out-Null
        Write-Host 'VM started.'
    }
    else {
        Write-Host "Next step: Start-VM -Name $VmName"
    }
}
catch {
    $originalError = $_
    Write-Warning "VM creation failed; rolling back resources created by this run. $($originalError.Exception.Message)"
    $vmStillRegistered = $false
    $registeredVm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    $registeredVmOwnedByRun = $createdVm
    if ($registeredVm -and -not $registeredVmOwnedByRun -and $registeredVm.Path) {
        $registeredPath = [System.IO.Path]::GetFullPath([string]$registeredVm.Path).TrimEnd('\')
        $registeredVmOwnedByRun = $registeredPath.Equals($vmPath, [System.StringComparison]::OrdinalIgnoreCase)
    }

    if ($registeredVm -and $registeredVmOwnedByRun) {
        try {
            if ($registeredVm.State -ne 'Off') {
                Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop
            }
            Remove-VM -Name $VmName -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Rollback could not unregister VM '$VmName'; its files will be preserved. $($_.Exception.Message)"
        }
    }
    elseif ($registeredVm) {
        Write-Warning "A VM named '$VmName' is registered at another path; rollback will not modify it."
    }

    $vmStillRegistered = [bool](Get-VM -Name $VmName -ErrorAction SilentlyContinue)
    if ($createdVmPath -and -not $vmStillRegistered -and (Test-Path -LiteralPath $vmPath)) {
        try { Remove-Item -LiteralPath $vmPath -Recurse -Force -ErrorAction Stop }
        catch { Write-Warning "Rollback could not remove VM path '$vmPath'. $($_.Exception.Message)" }
    }
    throw $originalError
}
