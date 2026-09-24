[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$SwitchName,
    [string]$ExpectedNatPrefix,
    [string]$Gateway,
    [string]$ConfigPath,
    [string]$NatName,
    [switch]$RequireNat,
    [switch]$Repair,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Expand-PreflightPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ($expanded -eq '~') { return $env:USERPROFILE }
    if ($expanded.StartsWith('~\') -or $expanded.StartsWith('~/')) {
        return Join-Path $env:USERPROFILE $expanded.Substring(2)
    }
    return $expanded
}

function Resolve-PreflightConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { return Expand-PreflightPath $ConfigPath }
    $localBase = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\Local' }
    $userConfig = Join-Path $localBase 'HyperVGoldenImage\New-GoldenVmInteractive.config.psd1'
    $legacyConfig = Join-Path $PSScriptRoot 'New-GoldenVmInteractive.config.psd1'
    if (Test-Path -LiteralPath $userConfig) { return $userConfig }
    if (Test-Path -LiteralPath $legacyConfig) { return $legacyConfig }
    return $null
}

function ConvertTo-IPv4NetworkPrefix {
    param([string]$Cidr)
    if ($Cidr -notmatch '^(.+)/(\d{1,2})$') { throw "Invalid IPv4 CIDR: $Cidr" }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($matches[1], [ref]$ip) -or $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Invalid IPv4 address: $($matches[1])"
    }
    $prefixLength = [int]$matches[2]
    if ($prefixLength -lt 0 -or $prefixLength -gt 32) { throw "Invalid IPv4 prefix length: $prefixLength" }

    $bytes = $ip.GetAddressBytes()
    $mask = [uint32]0
    if ($prefixLength -gt 0) { $mask = [uint32]::MaxValue -shl (32 - $prefixLength) }
    $value = ([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3]
    $network = $value -band $mask
    $networkBytes = [byte[]]@(
        (($network -shr 24) -band 255)
        (($network -shr 16) -band 255)
        (($network -shr 8) -band 255)
        ($network -band 255)
    )
    return "$(New-Object System.Net.IPAddress (,$networkBytes))/$prefixLength"
}

function Test-IPv4InCidr {
    param([string]$Address, [string]$Cidr)
    try {
        $network = ConvertTo-IPv4NetworkPrefix $Cidr
        $addressNetwork = ConvertTo-IPv4NetworkPrefix "$Address/$($Cidr.Split('/')[1])"
        return $network -eq $addressNetwork
    }
    catch { return $false }
}

function New-CheckResult {
    param([string]$Check, [ValidateSet('Pass','Fail','Warning','Skipped')][string]$Status, [string]$Details)
    [PSCustomObject]@{ Check=$Check; Status=$Status; Details=$Details }
}

$configFile = Resolve-PreflightConfigPath
$config = @{}
if ($configFile) {
    if (-not (Test-Path -LiteralPath $configFile)) { throw "Config file not found: $configFile" }
    $config = Import-PowerShellDataFile -Path $configFile
    if ($null -eq $config) { $config = @{} }
}

if ([string]::IsNullOrWhiteSpace($SwitchName) -and $config.ContainsKey('SwitchName')) { $SwitchName = [string]$config.SwitchName }
if ([string]::IsNullOrWhiteSpace($Gateway) -and $config.ContainsKey('Gateway')) { $Gateway = [string]$config.Gateway }
if ([string]::IsNullOrWhiteSpace($ExpectedNatPrefix)) {
    if ($config.ContainsKey('StaticIpCidr') -and -not [string]::IsNullOrWhiteSpace([string]$config.StaticIpCidr)) {
        $ExpectedNatPrefix = ConvertTo-IPv4NetworkPrefix ([string]$config.StaticIpCidr)
    }
    elseif ($config.ContainsKey('IpPrefix') -and -not [string]::IsNullOrWhiteSpace([string]$config.IpPrefix)) {
        $ExpectedNatPrefix = ConvertTo-IPv4NetworkPrefix ("{0}.0/24" -f ([string]$config.IpPrefix).Trim().TrimEnd('.'))
    }
}
$natRequired = $RequireNat.IsPresent -or -not [string]::IsNullOrWhiteSpace($ExpectedNatPrefix) -or -not [string]::IsNullOrWhiteSpace($Gateway)
if ([string]::IsNullOrWhiteSpace($NatName) -and -not [string]::IsNullOrWhiteSpace($SwitchName)) { $NatName = $SwitchName }

$results = [System.Collections.Generic.List[object]]::new()
$runningOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$results.Add((New-CheckResult 'Windows platform' $(if($runningOnWindows){'Pass'}else{'Fail'}) $(if($runningOnWindows){[Environment]::OSVersion.VersionString}else{'Hyper-V requires Windows'})))

$isAdmin = $false
if ($runningOnWindows) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$results.Add((New-CheckResult 'Administrator' $(if($isAdmin){'Pass'}else{'Fail'}) $(if($isAdmin){'Process is elevated'}else{'Run PowerShell as Administrator'})))

$moduleAvailable = [bool](Get-Module -ListAvailable -Name Hyper-V)
$results.Add((New-CheckResult 'Hyper-V PowerShell module' $(if($moduleAvailable){'Pass'}else{'Fail'}) $(if($moduleAvailable){'Module is available'}else{'Install Hyper-V management tools'})))

$featureStatus = 'Skipped'
$featureDetails = 'Feature cmdlet is unavailable; module and service checks are used instead'
if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
        $featureStatus = if ($feature.State -eq 'Enabled') { 'Pass' } else { 'Fail' }
        $featureDetails = "Microsoft-Hyper-V-All state: $($feature.State)"
    }
    catch { $featureStatus='Warning'; $featureDetails=$_.Exception.Message }
}
$results.Add((New-CheckResult 'Hyper-V Windows feature' $featureStatus $featureDetails))

$vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
$results.Add((New-CheckResult 'Hyper-V VMMS service' $(if($vmms -and $vmms.Status -eq 'Running'){'Pass'}else{'Fail'}) $(if($vmms){"Status: $($vmms.Status)"}else{'Service not found'})))

$requiredCommands = @(
    'Get-VM','New-VM','Get-VMSwitch','New-VHD','Mount-VHD','Get-Disk','Initialize-Disk',
    'New-Partition','Format-Volume','Dismount-DiskImage','Set-VMProcessor','Set-VMMemory',
    'Set-VMFirmware','Set-VMNetworkAdapter','Add-VMHardDiskDrive'
)
$missingCommands = @($requiredCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
$results.Add((New-CheckResult 'Required Hyper-V commands' $(if($missingCommands.Count -eq 0){'Pass'}else{'Fail'}) $(if($missingCommands.Count -eq 0){'All required commands are available'}else{"Missing: $($missingCommands -join ', ')"})))

$switch = $null
if ([string]::IsNullOrWhiteSpace($SwitchName)) {
    $results.Add((New-CheckResult 'Virtual switch' 'Warning' 'No SwitchName was supplied by CLI or config'))
}
elseif (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) {
    $switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    $results.Add((New-CheckResult 'Virtual switch' $(if($switch){'Pass'}else{'Fail'}) $(if($switch){"$($switch.Name) [$($switch.SwitchType)]"}else{"Not found: $SwitchName"})))
}
else {
    $results.Add((New-CheckResult 'Virtual switch' 'Fail' 'Get-VMSwitch is unavailable'))
}

$hostAdapter = $null
if ($switch -and $switch.SwitchType -eq 'Internal' -and (Get-Command Get-VMNetworkAdapter -ErrorAction SilentlyContinue)) {
    $hostAdapter = @(Get-VMNetworkAdapter -ManagementOS -ErrorAction SilentlyContinue | Where-Object SwitchName -eq $SwitchName | Select-Object -First 1)
}
$adapterRequired = $natRequired -or ($switch -and $switch.SwitchType -eq 'Internal')
$adapterStatus = if(-not $adapterRequired){'Skipped'}elseif($hostAdapter){'Pass'}else{'Fail'}
$adapterDetails = if($hostAdapter){"Management adapter: $($hostAdapter.Name)"}elseif($adapterRequired){'Management OS adapter was not found for the internal switch'}else{'Not required for this switch type'}
$results.Add((New-CheckResult 'Host vEthernet adapter' $adapterStatus $adapterDetails))

$gatewayFound = $false
if (-not [string]::IsNullOrWhiteSpace($Gateway) -and (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue)) {
    $gatewayFound = [bool](Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $Gateway | Select-Object -First 1)
    $results.Add((New-CheckResult 'Host gateway address' $(if($gatewayFound){'Pass'}else{'Fail'}) $(if($gatewayFound){"Found: $Gateway"}else{"Not assigned to the host: $Gateway"})))
}
else {
    $results.Add((New-CheckResult 'Host gateway address' $(if($natRequired){'Warning'}else{'Skipped'}) 'No gateway was supplied or Get-NetIPAddress is unavailable'))
}

$matchingNat = $null
if (Get-Command Get-NetNat -ErrorAction SilentlyContinue) {
    $nats = @(Get-NetNat -ErrorAction SilentlyContinue)
    if (-not [string]::IsNullOrWhiteSpace($ExpectedNatPrefix)) {
        $matchingNat = $nats | Where-Object InternalIPInterfaceAddressPrefix -eq $ExpectedNatPrefix | Select-Object -First 1
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Gateway)) {
        $matchingNat = $nats | Where-Object { Test-IPv4InCidr -Address $Gateway -Cidr $_.InternalIPInterfaceAddressPrefix } | Select-Object -First 1
    }
    elseif ($nats.Count -eq 1) { $matchingNat = $nats[0] }

    $natStatus = if($matchingNat){'Pass'}elseif($natRequired){'Fail'}else{'Warning'}
    $natDetails = if($matchingNat){"$($matchingNat.Name): $($matchingNat.InternalIPInterfaceAddressPrefix)"}elseif($nats.Count -eq 0){'No NetNat objects exist'}else{"No NAT matches expected prefix/gateway. Available: $($nats.InternalIPInterfaceAddressPrefix -join ', ')"}
    $results.Add((New-CheckResult 'NetNat configuration' $natStatus $natDetails))
}
else {
    $results.Add((New-CheckResult 'NetNat configuration' $(if($natRequired){'Fail'}else{'Skipped'}) 'Get-NetNat is unavailable'))
}

$failed = @($results | Where-Object Status -eq 'Fail')
$summary = [PSCustomObject]@{
    Passed = $failed.Count -eq 0
    ConfigPath = $configFile
    SwitchName = $SwitchName
    ExpectedNatPrefix = $ExpectedNatPrefix
    Gateway = $Gateway
    Checks = @($results)
}

if ($Repair) {
    if (-not $isAdmin) { throw 'Repair requires an elevated PowerShell session. Run PowerShell as Administrator.' }
    if ([string]::IsNullOrWhiteSpace($SwitchName)) { throw 'Repair requires SwitchName from CLI or config.' }
    if ($natRequired -and [string]::IsNullOrWhiteSpace($ExpectedNatPrefix)) { throw 'NAT repair requires ExpectedNatPrefix or a static network in the config.' }
    if ($natRequired -and [string]::IsNullOrWhiteSpace($Gateway)) { throw 'NAT repair requires Gateway from CLI or config.' }

    $repairCanContinue = $true
    if (-not $switch) {
        if (-not $natRequired) {
            throw "Switch '$SwitchName' is missing, but DHCP mode does not define whether it should be external, internal, or private. Create the intended DHCP-capable switch explicitly."
        }
        if (-not (Get-Command New-VMSwitch -ErrorAction SilentlyContinue)) { throw 'New-VMSwitch is unavailable.' }
        if ($PSCmdlet.ShouldProcess("Internal Hyper-V switch '$SwitchName'", 'Create')) {
            New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
        }
        else { $repairCanContinue = $false }
    }

    $switch = if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) { Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue } else { $null }
    if (-not $switch) {
        Write-Warning "Switch '$SwitchName' is still unavailable; dependent gateway and NAT repairs were skipped."
        $repairCanContinue = $false
    }
    if ($switch -and $switch.SwitchType -ne 'Internal' -and $natRequired) {
        throw "Switch '$SwitchName' exists as type '$($switch.SwitchType)'. Repair will not replace or convert an existing switch."
    }

    $netAdapter = $null
    if ($switch -and (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
        $netAdapter = Get-NetAdapter -Name "vEthernet ($SwitchName)" -ErrorAction SilentlyContinue
    }
    if ($natRequired -and $repairCanContinue -and -not $netAdapter) {
        throw "The management adapter 'vEthernet ($SwitchName)' is unavailable. Repair stopped before changing IP or NAT settings."
    }

    if ($natRequired -and $repairCanContinue) {
        foreach ($commandName in @('Get-NetIPAddress','New-NetIPAddress','Get-NetNat','New-NetNat')) {
            if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) { throw "Required repair command is unavailable: $commandName" }
        }
        $gatewayIp = $null
        if (-not [System.Net.IPAddress]::TryParse($Gateway, [ref]$gatewayIp) -or $gatewayIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Gateway is not a valid IPv4 address: $Gateway"
        }
        if (-not (Test-IPv4InCidr -Address $Gateway -Cidr $ExpectedNatPrefix)) {
            throw "Gateway $Gateway is outside expected NAT prefix $ExpectedNatPrefix."
        }

        $prefixLength = [int]$ExpectedNatPrefix.Split('/')[1]
        $gatewayAssignment = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Gateway -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gatewayAssignment -and $gatewayAssignment.InterfaceIndex -ne $netAdapter.ifIndex) {
            throw "Gateway $Gateway is already assigned to another interface: $($gatewayAssignment.InterfaceAlias)"
        }
        if (-not $gatewayAssignment) {
            if ($PSCmdlet.ShouldProcess("$($netAdapter.Name) [$Gateway/$prefixLength]", 'Assign host gateway address')) {
                New-NetIPAddress -InterfaceIndex $netAdapter.ifIndex -IPAddress $Gateway -PrefixLength $prefixLength | Out-Null
            }
            else { $repairCanContinue = $false }
        }

        if ($repairCanContinue) {
            $sameNameNat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
            if ($sameNameNat -and $sameNameNat.InternalIPInterfaceAddressPrefix -ne $ExpectedNatPrefix) {
                throw "NetNat '$NatName' already exists with prefix $($sameNameNat.InternalIPInterfaceAddressPrefix). Repair will not modify or replace it."
            }
            $samePrefixNat = Get-NetNat -ErrorAction SilentlyContinue | Where-Object InternalIPInterfaceAddressPrefix -eq $ExpectedNatPrefix | Select-Object -First 1
            if (-not $sameNameNat -and -not $samePrefixNat) {
                if ($PSCmdlet.ShouldProcess("NetNat '$NatName' [$ExpectedNatPrefix]", 'Create')) {
                    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $ExpectedNatPrefix | Out-Null
                }
            }
        }
    }

    $verifyParameters = @{ PassThru=$true }
    if ($SwitchName) { $verifyParameters.SwitchName=$SwitchName }
    if ($ExpectedNatPrefix) { $verifyParameters.ExpectedNatPrefix=$ExpectedNatPrefix }
    if ($Gateway) { $verifyParameters.Gateway=$Gateway }
    if ($ConfigPath) { $verifyParameters.ConfigPath=$ConfigPath }
    if ($NatName) { $verifyParameters.NatName=$NatName }
    if ($RequireNat) { $verifyParameters.RequireNat=$true }
    $summary = & $PSCommandPath @verifyParameters
    $results = $summary.Checks
}

if ($PassThru) { return $summary }

$results | Format-Table Check, Status, Details -Wrap -AutoSize
Write-Host "`nOverall: $(if($summary.Passed){'PASS'}else{'FAIL'})" -ForegroundColor $(if($summary.Passed){'Green'}else{'Red'})
if (-not $summary.Passed) { exit 1 }
