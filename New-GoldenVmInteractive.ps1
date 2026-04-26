[CmdletBinding()]
param(
    # Automation/config inputs. In -Auto mode, environment-specific values come from config, then CLI overrides.
    [string]$RepoRoot,
    [string]$ConfigPath,
    [string]$DeviceName,
    [string]$Hostname,
    [string]$AdminUser = 'ubuntu',
    [string]$SshPublicKeyPath,
    [string]$MacAddress,

    [string]$GoldenVhdxPath,
    [string]$VmRoot,
    [string]$SeedRoot,
    [string]$SeedDiskPath,
    [string]$SwitchName,
    [bool]$SeedOnly = $false,

    [bool]$UseStatic = $false,
    [string]$StaticIpCidr,
    [string]$IpPrefix,
    [ValidateRange(1,254)][int]$IpOctet,
    [string]$Gateway,
    [string[]]$DnsServers,
    [string]$InterfaceName = 'lan0',

    [bool]$EnableRescueUser = $true,
    [string]$RescueUser = 'rescue',
    [string]$RescueSshPublicKeyPath,
    [string]$Password,
    [bool]$EnableRescueSshPassword = $false,
    [bool]$SetRescuePassword = $false,

    [ValidateRange(1,1024)][int]$MemoryStartupGb = 4,
    [ValidateRange(1,1024)][int]$MinimumMemoryGb = 2,
    [ValidateRange(1,1024)][int]$MaximumMemoryGb = 8,
    [ValidateRange(1,256)][int]$ProcessorCount = 2,
    [ValidateRange(0,63)][int]$SeedControllerLocation = 1,
    [bool]$StartAfterCreate = $true,

    [switch]$Auto
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AutoMode = $Auto.IsPresent
$script:OriginalBoundParameters = @{} + $PSBoundParameters

function Write-Section {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
}

function Assert-Command {
    param([Parameter(Mandatory = $true)][string[]]$Name)

    foreach ($cmd in $Name) {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            throw "Required command not found: $cmd. Run from an elevated PowerShell session on a Hyper-V host."
        }
    }
}


function Resolve-DefaultConfigPath {
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    return (Join-Path $root 'New-GoldenVmInteractive.config.psd1')
}

function Import-WrapperConfig {
    param(
        [AllowNull()][string]$Path,
        [bool]$Required = $false,
        [bool]$Explicit = $false
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @{}
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($Required -or $Explicit) {
            $examplePath = Join-Path (Split-Path -Parent $Path) 'New-GoldenVmInteractive.config.example.psd1'
            throw "Config file not found: $Path. Copy/fill the example config first: $examplePath, or pass -ConfigPath with a valid file."
        }

        return @{}
    }

    try {
        $data = Import-PowerShellDataFile -Path $Path
    }
    catch {
        throw "Failed to read config file: $Path. $($_.Exception.Message)"
    }

    if ($null -eq $data) {
        return @{}
    }

    $knownKeys = @(
        'RepoRoot', 'DeviceName', 'Hostname', 'AdminUser', 'SshPublicKeyPath', 'MacAddress',
        'GoldenVhdxPath', 'VmRoot', 'SeedRoot', 'SeedDiskPath', 'SwitchName', 'SeedOnly',
        'UseStatic', 'StaticIpCidr', 'IpPrefix', 'IpOctet', 'Gateway', 'DnsServers', 'InterfaceName',
        'EnableRescueUser', 'RescueUser', 'RescueSshPublicKeyPath', 'Password',
        'EnableRescueSshPassword', 'SetRescuePassword',
        'MemoryStartupGb', 'MinimumMemoryGb', 'MaximumMemoryGb', 'ProcessorCount',
        'SeedControllerLocation', 'StartAfterCreate'
    )

    $unknownKeys = @($data.Keys | Where-Object { $_ -notin $knownKeys })
    if ($unknownKeys.Count -gt 0) {
        throw "Unknown config key(s) in ${Path}: $($unknownKeys -join ', '). Check spelling or remove unsupported keys."
    }

    return $data
}

function Get-EffectiveSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$CurrentValue
    )

    if ($script:OriginalBoundParameters.ContainsKey($Name)) {
        return $CurrentValue
    }

    if ($script:WrapperConfig.ContainsKey($Name)) {
        return $script:WrapperConfig[$Name]
    }

    return $CurrentValue
}

function Apply-WrapperConfig {
    $configPathExplicit = $script:OriginalBoundParameters.ContainsKey('ConfigPath')
    $explicitAutomationInputs = @($script:OriginalBoundParameters.Keys | Where-Object { $_ -notin @('Auto', 'ConfigPath') })
    $configRequiredForBareAuto = $script:AutoMode -and (-not $configPathExplicit) -and ($explicitAutomationInputs.Count -eq 0)

    $configPathFinal = if ($configPathExplicit) { $ConfigPath } else { Resolve-DefaultConfigPath }
    $script:ResolvedConfigPath = $configPathFinal
    $script:WrapperConfig = Import-WrapperConfig -Path $configPathFinal -Required:$configRequiredForBareAuto -Explicit:$configPathExplicit

    if ($script:WrapperConfig.Count -gt 0) {
        Write-Host "Config loaded: $configPathFinal" -ForegroundColor DarkCyan
    }
    elseif ($configRequiredForBareAuto) {
        throw "Bare -Auto requires a filled config file. Expected config: $configPathFinal. To run without a config file, pass the required values as parameters."
    }

    # CLI parameters always win. Config values win over built-in script defaults.
    $script:ConfigAppliedKeys = @()
    foreach ($key in $script:WrapperConfig.Keys) {
        if (-not $script:OriginalBoundParameters.ContainsKey($key)) {
            $script:ConfigAppliedKeys += $key
        }
    }
}

function Read-Default {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [AllowNull()][string]$Default = ''
    )

    if ($null -eq $Default) {
        $Default = ''
    }

    if ($script:AutoMode) {
        return $Default.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($Default)) {
        $value = Read-Host $Prompt
    }
    else {
        $value = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = $Default
        }
    }

    if ($null -eq $value) {
        return ''
    }

    return $value.Trim()
}

function Read-RequiredValue {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [AllowNull()][string]$Default = ''
    )

    while ($true) {
        $value = Read-Default -Prompt $Prompt -Default $Default
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }

        if ($script:AutoMode) {
            throw "A value is required for: $Prompt"
        }

        Write-Warning 'A value is required.'
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$Default = $true
    )

    if ($script:AutoMode) {
        return $Default
    }

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
        [AllowNull()][string]$Default = '',
        [bool]$MustExist = $true
    )

    while ($true) {
        $path = Read-RequiredValue -Prompt $Prompt -Default $Default
        if (-not $MustExist -or (Test-Path $path)) {
            return $path
        }

        if ($script:AutoMode) {
            throw "Path not found: $path"
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

        if ($script:AutoMode) {
            throw "Please provide a positive integer for: $Prompt"
        }

        Write-Warning 'Please enter a positive integer.'
    }
}

function Read-IpLastOctet {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [AllowNull()][string]$Default = ''
    )

    while ($true) {
        $raw = Read-Default -Prompt $Prompt -Default $Default
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 254) {
            return [string]$parsed
        }

        if ($script:AutoMode) {
            throw "Please provide an IP last octet between 1 and 254 for: $Prompt"
        }

        Write-Warning 'Please enter a value between 1 and 254.'
    }
}

function Read-OptionalPassword {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [AllowNull()][string]$Default = ''
    )

    if ($script:AutoMode) {
        if ([string]::IsNullOrWhiteSpace($Default)) {
            return $null
        }
        return $Default.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($Default)) {
        $value = Read-Host $Prompt
    }
    else {
        $value = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = $Default
        }
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value.Trim()
}

function New-RandomHyperVMacAddress {
    # Hyper-V dynamic MACs commonly use 00-15-5D. Reusing that OUI keeps the value recognizable.
    $bytes = @(0x00, 0x15, 0x5D, (Get-Random -Minimum 0 -Maximum 256), (Get-Random -Minimum 0 -Maximum 256), (Get-Random -Minimum 0 -Maximum 256))
    return (($bytes | ForEach-Object { $_.ToString('X2') }) -join '-')
}

function Resolve-RepoRoot {
    $candidates = @()

    if ($RepoRoot) {
        $candidates += $RepoRoot
    }

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

    return $RepoRoot
}

function Get-BytesFromGb {
    param([int]$Gb)
    return [int64]($Gb * 1GB)
}

function ConvertFrom-DnsInput {
    param([AllowNull()][string[]]$Value)

    if (-not $Value -or $Value.Count -eq 0) {
        return @()
    }

    return @(
        $Value |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Resolve-StaticIp {
    param(
        [string]$ProvidedStaticIpCidr,
        [string]$ProvidedIpPrefix,
        [int]$ProvidedIpOctet
    )

    if (-not [string]::IsNullOrWhiteSpace($ProvidedStaticIpCidr)) {
        return $ProvidedStaticIpCidr.Trim()
    }

    $prefix = Read-RequiredValue -Prompt 'Static IP prefix (first three octets, e.g. a.b.c)' -Default $ProvidedIpPrefix
    $octetDefault = if ($ProvidedIpOctet -ge 1) { [string]$ProvidedIpOctet } else { '' }
    $selectedIpOctet = Read-IpLastOctet -Prompt ("IP last octet for {0}.[x]" -f $prefix) -Default $octetDefault
    return "{0}.{1}/24" -f $prefix.Trim().TrimEnd('.'), $selectedIpOctet
}

try {
    Write-Host 'Hyper-V Golden Image VM Creator' -ForegroundColor Green
    Write-Host 'This script creates a NoCloud seed disk, then creates a brand-new VM from the golden VHDX.'

    Apply-WrapperConfig

    $RepoRoot = Get-EffectiveSetting -Name 'RepoRoot' -CurrentValue $RepoRoot
    $DeviceName = Get-EffectiveSetting -Name 'DeviceName' -CurrentValue $DeviceName
    $Hostname = Get-EffectiveSetting -Name 'Hostname' -CurrentValue $Hostname
    $AdminUser = Get-EffectiveSetting -Name 'AdminUser' -CurrentValue $AdminUser
    $SshPublicKeyPath = Get-EffectiveSetting -Name 'SshPublicKeyPath' -CurrentValue $SshPublicKeyPath
    $MacAddress = Get-EffectiveSetting -Name 'MacAddress' -CurrentValue $MacAddress
    $GoldenVhdxPath = Get-EffectiveSetting -Name 'GoldenVhdxPath' -CurrentValue $GoldenVhdxPath
    $VmRoot = Get-EffectiveSetting -Name 'VmRoot' -CurrentValue $VmRoot
    $SeedRoot = Get-EffectiveSetting -Name 'SeedRoot' -CurrentValue $SeedRoot
    $SeedDiskPath = Get-EffectiveSetting -Name 'SeedDiskPath' -CurrentValue $SeedDiskPath
    $SwitchName = Get-EffectiveSetting -Name 'SwitchName' -CurrentValue $SwitchName
    $SeedOnly = [bool](Get-EffectiveSetting -Name 'SeedOnly' -CurrentValue $SeedOnly)
    $UseStatic = [bool](Get-EffectiveSetting -Name 'UseStatic' -CurrentValue $UseStatic)
    $StaticIpCidr = Get-EffectiveSetting -Name 'StaticIpCidr' -CurrentValue $StaticIpCidr
    $IpPrefix = Get-EffectiveSetting -Name 'IpPrefix' -CurrentValue $IpPrefix
    $IpOctet = [int](Get-EffectiveSetting -Name 'IpOctet' -CurrentValue $IpOctet)
    $Gateway = Get-EffectiveSetting -Name 'Gateway' -CurrentValue $Gateway
    $DnsServers = @(Get-EffectiveSetting -Name 'DnsServers' -CurrentValue $DnsServers)
    $InterfaceName = Get-EffectiveSetting -Name 'InterfaceName' -CurrentValue $InterfaceName
    $EnableRescueUser = [bool](Get-EffectiveSetting -Name 'EnableRescueUser' -CurrentValue $EnableRescueUser)
    $RescueUser = Get-EffectiveSetting -Name 'RescueUser' -CurrentValue $RescueUser
    $RescueSshPublicKeyPath = Get-EffectiveSetting -Name 'RescueSshPublicKeyPath' -CurrentValue $RescueSshPublicKeyPath
    $Password = Get-EffectiveSetting -Name 'Password' -CurrentValue $Password
    $EnableRescueSshPassword = [bool](Get-EffectiveSetting -Name 'EnableRescueSshPassword' -CurrentValue $EnableRescueSshPassword)
    $SetRescuePassword = [bool](Get-EffectiveSetting -Name 'SetRescuePassword' -CurrentValue $SetRescuePassword)
    $MemoryStartupGb = [int](Get-EffectiveSetting -Name 'MemoryStartupGb' -CurrentValue $MemoryStartupGb)
    $MinimumMemoryGb = [int](Get-EffectiveSetting -Name 'MinimumMemoryGb' -CurrentValue $MinimumMemoryGb)
    $MaximumMemoryGb = [int](Get-EffectiveSetting -Name 'MaximumMemoryGb' -CurrentValue $MaximumMemoryGb)
    $ProcessorCount = [int](Get-EffectiveSetting -Name 'ProcessorCount' -CurrentValue $ProcessorCount)
    $SeedControllerLocation = [int](Get-EffectiveSetting -Name 'SeedControllerLocation' -CurrentValue $SeedControllerLocation)
    $StartAfterCreate = [bool](Get-EffectiveSetting -Name 'StartAfterCreate' -CurrentValue $StartAfterCreate)
    if ($script:AutoMode) {
        Write-Host 'Auto mode is enabled. Values are loaded from config first, then overridden by CLI parameters.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'Press Enter to accept suggested values. Blank required values will be rejected.' -ForegroundColor Yellow
    }

    Assert-Command -Name @('New-VHD', 'Mount-VHD', 'Get-Disk', 'Initialize-Disk', 'New-Partition', 'Format-Volume', 'Dismount-DiskImage')

    Write-Section 'Project paths'
    $detectedRepoRoot = Resolve-RepoRoot
    $repoRootFinal = Read-RequiredPath -Prompt 'Repo root (must contain .\windows and .\cloud-init)' -Default $detectedRepoRoot

    $seedScript = Join-Path $repoRootFinal 'windows\New-NoCloudSeedDisk.ps1'
    $vmScript = Join-Path $repoRootFinal 'windows\New-HyperVVmFromGolden.ps1'
    $templateRoot = Join-Path $repoRootFinal 'cloud-init'

    foreach ($requiredFile in @($seedScript, $vmScript, $templateRoot)) {
        if (-not (Test-Path $requiredFile)) {
            throw "Required project path not found: $requiredFile"
        }
    }

    Write-Section 'VM identity'
    $vmName = Read-RequiredValue -Prompt 'VM name' -Default $DeviceName
    $hostnameFinal = Read-RequiredValue -Prompt 'Hostname' -Default $(if ($Hostname) { $Hostname } else { $vmName })
    $adminUserFinal = Read-RequiredValue -Prompt 'Primary admin username' -Default $AdminUser
    $sshPublicKeyPathFinal = Read-RequiredPath -Prompt 'SSH public key path' -Default $SshPublicKeyPath

    $autoMac = New-RandomHyperVMacAddress
    $macAddressFinal = Read-RequiredValue -Prompt 'MAC address (same value will be used for seed + VM)' -Default $(if ($MacAddress) { $MacAddress } else { $autoMac })

    Write-Section 'Storage and switch'
    $seedOnlyFinal = Read-YesNo -Prompt 'Only create/overwrite the seed disk and skip VM creation?' -Default $SeedOnly

    $goldenVhdxPathFinal = $null
    if (-not $seedOnlyFinal) {
        $goldenVhdxPathFinal = Read-RequiredPath -Prompt 'Golden VHDX path' -Default $GoldenVhdxPath
    }

    if (-not $SeedDiskPath) {
        $seedRootFinal = Read-RequiredPath -Prompt 'Seed disks folder' -Default $SeedRoot -MustExist $false
        $seedDiskPathFinal = Join-Path $seedRootFinal ("{0}-seed.vhdx" -f $vmName)
    }
    else {
        $seedDiskPathFinal = $SeedDiskPath
    }
    Write-Host "Seed disk will be created at: $seedDiskPathFinal"

    $vmRootFinal = $null
    $switchNameFinal = $null
    if (-not $seedOnlyFinal) {
        $vmRootFinal = Read-RequiredPath -Prompt 'VM root folder' -Default $VmRoot -MustExist $false
        $switchNameFinal = Read-RequiredValue -Prompt 'Hyper-V switch name' -Default $SwitchName
        if (-not (Get-VMSwitch -Name $switchNameFinal -ErrorAction SilentlyContinue)) {
            throw "Hyper-V switch not found: $switchNameFinal"
        }
    }

    Write-Section 'Networking'
    $useStaticFinal = Read-YesNo -Prompt 'Use static IP networking?' -Default $UseStatic
    $interfaceNameFinal = Read-RequiredValue -Prompt 'Cloud-init interface name' -Default $InterfaceName

    $staticIpCidrFinal = $null
    $gatewayFinal = $null
    $dnsServersFinal = @()

    if ($useStaticFinal) {
        $staticIpCidrFinal = Resolve-StaticIp -ProvidedStaticIpCidr $StaticIpCidr -ProvidedIpPrefix $IpPrefix -ProvidedIpOctet $IpOctet
        Write-Host "Static IP/CIDR resolved to: $staticIpCidrFinal"
        $gatewayFinal = Read-RequiredValue -Prompt 'Gateway' -Default $Gateway

        $dnsServersFinal = ConvertFrom-DnsInput -Value $DnsServers
        if (-not $dnsServersFinal -or $dnsServersFinal.Count -eq 0) {
            $dnsInput = Read-RequiredValue -Prompt 'DNS servers comma separated' -Default ''
            $dnsServersFinal = ConvertFrom-DnsInput -Value @($dnsInput)
        }
    }

    Write-Section 'Rescue user'
    $enableRescueUserFinal = Read-YesNo -Prompt 'Enable rescue user?' -Default $EnableRescueUser
    $rescueUserFinal = $RescueUser
    $rescueSshPublicKeyPathFinal = $null
    $rescuePasswordFinal = $null
    $enableRescueSshPasswordFinal = $false

    if ($enableRescueUserFinal) {
        $rescueUserFinal = Read-RequiredValue -Prompt 'Rescue username' -Default $RescueUser
        $useSeparateRescueKey = Read-YesNo -Prompt 'Use a different SSH public key for rescue user?' -Default (-not [string]::IsNullOrWhiteSpace($RescueSshPublicKeyPath))
        if ($useSeparateRescueKey) {
            $rescueSshPublicKeyPathFinal = Read-RequiredPath -Prompt 'Rescue SSH public key path' -Default $RescueSshPublicKeyPath
        }

        $enableRescueSshPasswordFinal = Read-YesNo -Prompt 'Enable password SSH login for rescue user?' -Default $EnableRescueSshPassword
        $shouldSetPassword = $enableRescueSshPasswordFinal -or $SetRescuePassword -or (-not [string]::IsNullOrWhiteSpace($Password))
        if ($shouldSetPassword) {
            $rescuePasswordFinal = Read-OptionalPassword -Prompt 'Rescue password (leave blank to auto-generate)' -Default $Password
        }
    }

    $memoryStartupGbFinal = $MemoryStartupGb
    $minimumMemoryGbFinal = $MinimumMemoryGb
    $maximumMemoryGbFinal = $MaximumMemoryGb
    $processorCountFinal = $ProcessorCount
    $seedControllerLocationFinal = $SeedControllerLocation
    $startAfterCreateFinal = $StartAfterCreate

    if (-not $seedOnlyFinal) {
        Assert-Command -Name @('New-VM', 'Get-VM', 'Set-VMProcessor', 'Set-VMMemory', 'Set-VMFirmware', 'Set-VMNetworkAdapter', 'Add-VMHardDiskDrive')

        Write-Section 'VM sizing'
        $memoryStartupGbFinal = Read-PositiveInt -Prompt 'Startup memory in GB' -Default $MemoryStartupGb
        $minimumMemoryGbFinal = Read-PositiveInt -Prompt 'Minimum memory in GB' -Default $MinimumMemoryGb
        $maximumMemoryGbFinal = Read-PositiveInt -Prompt 'Maximum memory in GB' -Default $MaximumMemoryGb
        if ($minimumMemoryGbFinal -gt $memoryStartupGbFinal) {
            throw 'Minimum memory cannot be greater than startup memory.'
        }
        if ($maximumMemoryGbFinal -lt $memoryStartupGbFinal) {
            throw 'Maximum memory cannot be less than startup memory.'
        }

        $processorCountFinal = Read-PositiveInt -Prompt 'Processor count' -Default $ProcessorCount
        $seedControllerLocationFinal = Read-PositiveInt -Prompt 'Seed disk SCSI controller location' -Default $SeedControllerLocation
        $startAfterCreateFinal = Read-YesNo -Prompt 'Start the VM immediately after creation?' -Default $StartAfterCreate
    }

    Write-Section 'Summary'
    $summary = [ordered]@{
        'Config file' = $(if ($script:WrapperConfig.Count -gt 0) { $script:ResolvedConfigPath } else { '-' })
        'Repo root' = $repoRootFinal
        'VM name' = $vmName
        'Hostname' = $hostnameFinal
        'Admin user' = $adminUserFinal
        'SSH public key' = $sshPublicKeyPathFinal
        'Golden VHDX' = $(if ($seedOnlyFinal) { '-' } else { $goldenVhdxPathFinal })
        'VM root' = $(if ($seedOnlyFinal) { '-' } else { $vmRootFinal })
        'Seed disk' = $seedDiskPathFinal
        'Mode' = $(if ($seedOnlyFinal) { 'Seed only (overwrite if exists)' } else { 'Seed + VM creation' })
        'Switch' = $(if ($seedOnlyFinal) { '-' } else { $switchNameFinal })
        'MAC address' = $macAddressFinal
        'Interface name' = $interfaceNameFinal
        'Static networking' = $useStaticFinal
        'Static IP/CIDR' = $(if ($useStaticFinal) { $staticIpCidrFinal } else { 'DHCP' })
        'Gateway' = $(if ($useStaticFinal) { $gatewayFinal } else { '-' })
        'DNS servers' = $(if ($useStaticFinal) { ($dnsServersFinal -join ', ') } else { '-' })
        'Rescue user enabled' = $enableRescueUserFinal
        'Rescue username' = $(if ($enableRescueUserFinal) { $rescueUserFinal } else { '-' })
        'Rescue SSH password login' = $(if ($enableRescueUserFinal) { $enableRescueSshPasswordFinal } else { '-' })
        'Startup memory' = $(if ($seedOnlyFinal) { '-' } else { "$memoryStartupGbFinal GB" })
        'Minimum memory' = $(if ($seedOnlyFinal) { '-' } else { "$minimumMemoryGbFinal GB" })
        'Maximum memory' = $(if ($seedOnlyFinal) { '-' } else { "$maximumMemoryGbFinal GB" })
        'Processors' = $(if ($seedOnlyFinal) { '-' } else { $processorCountFinal })
        'Seed controller location' = $(if ($seedOnlyFinal) { '-' } else { $seedControllerLocationFinal })
        'Start after create' = $(if ($seedOnlyFinal) { '-' } else { $startAfterCreateFinal })
    }

    $summary.GetEnumerator() | ForEach-Object {
        Write-Host ("{0,-28}: {1}" -f $_.Key, $_.Value)
    }

    $proceedPrompt = if ($seedOnlyFinal) { 'Proceed with seed disk creation/overwrite?' } else { 'Proceed with seed + VM creation?' }
    if (-not (Read-YesNo -Prompt $proceedPrompt -Default $true)) {
        Write-Host 'Cancelled by user.' -ForegroundColor Yellow
        return
    }

    Write-Section 'Creating seed disk'
    $seedParams = @{
        SeedDiskPath = $seedDiskPathFinal
        Hostname = $hostnameFinal
        AdminUser = $adminUserFinal
        SshPublicKeyPath = $sshPublicKeyPathFinal
        InterfaceMacAddress = $macAddressFinal
        TemplateRoot = $templateRoot
        InterfaceName = $interfaceNameFinal
        EnableRescueUser = $enableRescueUserFinal
    }

    if ($useStaticFinal) {
        $seedParams.StaticIpCidr = $staticIpCidrFinal
        $seedParams.Gateway = $gatewayFinal
        $seedParams.DnsServers = $dnsServersFinal
    }

    if ($enableRescueUserFinal) {
        $seedParams.RescueUser = $rescueUserFinal
        if ($rescueSshPublicKeyPathFinal) {
            $seedParams.RescueSshPublicKeyPath = $rescueSshPublicKeyPathFinal
        }
        if ($null -ne $rescuePasswordFinal) {
            $seedParams.RescuePassword = $rescuePasswordFinal
        }
        if ($SetRescuePassword) {
            $seedParams.SetRescuePassword = $true
        }
        if ($enableRescueSshPasswordFinal) {
            $seedParams.EnableRescueSshPassword = $true
        }
    }

    & $seedScript @seedParams

    if ($seedOnlyFinal) {
        Write-Section 'Done'
        Write-Host "Seed disk created successfully: $seedDiskPathFinal" -ForegroundColor Green
        Write-Host "Seed summary file: $seedDiskPathFinal.rescue.txt"
        return
    }

    Write-Section 'Creating VM from golden disk'
    $vmParams = @{
        VmName = $vmName
        GoldenVhdxPath = $goldenVhdxPathFinal
        VmRoot = $vmRootFinal
        SwitchName = $switchNameFinal
        SeedDiskPath = $seedDiskPathFinal
        StaticMacAddress = $macAddressFinal
        MemoryStartupBytes = (Get-BytesFromGb -Gb $memoryStartupGbFinal)
        ProcessorCount = $processorCountFinal
        MinimumMemoryBytes = (Get-BytesFromGb -Gb $minimumMemoryGbFinal)
        MaximumMemoryBytes = (Get-BytesFromGb -Gb $maximumMemoryGbFinal)
        SeedControllerLocation = $seedControllerLocationFinal
    }

    if ($startAfterCreateFinal) {
        $vmParams.StartAfterCreate = $true
    }

    & $vmScript @vmParams

    Write-Section 'Done'
    Write-Host "VM created successfully: $vmName" -ForegroundColor Green
    Write-Host "Seed summary file: $seedDiskPathFinal.rescue.txt"
    Write-Host 'Next checks:'
    Write-Host "  Get-VM -Name $vmName | Format-List Name, State, Status"
    Write-Host "  Get-VMNetworkAdapter -VMName $vmName | Format-List *"
    if ($useStaticFinal) {
        Write-Host "  ssh -i $($sshPublicKeyPathFinal -replace '\.pub$','') $adminUserFinal@$($staticIpCidrFinal -replace '/.*$','')"
    }
    else {
        Write-Host "  Find the VM IP, then SSH as: $adminUserFinal@<vm-ip>"
    }
}
catch {
    Write-Error $_
    exit 1
}

