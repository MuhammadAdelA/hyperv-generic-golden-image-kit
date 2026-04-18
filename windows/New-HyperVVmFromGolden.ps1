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

if (-not (Test-Path $GoldenVhdxPath)) {
    throw "Golden VHDX not found: $GoldenVhdxPath"
}
if (-not (Test-Path $SeedDiskPath)) {
    throw "Seed disk not found: $SeedDiskPath"
}
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Hyper-V switch not found: $SwitchName"
}

$vmPath = Join-Path $VmRoot $VmName
$osDiskPath = Join-Path $vmPath ("{0}.vhdx" -f $VmName)

if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
    throw "A VM with this name already exists: $VmName"
}
if (Test-Path $vmPath) {
    throw "VM path already exists: $vmPath"
}

New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
Copy-Item $GoldenVhdxPath $osDiskPath -Force

New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $MemoryStartupBytes -VHDPath $osDiskPath -Path $vmPath -SwitchName $SwitchName | Out-Null
Set-VMProcessor -VMName $VmName -Count $ProcessorCount
Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $true -MinimumBytes $MinimumMemoryBytes -StartupBytes $MemoryStartupBytes -MaximumBytes $MaximumMemoryBytes
Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
Set-VMNetworkAdapter -VMName $VmName -StaticMacAddress (Convert-ToHyperVMacAddress -MacAddress $StaticMacAddress)
Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $SeedControllerLocation -Path $SeedDiskPath

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
