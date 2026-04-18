[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
}

function Read-Default {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$Default = ''
    )

    if ([string]::IsNullOrWhiteSpace($Default)) {
        $value = Read-Host $Prompt
    }
    else {
        $value = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = $Default
        }
    }

    return $value.Trim()
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$Default = $true
    )

    $defaultText = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $value = Read-Host ("{0} [{1}]" -f $Prompt, $defaultText)
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $Default
        }

        switch -Regex ($value.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
            default     { Write-Warning 'Please answer y or n.' }
        }
    }
}

function Read-RequiredPath {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$Default = '',
        [bool]$MustExist = $true
    )

    while ($true) {
        $path = Read-Default -Prompt $Prompt -Default $Default
        if ([string]::IsNullOrWhiteSpace($path)) {
            Write-Warning 'A value is required.'
            continue
        }

        if (-not $MustExist -or (Test-Path $path)) {
            return $path
        }

        Write-Warning "Path not found: $path"
    }
}

function Read-PositiveInt {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [int]$Default
    )

    while ($true) {
        $raw = Read-Default -Prompt $Prompt -Default ([string]$Default)
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0) {
            return $parsed
        }

        Write-Warning 'Please enter a positive integer.'
    }
}

function New-RandomHyperVMacAddress {
    # Hyper-V dynamic MACs commonly use 00-15-5D. Reusing that OUI keeps the value recognizable.
    $bytes = @(0x00, 0x15, 0x5D, (Get-Random -Minimum 0 -Maximum 256), (Get-Random -Minimum 0 -Maximum 256), (Get-Random -Minimum 0 -Maximum 256))
    return (($bytes | ForEach-Object { $_.ToString('X2') }) -join '-')
}

function Resolve-RepoRoot {
    $candidates = @()

    if ($PSScriptRoot) {
        $candidates += $PSScriptRoot
        $candidates += (Split-Path -Parent $PSScriptRoot)
    }

    $candidates += (Get-Location).Path

    foreach ($candidate in ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        $windowsDir = Join-Path $candidate 'windows'
        $cloudInitDir = Join-Path $candidate 'cloud-init'
        if ((Test-Path $windowsDir) -and (Test-Path $cloudInitDir)) {
            return $candidate
        }
    }

    return $PSScriptRoot
}

function Get-BytesFromGb {
    param([int]$Gb)
    return [int64]($Gb * 1GB)
}

try {
    Write-Host 'Hyper-V Golden Image VM Creator' -ForegroundColor Green
    Write-Host 'This script creates a NoCloud seed disk, then creates a brand-new VM from the golden VHDX.'

    Write-Section 'Project paths'
    $detectedRepoRoot = Resolve-RepoRoot
    $repoRoot = Read-RequiredPath -Prompt 'Repo root (must contain .\windows and .\cloud-init)' -Default $detectedRepoRoot

    $seedScript = Join-Path $repoRoot 'windows\New-NoCloudSeedDisk.ps1'
    $vmScript = Join-Path $repoRoot 'windows\New-HyperVVmFromGolden.ps1'
    $templateRoot = Join-Path $repoRoot 'cloud-init'

    foreach ($requiredFile in @($seedScript, $vmScript, $templateRoot)) {
        if (-not (Test-Path $requiredFile)) {
            throw "Required project path not found: $requiredFile"
        }
    }

    Write-Section 'VM identity'
    $vmName = Read-Default -Prompt 'VM name' -Default 'ubuntu-dev-01'
    if ([string]::IsNullOrWhiteSpace($vmName)) {
        throw 'VM name is required.'
    }

    $hostname = Read-Default -Prompt 'Hostname' -Default $vmName
    $adminUser = Read-Default -Prompt 'Primary admin username' -Default 'ubuntuadmin'
    $sshPublicKeyPath = Read-RequiredPath -Prompt 'SSH public key path' -Default "$HOME\.ssh\id_ed25519.pub"

    $autoMac = New-RandomHyperVMacAddress
    $macAddress = Read-Default -Prompt 'MAC address (same value will be used for seed + VM)' -Default $autoMac

    Write-Section 'Storage and switch'
    $goldenVhdxPath = Read-RequiredPath -Prompt 'Golden VHDX path' -Default 'D:\HyperV\Golden\ubuntu-24.04-golden-base.vhdx'
    $vmRoot = Read-Default -Prompt 'VM root folder' -Default 'D:\HyperV\VMs'
    $seedRoot = Read-Default -Prompt 'Seed disks folder' -Default 'D:\HyperV\Seeds'
    $seedDiskPath = Join-Path $seedRoot ("{0}-seed.vhdx" -f $vmName)
    Write-Host "Seed disk will be created at: $seedDiskPath"

    $seedOnly = Read-YesNo -Prompt 'Only create/overwrite the seed disk and skip VM creation?' -Default $false

    $switchName = $null
    if (-not $seedOnly) {
        $switchName = Read-Default -Prompt 'Hyper-V switch name' -Default 'Default Switch'
        if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
            throw "Hyper-V switch not found: $switchName"
        }
    }

    Write-Section 'Networking'
    $useStatic = Read-YesNo -Prompt 'Use static IP networking?' -Default $false
    $interfaceName = Read-Default -Prompt 'Cloud-init interface name' -Default 'lan0'

    $staticIpCidr = $null
    $gateway = $null
    $dnsServers = @('1.1.1.1', '8.8.8.8')

    if ($useStatic) {
        $staticIpCidr = Read-Default -Prompt 'Static IP/CIDR (example 192.168.201.10/24)'
        $gateway = Read-Default -Prompt 'Gateway (example 192.168.201.1)'
        $dnsInput = Read-Default -Prompt 'DNS servers comma separated' -Default '1.1.1.1,8.8.8.8'
        $dnsServers = @($dnsInput.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if (-not $dnsServers -or $dnsServers.Count -eq 0) {
            $dnsServers = @('1.1.1.1', '8.8.8.8')
        }
    }

    Write-Section 'Rescue user'
    $enableRescueUser = Read-YesNo -Prompt 'Enable rescue user?' -Default $true
    $rescueUser = 'rescueadmin'
    $rescueSshPublicKeyPath = $null
    $rescuePassword = $null
    $enableRescueSshPassword = $false

    if ($enableRescueUser) {
        $rescueUser = Read-Default -Prompt 'Rescue username' -Default 'rescueadmin'
        $useSeparateRescueKey = Read-YesNo -Prompt 'Use a different SSH public key for rescue user?' -Default $false
        if ($useSeparateRescueKey) {
            $rescueSshPublicKeyPath = Read-RequiredPath -Prompt 'Rescue SSH public key path'
        }

        $enableRescueSshPassword = Read-YesNo -Prompt 'Enable password SSH login for rescue user?' -Default $false
        if ($enableRescueSshPassword) {
            $rescuePassword = Read-Host 'Rescue password (leave blank to auto-generate)'
            if (-not [string]::IsNullOrWhiteSpace($rescuePassword)) {
                $rescuePassword = $rescuePassword.Trim()
            }
            else {
                $rescuePassword = $null
            }
        }
        else {
            $setRescuePassword = Read-YesNo -Prompt 'Set a rescue password anyway (for console/sudo use)?' -Default $false
            if ($setRescuePassword) {
                $rescuePassword = Read-Host 'Rescue password (leave blank to auto-generate)'
                if (-not [string]::IsNullOrWhiteSpace($rescuePassword)) {
                    $rescuePassword = $rescuePassword.Trim()
                }
                else {
                    $rescuePassword = $null
                }
            }
        }
    }

    $memoryStartupGb = 4
    $minimumMemoryGb = 2
    $maximumMemoryGb = 8
    $processorCount = 2
    $seedControllerLocation = 1
    $startAfterCreate = $true

    if (-not $seedOnly) {
        Write-Section 'VM sizing'
        $memoryStartupGb = Read-PositiveInt -Prompt 'Startup memory in GB' -Default 4
        $minimumMemoryGb = Read-PositiveInt -Prompt 'Minimum memory in GB' -Default 2
        $maximumMemoryGb = Read-PositiveInt -Prompt 'Maximum memory in GB' -Default 8
        if ($minimumMemoryGb -gt $memoryStartupGb) {
            throw 'Minimum memory cannot be greater than startup memory.'
        }
        if ($maximumMemoryGb -lt $memoryStartupGb) {
            throw 'Maximum memory cannot be less than startup memory.'
        }

        $processorCount = Read-PositiveInt -Prompt 'Processor count' -Default 2
        $seedControllerLocation = Read-PositiveInt -Prompt 'Seed disk SCSI controller location' -Default 1
        $startAfterCreate = Read-YesNo -Prompt 'Start the VM immediately after creation?' -Default $true
    }

    Write-Section 'Summary'
    $summary = [ordered]@{
        'Repo root' = $repoRoot
        'VM name' = $vmName
        'Hostname' = $hostname
        'Admin user' = $adminUser
        'SSH public key' = $sshPublicKeyPath
        'Golden VHDX' = $goldenVhdxPath
        'VM root' = $vmRoot
        'Seed disk' = $seedDiskPath
        'Mode' = $(if ($seedOnly) { 'Seed only (overwrite if exists)' } else { 'Seed + VM creation' })
        'Switch' = $(if ($seedOnly) { '-' } else { $switchName })
        'MAC address' = $macAddress
        'Interface name' = $interfaceName
        'Static networking' = $useStatic
        'Static IP/CIDR' = $(if ($useStatic) { $staticIpCidr } else { 'DHCP' })
        'Gateway' = $(if ($useStatic) { $gateway } else { '-' })
        'DNS servers' = $(if ($useStatic) { ($dnsServers -join ', ') } else { '-' })
        'Rescue user enabled' = $enableRescueUser
        'Rescue username' = $(if ($enableRescueUser) { $rescueUser } else { '-' })
        'Startup memory' = $(if ($seedOnly) { '-' } else { "$memoryStartupGb GB" })
        'Minimum memory' = $(if ($seedOnly) { '-' } else { "$minimumMemoryGb GB" })
        'Maximum memory' = $(if ($seedOnly) { '-' } else { "$maximumMemoryGb GB" })
        'Processors' = $(if ($seedOnly) { '-' } else { $processorCount })
        'Seed controller location' = $(if ($seedOnly) { '-' } else { $seedControllerLocation })
        'Start after create' = $(if ($seedOnly) { '-' } else { $startAfterCreate })
    }

    $summary.GetEnumerator() | ForEach-Object {
        Write-Host ("{0,-24}: {1}" -f $_.Key, $_.Value)
    }

    $proceedPrompt = if ($seedOnly) { 'Proceed with seed disk creation/overwrite?' } else { 'Proceed with seed + VM creation?' }
    if (-not (Read-YesNo -Prompt $proceedPrompt -Default $true)) {
        Write-Host 'Cancelled by user.' -ForegroundColor Yellow
        return
    }

    Write-Section 'Creating seed disk'
    $seedParams = @{
        SeedDiskPath = $seedDiskPath
        Hostname = $hostname
        AdminUser = $adminUser
        SshPublicKeyPath = $sshPublicKeyPath
        InterfaceMacAddress = $macAddress
        TemplateRoot = $templateRoot
        InterfaceName = $interfaceName
        EnableRescueUser = $enableRescueUser
    }

    if ($useStatic) {
        $seedParams.StaticIpCidr = $staticIpCidr
        $seedParams.Gateway = $gateway
        $seedParams.DnsServers = $dnsServers
    }

    if ($enableRescueUser) {
        $seedParams.RescueUser = $rescueUser
        if ($rescueSshPublicKeyPath) {
            $seedParams.RescueSshPublicKeyPath = $rescueSshPublicKeyPath
        }
        if ($null -ne $rescuePassword) {
            $seedParams.RescuePassword = $rescuePassword
        }
        if ($enableRescueSshPassword) {
            $seedParams.EnableRescueSshPassword = $true
        }
    }

    & $seedScript @seedParams

    if ($seedOnly) {
        Write-Section 'Done'
        Write-Host "Seed disk created successfully: $seedDiskPath" -ForegroundColor Green
        Write-Host "Seed summary file: $seedDiskPath.rescue.txt"
        return
    }

    Write-Section 'Creating VM from golden disk'
    $vmParams = @{
        VmName = $vmName
        GoldenVhdxPath = $goldenVhdxPath
        VmRoot = $vmRoot
        SwitchName = $switchName
        SeedDiskPath = $seedDiskPath
        StaticMacAddress = $macAddress
        MemoryStartupBytes = (Get-BytesFromGb -Gb $memoryStartupGb)
        ProcessorCount = $processorCount
        MinimumMemoryBytes = (Get-BytesFromGb -Gb $minimumMemoryGb)
        MaximumMemoryBytes = (Get-BytesFromGb -Gb $maximumMemoryGb)
        SeedControllerLocation = $seedControllerLocation
    }

    if ($startAfterCreate) {
        $vmParams.StartAfterCreate = $true
    }

    & $vmScript @vmParams

    Write-Section 'Done'
    Write-Host "VM created successfully: $vmName" -ForegroundColor Green
    Write-Host "Seed summary file: $seedDiskPath.rescue.txt"
    Write-Host 'Next checks:'
    Write-Host "  Get-VM -Name $vmName | Format-List Name, State, Status"
    Write-Host "  Get-VMNetworkAdapter -VMName $vmName | Format-List *"
    if ($useStatic) {
        Write-Host "  ssh -i $($sshPublicKeyPath -replace '\.pub$','') $adminUser@$($staticIpCidr -replace '/.*$','')"
    }
    else {
        Write-Host "  Find the VM IP, then SSH as: $adminUser@<vm-ip>"
    }
}
catch {
    Write-Error $_
    exit 1
}
