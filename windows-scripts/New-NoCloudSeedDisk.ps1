param(
    [Parameter(Mandatory = $true)]
    [string]$SeedDiskPath,

    [Parameter(Mandatory = $true)]
    [string]$Hostname,

    [Parameter(Mandatory = $true)]
    [string]$AdminUser,

    [Parameter(Mandatory = $true)]
    [string]$SshPublicKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$InterfaceMacAddress,

    [string]$InstanceId = ("iid-{0}" -f ([guid]::NewGuid().ToString())),
    [string]$TemplateRoot,
    [string]$NetworkConfigPath,
    [string]$InterfaceName = "lan0",
    [string]$StaticIpCidr,
    [string]$Gateway,
    [string[]]$DnsServers = @(),
    [bool]$EnableRescueUser = $true,
    [string]$RescueUser = "rescue",
    [string]$RescueSshPublicKeyPath,
    [string]$RescuePassword,
    [switch]$SetRescuePassword,
    [switch]$EnableRescueSshPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($TemplateRoot)) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $TemplateRoot = Join-Path $repoRoot 'cloud-init'
}


function New-RandomPassword {
    param([int]$Length = 20)

    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*()-_=+'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $builder = New-Object System.Text.StringBuilder

    try {
        while ($builder.Length -lt $Length) {
            $bytes = New-Object byte[] 1
            $rng.GetBytes($bytes)
            [void]$builder.Append($chars[$bytes[0] % $chars.Length])
        }
    }
    finally {
        $rng.Dispose()
    }

    return $builder.ToString()
}

function Convert-ToCloudInitMacAddress {
    param([string]$MacAddress)

    $normalized = $MacAddress.Trim().ToLowerInvariant().Replace('-', ':')
    if ($normalized -notmatch '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$') {
        throw "InterfaceMacAddress must be in the form 00-15-5D-32-10-01 or 00:15:5d:32:10:01. Got: $MacAddress"
    }

    return $normalized
}

function Set-TemplateValues {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][hashtable]$Values
    )

    foreach ($k in $Values.Keys) {
        $Text = $Text.Replace($k, [string]$Values[$k])
    }

    return $Text
}

function ConvertTo-YamlSingleQuotedScalar {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value.IndexOfAny([char[]]@("`r", "`n", [char]0)) -ge 0) {
        throw 'YAML values cannot contain newlines or NUL characters.'
    }
    return "'{0}'" -f $Value.Replace("'", "''")
}

function Assert-LinuxUserName {
    param([string]$Name, [string]$Label)
    if ($Name -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw "$Label is not a valid Linux username: $Name" }
}

function Assert-HostName {
    param([string]$Name)
    if ($Name.Length -gt 253 -or $Name -notmatch '^(?=.{1,253}$)([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(\.([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?))*$') {
        throw "Invalid hostname: $Name"
    }
}

function Assert-IpAddress {
    param([string]$Address, [string]$Label)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed) -or $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "$Label is not a valid IPv4 address: $Address"
    }
}

function New-NameserversBlock {
    param([string[]]$DnsList)

    if (-not $DnsList -or $DnsList.Count -eq 0) {
        return ''
    }

    $dnsInline = ($DnsList | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        $value = $_.Trim()
        Assert-IpAddress -Address $value -Label 'DNS server'
        ConvertTo-YamlSingleQuotedScalar $value
    }) -join ', '
    if ([string]::IsNullOrWhiteSpace($dnsInline)) {
        return ''
    }

@"
    nameservers:
      addresses: [ $dnsInline ]
"@
}

function New-ChpasswdBlock {
    param(
        [Parameter(Mandatory = $true)][string]$AccountName,
        [Parameter(Mandatory = $true)][string]$SecretText
    )

@"
chpasswd:
  expire: false
  users:
    - name: $(ConvertTo-YamlSingleQuotedScalar $AccountName)
      password: $(ConvertTo-YamlSingleQuotedScalar $SecretText)
      type: text
"@
}

if (-not (Test-Path $TemplateRoot)) {
    throw "TemplateRoot not found: $TemplateRoot"
}
if (-not (Test-Path $SshPublicKeyPath)) {
    throw "SSH public key not found: $SshPublicKeyPath"
}

Assert-HostName -Name $Hostname
Assert-LinuxUserName -Name $AdminUser -Label 'AdminUser'
if ($InterfaceName -notmatch '^[a-zA-Z0-9_.-]{1,15}$') { throw "Invalid InterfaceName: $InterfaceName" }
if ($EnableRescueUser) { Assert-LinuxUserName -Name $RescueUser -Label 'RescueUser' }
if ($StaticIpCidr) {
    if ($StaticIpCidr -notmatch '^(.+)/(\d{1,2})$') { throw "StaticIpCidr must include a prefix length: $StaticIpCidr" }
    Assert-IpAddress -Address $matches[1] -Label 'Static IP'
    if ([int]$matches[2] -gt 32) { throw "Invalid IPv4 prefix length: $($matches[2])" }
}
if ($Gateway) { Assert-IpAddress -Address $Gateway -Label 'Gateway' }

$metaTemplatePath = Join-Path $TemplateRoot 'meta-data.template.yaml'
$userTemplatePath = Join-Path $TemplateRoot 'user-data.template.yaml'

if (-not (Test-Path $metaTemplatePath)) { throw "meta-data template not found: $metaTemplatePath" }
if (-not (Test-Path $userTemplatePath)) { throw "user-data template not found: $userTemplatePath" }

$metaTemplate = Get-Content $metaTemplatePath -Raw
$userTemplate = Get-Content $userTemplatePath -Raw
$sshKey = (Get-Content $SshPublicKeyPath -Raw).Trim()
$cloudInitMacAddress = Convert-ToCloudInitMacAddress -MacAddress $InterfaceMacAddress

$rescueEnabledText = 'false'
$sshPwAuth = 'false'
$rescueUserBlock = ''
$rescueChpasswdBlock = ''
$rescuePasswordGenerated = $false
$rescuePasswordConfigured = $false
$rescueKey = $sshKey

if ($EnableRescueUser) {
    if ($RescueSshPublicKeyPath) {
        if (-not (Test-Path $RescueSshPublicKeyPath)) {
            throw "Rescue SSH public key not found: $RescueSshPublicKeyPath"
        }
        $rescueKey = (Get-Content $RescueSshPublicKeyPath -Raw).Trim()
    }

    $rescueEnabledText = 'true'
    if ($EnableRescueSshPassword.IsPresent) {
        $sshPwAuth = 'true'
    }

    $shouldConfigureRescuePassword = $EnableRescueSshPassword.IsPresent -or $SetRescuePassword.IsPresent -or (-not [string]::IsNullOrWhiteSpace($RescuePassword))
    if ($shouldConfigureRescuePassword) {
        if ([string]::IsNullOrWhiteSpace($RescuePassword)) {
            $RescuePassword = New-RandomPassword
            $rescuePasswordGenerated = $true
        }

        $rescuePasswordConfigured = $true
        $rescueChpasswdBlock = New-ChpasswdBlock -AccountName $RescueUser -SecretText $RescuePassword
    }

    $rescueLockPasswd = if ($rescuePasswordConfigured) { 'false' } else { 'true' }

    $rescueUserBlock = @"
  - name: $(ConvertTo-YamlSingleQuotedScalar $RescueUser)
    gecos: Rescue User
    shell: /bin/bash
    groups: [adm, sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: $rescueLockPasswd
    ssh_authorized_keys:
      - $(ConvertTo-YamlSingleQuotedScalar $rescueKey)
"@
}

$metaContent = Set-TemplateValues -Text $metaTemplate -Values @{
    '__INSTANCE_ID__' = (ConvertTo-YamlSingleQuotedScalar $InstanceId)
    '__HOSTNAME__'    = (ConvertTo-YamlSingleQuotedScalar $Hostname)
}

$userContent = Set-TemplateValues -Text $userTemplate -Values @{
    '__HOSTNAME__'              = $Hostname
    '__ADMIN_USER__'            = (ConvertTo-YamlSingleQuotedScalar $AdminUser)
    '__SSH_PUBLIC_KEY__'        = (ConvertTo-YamlSingleQuotedScalar $sshKey)
    '__SSH_PWAUTH__'            = $sshPwAuth
    '__RESCUE_USER_BLOCK__'     = $rescueUserBlock.TrimEnd()
    '__RESCUE_CHPASSWD_BLOCK__' = $rescueChpasswdBlock.TrimEnd()
    '__RESCUE_USER_ENABLED__'   = $rescueEnabledText
}

$networkContent = $null
if ($NetworkConfigPath) {
    if (-not (Test-Path $NetworkConfigPath)) {
        throw "NetworkConfigPath not found: $NetworkConfigPath"
    }
    $networkTemplate = Get-Content $NetworkConfigPath -Raw
}
elseif ($StaticIpCidr -or $Gateway) {
    if (-not ($StaticIpCidr -and $Gateway)) {
        throw 'When using static networking, both StaticIpCidr and Gateway are required.'
    }
    $networkTemplatePath = Join-Path $TemplateRoot 'network-config.static.template.yaml'
    if (-not (Test-Path $networkTemplatePath)) {
        throw "Static network template not found: $networkTemplatePath"
    }
    $networkTemplate = Get-Content $networkTemplatePath -Raw
}
else {
    $networkTemplatePath = Join-Path $TemplateRoot 'network-config.dhcp.yaml'
    if (-not (Test-Path $networkTemplatePath)) {
        throw "DHCP network template not found: $networkTemplatePath"
    }
    $networkTemplate = Get-Content $networkTemplatePath -Raw
}

$nameserversBlock = New-NameserversBlock -DnsList $DnsServers
$networkContent = Set-TemplateValues -Text $networkTemplate -Values @{
    '__MAC_ADDRESS__'       = ([string]$cloudInitMacAddress)
    '__INTERFACE_NAME__'    = (ConvertTo-YamlSingleQuotedScalar $InterfaceName)
    '__IP_CIDR__'           = (ConvertTo-YamlSingleQuotedScalar $StaticIpCidr)
    '__GATEWAY__'           = (ConvertTo-YamlSingleQuotedScalar $Gateway)
    '__NAMESERVERS_BLOCK__' = $nameserversBlock.TrimEnd()
}

$SeedDiskPath = [System.IO.Path]::GetFullPath($SeedDiskPath)
if (Test-Path -LiteralPath $SeedDiskPath -PathType Container) {
    throw "SeedDiskPath points to a directory, not a VHDX file: $SeedDiskPath"
}
$seedParent = Split-Path -Parent $SeedDiskPath
if (-not (Test-Path -LiteralPath $seedParent)) {
    New-Item -ItemType Directory -Path $seedParent -Force | Out-Null
}

$tempRoot = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$tempDir = Join-Path $tempRoot ("generic-seed-{0}" -f ([guid]::NewGuid().ToString()))
New-Item -ItemType Directory -Path $tempDir | Out-Null
$stagingSeedPath = Join-Path $seedParent (".{0}.new-{1}.vhdx" -f ([System.IO.Path]::GetFileNameWithoutExtension($SeedDiskPath)), ([guid]::NewGuid().ToString('N')))
$mountedStaging = $false
$buildSucceeded = $false
$summary = $null

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $tempDir 'meta-data'), $metaContent, $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $tempDir 'user-data'), $userContent, $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $tempDir 'network-config'), $networkContent, $utf8NoBom)

    New-VHD -Path $stagingSeedPath -Dynamic -SizeBytes 64MB | Out-Null
    $mounted = Mount-VHD -Path $stagingSeedPath -Passthru
    $mountedStaging = $true
    $disk = $mounted | Get-Disk
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel 'cidata' -Confirm:$false | Out-Null

    $driveLetter = ($partition | Get-Volume).DriveLetter
    if (-not $driveLetter) {
        throw 'Could not determine drive letter for seed disk.'
    }
    $driveRoot = "${driveLetter}:\"

    Copy-Item (Join-Path $tempDir 'meta-data') (Join-Path $driveRoot 'meta-data') -Force
    Copy-Item (Join-Path $tempDir 'user-data') (Join-Path $driveRoot 'user-data') -Force
    Copy-Item (Join-Path $tempDir 'network-config') (Join-Path $driveRoot 'network-config') -Force

    $rescuePasswordSummary = if (-not $EnableRescueUser) {
        '<disabled>'
    }
    elseif (-not $rescuePasswordConfigured) {
        '<not configured>'
    }
    else { '<configured; not stored>' }

    $summary = @(
        "Hostname: $Hostname",
        "Rescue user: $(if ($EnableRescueUser) { $RescueUser } else { '<disabled>' })",
        "Rescue password: $rescuePasswordSummary",
        "SSH password auth enabled: $sshPwAuth",
        "Interface MAC: $cloudInitMacAddress",
        "Seed disk: $SeedDiskPath"
    ) -join [Environment]::NewLine
    $buildSucceeded = $true
}
finally {
    if ($mountedStaging) {
        Dismount-DiskImage -ImagePath $stagingSeedPath -ErrorAction SilentlyContinue
    }
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $buildSucceeded -and (Test-Path -LiteralPath $stagingSeedPath)) {
        Remove-Item -LiteralPath $stagingSeedPath -Force -ErrorAction SilentlyContinue
    }
}

$backupSeedPath = "$SeedDiskPath.backup-$([guid]::NewGuid().ToString('N'))"
$movedOriginal = $false
$installedNewSeed = $false
try {
    if (Test-Path -LiteralPath $SeedDiskPath) {
        [System.IO.File]::Replace($stagingSeedPath, $SeedDiskPath, $backupSeedPath, $true)
        $movedOriginal = $true
        $installedNewSeed = $true
    }
    else {
        Move-Item -LiteralPath $stagingSeedPath -Destination $SeedDiskPath
        $installedNewSeed = $true
    }
}
catch {
    if ($installedNewSeed -and (Test-Path -LiteralPath $SeedDiskPath)) {
        Remove-Item -LiteralPath $SeedDiskPath -Force -ErrorAction SilentlyContinue
    }
    if ($movedOriginal -and (Test-Path -LiteralPath $backupSeedPath)) {
        Move-Item -LiteralPath $backupSeedPath -Destination $SeedDiskPath -Force
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $stagingSeedPath) { Remove-Item -LiteralPath $stagingSeedPath -Force -ErrorAction SilentlyContinue }
}

if ($movedOriginal -and (Test-Path -LiteralPath $backupSeedPath)) {
    Remove-Item -LiteralPath $backupSeedPath -Force
}

$summaryPath = "$SeedDiskPath.rescue.txt"
$summaryTemporaryPath = "$summaryPath.new-$([guid]::NewGuid().ToString('N'))"
try {
    [System.IO.File]::WriteAllText($summaryTemporaryPath, $summary + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $summaryTemporaryPath -Destination $summaryPath -Force
}
finally {
    if (Test-Path -LiteralPath $summaryTemporaryPath) { Remove-Item -LiteralPath $summaryTemporaryPath -Force -ErrorAction SilentlyContinue }
}

Write-Host "Created NoCloud seed disk: $SeedDiskPath"
if ($EnableRescueUser) {
    Write-Host "Rescue user enabled: $RescueUser"
    if (-not $rescuePasswordConfigured) {
        Write-Host 'Rescue password not configured.'
    }
    elseif ($rescuePasswordGenerated) {
        Write-Warning "Generated rescue password (shown once; it is not stored): $RescuePassword"
    }
    else {
        Write-Host "Rescue password supplied by caller."
    }
    Write-Host "Saved rescue details to: $SeedDiskPath.rescue.txt"
}
