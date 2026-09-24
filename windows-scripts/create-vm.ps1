[CmdletBinding()]
param(
    # Automation/config inputs. In -Auto mode, environment-specific values come from config, then CLI overrides.
    [string]$RepoRoot,
    [string]$ConfigPath,
    [string]$ConfigOutputPath,
    [string]$ImportConfigPath,
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
    [switch]$SeedOnly,

    [bool]$UseStatic = $false,
    [ValidateSet('','Dhcp','PrivateNat','Advanced')][string]$NetworkMode = '',
    [string]$StaticIpCidr,
    [string]$IpPrefix,
    [ValidateRange(0,254)][int]$IpOctet,
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

    [switch]$Auto,
    [switch]$NoPrompt,
    [switch]$ConfigureOnly,
    [switch]$GenerateSshKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AutoMode = $Auto.IsPresent
$script:PromptAllowed = -not $NoPrompt.IsPresent
$script:OriginalBoundParameters = @{} + $PSBoundParameters
$script:SuggestionColor = 'Cyan'
$script:EngineValueColor = 'DarkCyan'

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


function Expand-UserPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ($expanded -eq '~') { return $env:USERPROFILE }
    if ($expanded.StartsWith('~\') -or $expanded.StartsWith('~/')) {
        return (Join-Path $env:USERPROFILE $expanded.Substring(2))
    }
    return $expanded
}

function Read-ColoredInput {
    param([string]$Prompt, [AllowNull()][string]$Default, [switch]$NoDefault)
    Write-Host $Prompt -NoNewline
    if (-not $NoDefault -and -not [string]::IsNullOrWhiteSpace($Default)) {
        Write-Host ' [' -NoNewline
        Write-Host $Default -ForegroundColor $script:SuggestionColor -NoNewline
        Write-Host ']' -NoNewline
    }
    Write-Host ': ' -NoNewline
    return Read-Host
}

function Write-EngineValue {
    param([string]$Label, [AllowNull()][object]$Value)
    Write-Host $Label -NoNewline
    Write-Host ([string]$Value) -ForegroundColor $script:EngineValueColor
}

function Resolve-UserConfigPath {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\Local' }
    return (Join-Path $base 'HyperVGoldenImage\New-GoldenVmInteractive.config.psd1')
}

function Resolve-LegacyConfigImport {
    param([Parameter(Mandatory = $true)][string]$Path)
    $expanded = Expand-UserPath $Path
    if (Test-Path -LiteralPath $expanded -PathType Leaf) {
        $fullConfigPath = [System.IO.Path]::GetFullPath($expanded)
        $configDirectory = Split-Path -Parent $fullConfigPath
        $importRoot = if ((Split-Path -Leaf $configDirectory) -like '.hyperv-generic-golden-image.migrated-backup-*') {
            Split-Path -Parent $configDirectory
        }
        else { $configDirectory }
        return [pscustomobject]@{
            ConfigPath = $fullConfigPath
            ImportRoot = $importRoot
        }
    }
    if (-not (Test-Path -LiteralPath $expanded -PathType Container)) {
        throw "Legacy import path not found: $expanded"
    }

    $root = [System.IO.Path]::GetFullPath($expanded).TrimEnd('\')
    $directConfig = Join-Path $root 'New-GoldenVmInteractive.config.psd1'
    if (Test-Path -LiteralPath $directConfig -PathType Leaf) {
        return [pscustomobject]@{ ConfigPath=$directConfig; ImportRoot=$root }
    }

    $candidate = Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop |
        Where-Object Name -Like '.hyperv-generic-golden-image.migrated-backup-*' |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            $config = Join-Path $_.FullName 'New-GoldenVmInteractive.config.psd1'
            if (Test-Path -LiteralPath $config -PathType Leaf) { Get-Item -LiteralPath $config }
        } |
        Select-Object -First 1
    if (-not $candidate) {
        throw "No legacy New-GoldenVmInteractive.config.psd1 was found directly under '$root' or in a migrated-backup directory."
    }
    return [pscustomobject]@{ ConfigPath=$candidate.FullName; ImportRoot=$root }
}

function Normalize-LegacyImportedConfig {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [AllowNull()][string]$ImportRoot
    )
    $normalized = @{} + $Config
    $script:LegacyPluralizationReport = [pscustomobject]@{
        VmRoot=$null; VmNames=@()
        SeedRoot=$null; SeedNames=@()
    }
    if ([string]::IsNullOrWhiteSpace($ImportRoot)) { return $normalized }

    $canonicalVmRoot = Join-Path $ImportRoot 'VMs'
    $canonicalSeedRoot = Join-Path $ImportRoot 'Seeds'
    $legacyVmRoot = Join-Path $ImportRoot 'VMss'
    $legacySeedRoot = Join-Path $ImportRoot 'Seedss'
    if ((Test-Path -LiteralPath $canonicalVmRoot -PathType Container) -or (Test-Path -LiteralPath $legacyVmRoot -PathType Container)) {
        $normalized.VmRoot = $canonicalVmRoot
    }
    if ((Test-Path -LiteralPath $canonicalSeedRoot -PathType Container) -or (Test-Path -LiteralPath $legacySeedRoot -PathType Container)) {
        $normalized.SeedRoot = $canonicalSeedRoot
    }

    if ($normalized.ContainsKey('GoldenVhdxPath') -and
        -not [string]::IsNullOrWhiteSpace([string]$normalized.GoldenVhdxPath) -and
        -not (Test-Path -LiteralPath (Expand-UserPath ([string]$normalized.GoldenVhdxPath)) -PathType Leaf)) {
        $normalized.Remove('GoldenVhdxPath')
    }

    $legacyVmNames = @()
    if (Test-Path -LiteralPath $legacyVmRoot -PathType Container) {
        $legacyVmNames = @(Get-ChildItem -LiteralPath $legacyVmRoot -Directory -Force | Select-Object -ExpandProperty Name)
    }
    $legacySeedNames = @()
    if (Test-Path -LiteralPath $legacySeedRoot -PathType Container) {
        $legacySeedNames = @(Get-ChildItem -LiteralPath $legacySeedRoot -Directory -Force | Select-Object -ExpandProperty Name)
    }
    $script:LegacyPluralizationReport = [pscustomobject]@{
        VmRoot=$legacyVmRoot; VmNames=$legacyVmNames
        SeedRoot=$legacySeedRoot; SeedNames=$legacySeedNames
    }
    return $normalized
}

function Resolve-DefaultDataRoot {
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        throw 'USERPROFILE is unavailable; the default VM data directory cannot be resolved.'
    }
    return (Join-Path $env:USERPROFILE 'HyperVGoldenImage-Data')
}

function Resolve-IpAllocationPath {
    return (Join-Path (Resolve-DefaultDataRoot) 'state\ip-allocations.json')
}

function Get-IpAllocations {
    $path = Resolve-IpAllocationPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $content = Get-Content -LiteralPath $path -Raw
        if ([string]::IsNullOrWhiteSpace($content)) { return @() }
        return @(ConvertFrom-Json -InputObject $content)
    }
    catch { throw "Failed to read IP allocation registry: $path. $($_.Exception.Message)" }
}

function Assert-IpAddressAvailable {
    param([string]$IpAddress, [string]$VmName)
    $conflict = Get-IpAllocations | Where-Object {
        $_.IpAddress -eq $IpAddress -and $_.VmName -ne $VmName
    } | Select-Object -First 1
    if ($conflict) {
        throw "IP address $IpAddress is already reserved for VM '$($conflict.VmName)' since $($conflict.ReservedAt). Choose another address or release the stale reservation with windows-scripts\ip-reservations.ps1."
    }
}

function Save-IpAllocation {
    param([string]$VmName, [string]$StaticIpCidr, [string]$SwitchName, [string]$SeedDiskPath)
    $ipAddress = $StaticIpCidr -replace '/.*$', ''
    $path = Resolve-IpAllocationPath
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $allocations = @(Get-IpAllocations | Where-Object { $_.VmName -ne $VmName })
    $allocations += [pscustomobject]@{
        VmName=$VmName; IpAddress=$ipAddress; Cidr=$StaticIpCidr; SwitchName=$SwitchName
        SeedDiskPath=$SeedDiskPath; ReservedAt=[DateTime]::UtcNow.ToString('o')
    }
    $temporaryPath = "$path.tmp.$PID"
    $backupPath = $null
    try {
        [IO.File]::WriteAllText($temporaryPath, (ConvertTo-Json -InputObject @($allocations) -Depth 4), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $path) {
            $backupPath = "$path.bak.$PID"
            [IO.File]::Replace($temporaryPath, $path, $backupPath, $true)
        }
        else { Move-Item -LiteralPath $temporaryPath -Destination $path }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
        if ($backupPath -and (Test-Path -LiteralPath $backupPath)) { Remove-Item -LiteralPath $backupPath -Force }
    }
    Write-Host "IP reservation saved: $ipAddress -> $VmName" -ForegroundColor Green
}

function Enter-IpAllocationLock {
    $mutex = [System.Threading.Mutex]::new($false, 'Local\HyperVGoldenImage-IpAllocations')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(60)) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Timed out waiting for the static-IP reservation lock.' }
        return $mutex
    }
    catch {
        if (-not $acquired) { $mutex.Dispose() }
        throw
    }
}

function Exit-IpAllocationLock {
    param([AllowNull()][System.Threading.Mutex]$Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() }
    finally { $Mutex.Dispose() }
}

function Resolve-DefaultGoldenVhdxPath {
    param([AllowNull()][string]$RepoRoot)
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { return $null }
    $goldenDirectory = Join-Path $RepoRoot 'Golden'
    if (-not (Test-Path -LiteralPath $goldenDirectory)) { return $null }
    $candidate = Get-ChildItem -LiteralPath $goldenDirectory -File -Filter '*.vhdx' -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function ConvertTo-Psd1Literal {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64]) { return [string]$Value }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return '@(' + ((@($Value) | ForEach-Object { ConvertTo-Psd1Literal $_ }) -join ', ') + ')'
    }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Save-UserConfig {
    param([Parameter(Mandatory = $true)][hashtable]$Settings, [Parameter(Mandatory = $true)][string]$Path)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Generated by windows-scripts\create-vm.ps1 after successful initialization.')
    $lines.Add('# User-specific settings only. Passwords are never saved here.')
    $lines.Add('@{')
    foreach ($key in $Settings.Keys | Sort-Object) { $lines.Add("    $key = $(ConvertTo-Psd1Literal $Settings[$key])") }
    $lines.Add('}')
    $temporaryPath = "$Path.tmp.$PID"
    $backupPath = $null
    try {
        [IO.File]::WriteAllLines($temporaryPath, $lines, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) {
            $backupPath = "$Path.bak.$PID"
            [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
            Remove-Item -LiteralPath $backupPath -Force
        }
        else {
            Move-Item -LiteralPath $temporaryPath -Destination $Path
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
        if ($backupPath -and (Test-Path -LiteralPath $backupPath)) { Remove-Item -LiteralPath $backupPath -Force }
    }
}

function ConvertTo-IPv4NetworkPrefix {
    param([string]$Cidr)
    if ($Cidr -notmatch '^(.+)/(\d{1,2})$') { throw "Invalid IPv4 CIDR: $Cidr" }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($matches[1], [ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw "Invalid IPv4 address: $($matches[1])" }
    $prefixLength = [int]$matches[2]
    if ($prefixLength -gt 32) { throw "Invalid IPv4 prefix length: $prefixLength" }
    $bytes = $ip.GetAddressBytes()
    $mask = [uint32]0
    if ($prefixLength -gt 0) { $mask = [uint32]::MaxValue -shl (32 - $prefixLength) }
    $value = ([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3]
    $network = $value -band $mask
    $networkBytes = [byte[]]@((($network -shr 24) -band 255), (($network -shr 16) -band 255), (($network -shr 8) -band 255), ($network -band 255))
    return "$(New-Object Net.IPAddress (,$networkBytes))/$prefixLength"
}

function Invoke-IntegratedPreflight {
    param([string]$RepoRoot, [string]$SwitchName, [bool]$RequireNat, [AllowNull()][string]$StaticIpCidr, [AllowNull()][string]$Gateway)
    $preflightScript = Join-Path $RepoRoot 'windows-scripts\Test-HyperVPreflight.ps1'
    if (-not (Test-Path -LiteralPath $preflightScript)) { throw "Required project path not found: $preflightScript" }
    $parameters = @{ SwitchName=$SwitchName; PassThru=$true }
    if ($RequireNat) {
        $parameters.RequireNat = $true
        $parameters.ExpectedNatPrefix = ConvertTo-IPv4NetworkPrefix $StaticIpCidr
        $parameters.Gateway = $Gateway
    }
    Write-Section 'Environment preflight'
    $result = & $preflightScript @parameters
    $result.Checks | Format-Table Check, Status, Details -Wrap -AutoSize
    if ($result.Passed) { return $result }
    if (-not $script:PromptAllowed) { throw 'Preflight failed. -NoPrompt never performs host repairs; correct the reported checks and run again.' }
    $repairableNames = if ($RequireNat) {
        @('Virtual switch', 'Host vEthernet adapter', 'Host gateway address', 'NetNat configuration')
    }
    else { @() }
    $nonRepairable = @($result.Checks | Where-Object { $_.Status -eq 'Fail' -and $_.Check -notin $repairableNames })
    if ($nonRepairable.Count -gt 0) { throw "Preflight has failures that this program cannot repair: $($nonRepairable.Check -join ', '). Correct them and run again." }
    Write-Host 'Proposed repair: create the missing internal switch and, for static networking, assign the host gateway and create NetNat.' -ForegroundColor Yellow
    if (-not (Read-YesNo -Prompt 'Apply these Hyper-V host repairs?' -Default $false -ForcePrompt)) { throw 'Preflight repair was declined. No seed disk or VM was created.' }
    & $preflightScript @parameters -Repair -Confirm:$false | Out-Null
    $verified = & $preflightScript @parameters
    if (-not $verified.Passed) { throw 'Preflight still fails after repair. No seed disk or VM was created.' }
    return $verified
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
            throw "Config file not found: $Path. Remove -ConfigPath to start first-run setup, or pass a valid file."
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
        'UseStatic', 'NetworkMode', 'StaticIpCidr', 'IpPrefix', 'IpOctet', 'Gateway', 'DnsServers', 'InterfaceName',
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
    $importPathExplicit = $script:OriginalBoundParameters.ContainsKey('ImportConfigPath')
    if ($configPathExplicit -and $importPathExplicit) {
        throw 'Use either -ConfigPath or -ImportConfigPath, not both.'
    }
    $userConfigPath = Resolve-UserConfigPath
    $legacyImport = $null
    $configPathFinal = if ($importPathExplicit) {
        $legacyImport = Resolve-LegacyConfigImport -Path $ImportConfigPath
        $legacyImport.ConfigPath
    }
    elseif ($configPathExplicit) {
        Expand-UserPath $ConfigPath
    }
    elseif (Test-Path -LiteralPath $userConfigPath) {
        $userConfigPath
    }
    else {
        $userConfigPath
    }

    while ($true) {
        try {
            $script:WrapperConfig = Import-WrapperConfig -Path $configPathFinal -Required:$false -Explicit:$configPathExplicit
            if ($importPathExplicit) {
                $script:WrapperConfig = Normalize-LegacyImportedConfig -Config $script:WrapperConfig -ImportRoot $legacyImport.ImportRoot
            }
            break
        }
        catch {
            if ($importPathExplicit) { throw }
            if (-not $script:PromptAllowed) { throw }
            Write-Warning $_.Exception.Message
        }

        $enteredPath = Read-Host "Config file path (leave blank to continue without a config) [$configPathFinal]"
        if ([string]::IsNullOrWhiteSpace($enteredPath)) {
            $script:WrapperConfig = @{}
            $configPathFinal = $null
            break
        }
        $configPathFinal = Expand-UserPath $enteredPath
        $configPathExplicit = $true
    }

    if ([string]::IsNullOrWhiteSpace($configPathFinal) -or -not (Test-Path -LiteralPath $configPathFinal -ErrorAction SilentlyContinue)) {
        if (-not $script:PromptAllowed -and $configPathExplicit) {
            throw "Config file not found: $configPathFinal"
        }
        if ($script:PromptAllowed) {
            Write-Warning "No config file loaded. Missing values will be requested interactively. Suggested path: $userConfigPath"
        }
        $script:WrapperConfig = @{}
    }

    $script:ResolvedConfigPath = $configPathFinal

    if ($script:WrapperConfig.Count -gt 0) {
        Write-Host "Config loaded: $configPathFinal" -ForegroundColor DarkCyan
        if ($importPathExplicit) {
            Write-Host "Legacy configuration imported read-only from: $($legacyImport.ImportRoot)" -ForegroundColor Green
            Write-Host "Canonical VM root : $($script:WrapperConfig.VmRoot)" -ForegroundColor DarkCyan
            Write-Host "Canonical seed root: $($script:WrapperConfig.SeedRoot)" -ForegroundColor DarkCyan
            if ($script:LegacyPluralizationReport.VmNames.Count -gt 0) {
                Write-Warning "Legacy VM folders remain under '$($script:LegacyPluralizationReport.VmRoot)' and were not moved or registered: $($script:LegacyPluralizationReport.VmNames -join ', ')"
            }
            if ($script:LegacyPluralizationReport.SeedNames.Count -gt 0) {
                Write-Warning "Legacy seed folders remain under '$($script:LegacyPluralizationReport.SeedRoot)' and were not moved: $($script:LegacyPluralizationReport.SeedNames -join ', ')"
            }
        }
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
        [AllowNull()][string]$Default = '',
        [switch]$ForcePrompt
    )

    if ($null -eq $Default) {
        $Default = ''
    }

    if ($script:AutoMode -and -not $ForcePrompt -and -not [string]::IsNullOrWhiteSpace($Default)) {
        return $Default.Trim()
    }

    if (-not $script:PromptAllowed) { return $Default.Trim() }

    if ([string]::IsNullOrWhiteSpace($Default)) {
        $value = Read-ColoredInput -Prompt $Prompt -NoDefault
    }
    else {
        $value = Read-ColoredInput -Prompt $Prompt -Default $Default
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

    $forcePrompt = $false
    while ($true) {
        $value = Read-Default -Prompt $Prompt -Default $Default -ForcePrompt:$forcePrompt
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }

        if (-not $script:PromptAllowed) {
            throw "A value is required for: $Prompt"
        }

        Write-Warning 'A value is required.'
        $forcePrompt = $true
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$Default = $true,
        [switch]$ForcePrompt
    )

    if ($script:AutoMode -and -not $ForcePrompt) {
        return $Default
    }
    if (-not $script:PromptAllowed) { return $Default }

    $defaultText = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $value = Read-ColoredInput -Prompt $Prompt -Default $defaultText
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

    $forcePrompt = $false
    while ($true) {
        $path = Read-Default -Prompt $Prompt -Default $Default -ForcePrompt:$forcePrompt
        $path = Expand-UserPath $path
        if ([string]::IsNullOrWhiteSpace($path)) {
            if (-not $script:PromptAllowed) { throw "A path is required for: $Prompt" }
            Write-Warning 'A path is required.'
            $forcePrompt = $true
            continue
        }
        if (-not $MustExist -or (Test-Path $path)) {
            return $path
        }

        if (-not $script:PromptAllowed) {
            throw "Path not found: $path"
        }

        Write-Warning "Path not found: $path"
        $forcePrompt = $true
    }
}

function Read-PositiveInt {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [int]$Default
    )

    $forcePrompt = $false
    while ($true) {
        $raw = Read-Default -Prompt $Prompt -Default ([string]$Default) -ForcePrompt:$forcePrompt
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0) {
            return $parsed
        }

        if (-not $script:PromptAllowed) {
            throw "Please provide a positive integer for: $Prompt"
        }

        Write-Warning 'Please enter a positive integer.'
        $forcePrompt = $true
    }
}

function Test-SshPublicKeyFile {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $firstLine = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop
        return [bool]($firstLine -match '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)\s+[A-Za-z0-9+/]+={0,3}(\s+.*)?$')
    }
    catch { return $false }
}

function New-SshKeyPair {
    param([Parameter(Mandatory = $true)][string]$PublicKeyPath)

    $publicPath = [System.IO.Path]::GetFullPath((Expand-UserPath $PublicKeyPath))
    if (-not $publicPath.EndsWith('.pub', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "A generated SSH public-key path must end in .pub: $publicPath"
    }
    $privatePath = $publicPath.Substring(0, $publicPath.Length - 4)
    if ((Test-Path -LiteralPath $publicPath) -or (Test-Path -LiteralPath $privatePath)) {
        throw "SSH key generation refused because a key file already exists. Public: '$publicPath'; private: '$privatePath'."
    }

    $sshKeygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
    if (-not $sshKeygen) { throw 'ssh-keygen is unavailable. Install the Windows OpenSSH Client or select an existing public key.' }
    $parent = Split-Path -Parent $privatePath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $commentUser = if ($env:USERNAME) { $env:USERNAME } else { 'hyperv-user' }
    $commentHost = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'windows-host' }
    $comment = "$commentUser@$commentHost"
    $createdPrivate = $false
    $createdPublic = $false
    try {
        Write-Host "Generating Ed25519 SSH key without a passphrase: $privatePath" -ForegroundColor Yellow
        & $sshKeygen.Source -q -t ed25519 -a 64 -C $comment -f $privatePath -N ''
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed with exit code $LASTEXITCODE." }
        $createdPrivate = Test-Path -LiteralPath $privatePath -PathType Leaf
        $createdPublic = Test-Path -LiteralPath $publicPath -PathType Leaf
        if (-not $createdPrivate -or -not $createdPublic -or -not (Test-SshPublicKeyFile $publicPath)) {
            throw 'ssh-keygen did not produce a valid OpenSSH key pair.'
        }
        Write-Host "SSH private key created: $privatePath" -ForegroundColor Green
        Write-Host "SSH public key created : $publicPath" -ForegroundColor Green
        return $publicPath
    }
    catch {
        if (Test-Path -LiteralPath $publicPath) { Remove-Item -LiteralPath $publicPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $privatePath) { Remove-Item -LiteralPath $privatePath -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Read-SshPublicKeyPath {
    param([string]$Prompt, [AllowNull()][string]$Default = '', [switch]$AllowGenerate)
    $forcePrompt = $false
    while ($true) {
        $path = Expand-UserPath (Read-Default -Prompt $Prompt -Default $Default -ForcePrompt:$forcePrompt)
        if (Test-SshPublicKeyFile $path) { return $path }
        if (-not [string]::IsNullOrWhiteSpace($path) -and -not (Test-Path -LiteralPath $path) -and ($AllowGenerate -or $script:PromptAllowed)) {
            $generate = $AllowGenerate.IsPresent
            if (-not $generate -and $script:PromptAllowed) {
                $generate = Read-YesNo -Prompt "No public key exists at '$path'. Generate a new Ed25519 key pair there without a passphrase?" -Default $true -ForcePrompt
            }
            if ($generate) { return (New-SshKeyPair -PublicKeyPath $path) }
        }
        if (-not $script:PromptAllowed) { throw "A valid OpenSSH public key file is required for ${Prompt}: $path" }
        if (Test-Path -LiteralPath $path -PathType Container -ErrorAction SilentlyContinue) {
            Write-Warning "A folder was supplied. Select a public key file such as: $(Join-Path $path 'id_ed25519.pub')"
        }
        elseif (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
            Write-Warning 'The selected file is not an OpenSSH public key. Never select a private key; public keys commonly end in .pub.'
        }
        else { Write-Warning "SSH public key file not found: $path" }
        $Default = ''
        $forcePrompt = $true
    }
}

function Read-NetworkMode {
    param([AllowNull()][string]$ConfiguredMode, [bool]$LegacyUseStatic)

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredMode)) {
        $validMode = @('Dhcp','PrivateNat','Advanced') | Where-Object { $_ -eq $ConfiguredMode } | Select-Object -First 1
        if ($validMode) { return $validMode }
        if (-not $script:PromptAllowed) { throw "Invalid NetworkMode: $ConfiguredMode. Expected Dhcp, PrivateNat, or Advanced." }
        Write-Warning "Invalid NetworkMode: $ConfiguredMode"
    }
    if ($script:AutoMode -or -not $script:PromptAllowed) {
        return $(if ($LegacyUseStatic) { 'PrivateNat' } else { 'Dhcp' })
    }

    Write-Host ''
    Write-Host 'How should this VM connect?'
    Write-Host '  [1] Automatic network (DHCP) - recommended'
    Write-Host '  [2] Private NAT with a fixed IP'
    Write-Host '  [3] Advanced/custom networking'
    $defaultChoice = if ($LegacyUseStatic) { '2' } else { '1' }
    while ($true) {
        $choice = Read-ColoredInput -Prompt 'Select' -Default $defaultChoice
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = $defaultChoice }
        switch ($choice.Trim().ToLowerInvariant()) {
            { $_ -in @('1','dhcp') } { return 'Dhcp' }
            { $_ -in @('2','nat','privatenat') } { return 'PrivateNat' }
            { $_ -in @('3','advanced','custom') } { return 'Advanced' }
            default { Write-Warning 'Select 1, 2, or 3.' }
        }
    }
}

function Get-SuggestedStaticCidr {
    param([string]$StaticIpCidr, [string]$IpPrefix, [int]$IpOctet)
    if (-not [string]::IsNullOrWhiteSpace($StaticIpCidr)) { return $StaticIpCidr }
    if (-not [string]::IsNullOrWhiteSpace($IpPrefix) -and $IpOctet -ge 1) {
        return "$($IpPrefix.Trim().TrimEnd('.')).$IpOctet/24"
    }
    return '192.168.200.10/24'
}

function Get-SuggestedPrivateGateway {
    param([string]$StaticIpCidr)
    $network = ConvertTo-IPv4NetworkPrefix $StaticIpCidr
    if ($network -match '^(\d+)\.(\d+)\.(\d+)\.\d+/24$') { return "$($matches[1]).$($matches[2]).$($matches[3]).1" }
    return ''
}

function Get-SuggestedSwitchName {
    param([string]$Mode, [AllowNull()][string]$ConfiguredName)
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredName)) { return $ConfiguredName }
    if ($Mode -in @('PrivateNat','Advanced')) { return 'HyperV-NAT' }
    if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) {
        $defaultSwitch = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
        if ($defaultSwitch) { return $defaultSwitch.Name }
        $firstSwitch = Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($firstSwitch) { return $firstSwitch.Name }
    }
    return 'Default Switch'
}

function Read-NonNegativeInt {
    param([string]$Prompt, [int]$Default, [int]$Maximum = [int]::MaxValue)
    $forcePrompt = $false
    while ($true) {
        $raw = Read-Default -Prompt $Prompt -Default ([string]$Default) -ForcePrompt:$forcePrompt
        $parsed = -1
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 0 -and $parsed -le $Maximum) { return $parsed }
        if (-not $script:PromptAllowed) { throw "Please provide an integer from 0 through $Maximum for: $Prompt" }
        Write-Warning "Please enter an integer from 0 through $Maximum."
        $forcePrompt = $true
    }
}

function Read-MacAddress {
    param([string]$Prompt, [string]$Default)
    $forcePrompt = $false
    while ($true) {
        $value = Read-Default -Prompt $Prompt -Default $Default -ForcePrompt:$forcePrompt
        if (($value -replace '[:\-.]', '') -match '^[0-9A-Fa-f]{12}$') { return $value }
        if (-not $script:PromptAllowed) { throw "Invalid MAC address: $value" }
        Write-Warning 'MAC address must contain exactly 12 hexadecimal digits.'
        $forcePrompt = $true
    }
}

function Read-ValidatedText {
    param([string]$Prompt, [string]$Default, [string]$Pattern, [string]$ErrorMessage)
    $forcePrompt = $false
    while ($true) {
        $value = Read-Default -Prompt $Prompt -Default $Default -ForcePrompt:$forcePrompt
        if ($value -match $Pattern) { return $value }
        if (-not $script:PromptAllowed) { throw "$ErrorMessage Got: $value" }
        Write-Warning $ErrorMessage
        $forcePrompt = $true
    }
}

function Test-SafeVmName {
    param([AllowNull()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 128) { return $false }
    if ($Name -in @('.', '..') -or $Name.EndsWith('.') -or $Name.EndsWith(' ')) { return $false }
    if ($Name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $false }
    if ($Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') { return $false }
    return $true
}

function Read-SafeVmName {
    param([AllowNull()][string]$Default)
    $forcePrompt = $false
    while ($true) {
        $value = Read-Default -Prompt 'VM name' -Default $Default -ForcePrompt:$forcePrompt
        if (Test-SafeVmName $value) { return $value }
        if (-not $script:PromptAllowed) { throw "Invalid VM name: $value. Use one Windows-safe path segment without separators, dot segments, or reserved device names." }
        Write-Warning 'Use one Windows-safe VM name without path separators, dot segments, trailing dots/spaces, or reserved device names.'
        $Default = ''
        $forcePrompt = $true
    }
}

function Resolve-SafeChildPath {
    param([string]$Root, [string]$ChildName)
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $resolvedChild = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $ChildName)).TrimEnd('\')
    $boundary = $resolvedRoot + '\'
    if (-not $resolvedChild.StartsWith($boundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolved child path escapes its authorized root: $resolvedChild"
    }
    return $resolvedChild
}

function Test-IpAddressValue {
    param([string]$Value)
    $parsed = $null
    return [System.Net.IPAddress]::TryParse($Value, [ref]$parsed) -and
        $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Read-IpAddressValue {
    param([string]$Prompt, [string]$Default)
    $forcePrompt = $false
    while ($true) {
        $value = Read-Default -Prompt $Prompt -Default $Default -ForcePrompt:$forcePrompt
        if (Test-IpAddressValue $value) { return $value }
        if (-not $script:PromptAllowed) { throw "Invalid IP address for ${Prompt}: $value" }
        Write-Warning 'Please enter a valid IP address.'
        $forcePrompt = $true
    }
}

function Read-StaticCidrValue {
    param([string]$Prompt, [string]$Default)
    $forcePrompt = $false
    while ($true) {
        $value = Read-Default -Prompt $Prompt -Default $Default -ForcePrompt:$forcePrompt
        if ($value -match '^(.+)/(\d{1,2})$' -and (Test-IpAddressValue $matches[1]) -and [int]$matches[2] -le 32) { return $value }
        if (-not $script:PromptAllowed) { throw "Invalid IPv4 CIDR for ${Prompt}: $value" }
        Write-Warning 'Please enter a valid IPv4 address with CIDR prefix.'
        $forcePrompt = $true
    }
}

function Read-IpLastOctet {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [AllowNull()][string]$Default = ''
    )

    $forcePrompt = $false
    while ($true) {
        $raw = Read-Default -Prompt $Prompt -Default $Default -ForcePrompt:$forcePrompt
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 254) {
            return [string]$parsed
        }

        if (-not $script:PromptAllowed) {
            throw "Please provide an IP last octet between 1 and 254 for: $Prompt"
        }

        Write-Warning 'Please enter a value between 1 and 254.'
        $forcePrompt = $true
    }
}

function Read-OptionalPassword {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [AllowNull()][string]$Default = ''
    )

    if ($null -eq $Default) { $Default = '' }
    if ($script:AutoMode -and [string]::IsNullOrWhiteSpace($Default)) { return $null }
    if ($Default.IndexOfAny([char[]]@("`r", "`n", [char]0)) -ge 0) {
        if (-not $script:PromptAllowed) { throw 'Rescue password cannot contain newlines or NUL characters.' }
        Write-Warning 'Rescue password cannot contain newlines or NUL characters.'
        $Default = ''
    }
    if ($script:AutoMode -and -not [string]::IsNullOrWhiteSpace($Default)) {
        return $Default.Trim()
    }

    $promptText = if ([string]::IsNullOrWhiteSpace($Default)) { $Prompt } else { "$Prompt [configured value hidden; Enter to use it]" }
    $secureValue = Read-Host $promptText -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
    try {
        $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ([string]::IsNullOrWhiteSpace($value) -and -not [string]::IsNullOrWhiteSpace($Default)) {
        $value = $Default
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
        $windowsDir = Join-Path $candidate 'windows-scripts'
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
        return Read-StaticCidrValue -Prompt 'Static IP/CIDR' -Default $ProvidedStaticIpCidr
    }

    $prefix = Read-RequiredValue -Prompt 'Static IP prefix (first three octets, e.g. a.b.c)' -Default $ProvidedIpPrefix
    $octetDefault = if ($ProvidedIpOctet -ge 1) { [string]$ProvidedIpOctet } else { '' }
    $selectedIpOctet = Read-IpLastOctet -Prompt ("IP last octet for {0}.[x]" -f $prefix) -Default $octetDefault
    return Read-StaticCidrValue -Prompt 'Static IP/CIDR' -Default ("{0}.{1}/24" -f $prefix.Trim().TrimEnd('.'), $selectedIpOctet)
}

function Get-ValidatedBooleanSetting {
    param([string]$Name, [bool]$CurrentValue)
    $raw = Get-EffectiveSetting -Name $Name -CurrentValue $CurrentValue
    if ($raw -is [bool]) { return $raw }
    $parsed = $false
    if ([bool]::TryParse([string]$raw, [ref]$parsed)) { return $parsed }
    if (-not $script:PromptAllowed) { throw "Invalid Boolean value for ${Name}: $raw" }
    Write-Warning "Invalid Boolean value for ${Name}: $raw"
    return Read-YesNo -Prompt $Name -Default $CurrentValue -ForcePrompt
}

function Get-ValidatedIntegerSetting {
    param([string]$Name, [int]$CurrentValue, [int]$Minimum, [int]$Maximum)
    $raw = Get-EffectiveSetting -Name $Name -CurrentValue $CurrentValue
    $parsed = 0
    if ([int]::TryParse([string]$raw, [ref]$parsed) -and $parsed -ge $Minimum -and $parsed -le $Maximum) { return $parsed }
    if (-not $script:PromptAllowed) { throw "Invalid integer value for $Name. Expected $Minimum through $Maximum; got: $raw" }
    Write-Warning "Invalid integer value for $Name. Expected $Minimum through $Maximum; got: $raw"
    while ($true) {
        $entered = Read-ColoredInput -Prompt "$Name ($Minimum-$Maximum)" -NoDefault
        if ([int]::TryParse($entered, [ref]$parsed) -and $parsed -ge $Minimum -and $parsed -le $Maximum) { return $parsed }
        Write-Warning "Enter an integer from $Minimum through $Maximum."
    }
}

try {
    Write-Host 'Hyper-V Golden Image VM Creator' -ForegroundColor Green
    Write-Host $(if ($ConfigureOnly) { 'Configuration-only mode: prepare SSH access and save settings without creating a seed disk or VM.' } else { 'This script creates a NoCloud seed disk, then creates a brand-new VM from the golden VHDX.' })

    if ($ConfigureOnly -and $SeedOnly) { throw '-ConfigureOnly and -SeedOnly cannot be used together.' }

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
    $seedOnlySetting = Get-ValidatedBooleanSetting -Name 'SeedOnly' -CurrentValue $SeedOnly.IsPresent
    $UseStatic = Get-ValidatedBooleanSetting -Name 'UseStatic' -CurrentValue $UseStatic
    $NetworkMode = Get-EffectiveSetting -Name 'NetworkMode' -CurrentValue $NetworkMode
    $StaticIpCidr = Get-EffectiveSetting -Name 'StaticIpCidr' -CurrentValue $StaticIpCidr
    $IpPrefix = Get-EffectiveSetting -Name 'IpPrefix' -CurrentValue $IpPrefix
    $IpOctet = Get-ValidatedIntegerSetting -Name 'IpOctet' -CurrentValue $IpOctet -Minimum 0 -Maximum 254
    $Gateway = Get-EffectiveSetting -Name 'Gateway' -CurrentValue $Gateway
    $DnsServers = @(Get-EffectiveSetting -Name 'DnsServers' -CurrentValue $DnsServers)
    $InterfaceName = Get-EffectiveSetting -Name 'InterfaceName' -CurrentValue $InterfaceName
    $EnableRescueUser = Get-ValidatedBooleanSetting -Name 'EnableRescueUser' -CurrentValue $EnableRescueUser
    $RescueUser = Get-EffectiveSetting -Name 'RescueUser' -CurrentValue $RescueUser
    $RescueSshPublicKeyPath = Get-EffectiveSetting -Name 'RescueSshPublicKeyPath' -CurrentValue $RescueSshPublicKeyPath
    $Password = Get-EffectiveSetting -Name 'Password' -CurrentValue $Password
    $EnableRescueSshPassword = Get-ValidatedBooleanSetting -Name 'EnableRescueSshPassword' -CurrentValue $EnableRescueSshPassword
    $SetRescuePassword = Get-ValidatedBooleanSetting -Name 'SetRescuePassword' -CurrentValue $SetRescuePassword
    $MemoryStartupGb = Get-ValidatedIntegerSetting -Name 'MemoryStartupGb' -CurrentValue $MemoryStartupGb -Minimum 1 -Maximum 1024
    $MinimumMemoryGb = Get-ValidatedIntegerSetting -Name 'MinimumMemoryGb' -CurrentValue $MinimumMemoryGb -Minimum 1 -Maximum 1024
    $MaximumMemoryGb = Get-ValidatedIntegerSetting -Name 'MaximumMemoryGb' -CurrentValue $MaximumMemoryGb -Minimum 1 -Maximum 1024
    $ProcessorCount = Get-ValidatedIntegerSetting -Name 'ProcessorCount' -CurrentValue $ProcessorCount -Minimum 1 -Maximum 256
    $SeedControllerLocation = Get-ValidatedIntegerSetting -Name 'SeedControllerLocation' -CurrentValue $SeedControllerLocation -Minimum 0 -Maximum 63
    $StartAfterCreate = Get-ValidatedBooleanSetting -Name 'StartAfterCreate' -CurrentValue $StartAfterCreate
    foreach ($pathVariableName in @('RepoRoot', 'ConfigOutputPath', 'SshPublicKeyPath', 'RescueSshPublicKeyPath', 'GoldenVhdxPath', 'VmRoot', 'SeedRoot', 'SeedDiskPath')) {
        Set-Variable -Name $pathVariableName -Value (Expand-UserPath (Get-Variable -Name $pathVariableName -ValueOnly))
    }
    if ($script:AutoMode) {
        Write-Host 'Auto mode is enabled. Valid values are reused; missing or invalid values are requested unless -NoPrompt is set.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'Press Enter to accept suggested values. Blank required values will be rejected.' -ForegroundColor Yellow
    }

    Write-Section 'Project paths'
    $detectedRepoRoot = Resolve-RepoRoot
    $repoRootFinal = Read-RequiredPath -Prompt 'Repo root (must contain .\windows-scripts and .\cloud-init)' -Default $detectedRepoRoot

    $defaultDataRoot = Resolve-DefaultDataRoot
    if ([string]::IsNullOrWhiteSpace($VmRoot)) { $VmRoot = Join-Path $defaultDataRoot 'VMs' }
    if ([string]::IsNullOrWhiteSpace($SeedRoot)) { $SeedRoot = Join-Path $defaultDataRoot 'Seeds' }
    if ([string]::IsNullOrWhiteSpace($GoldenVhdxPath)) { $GoldenVhdxPath = Resolve-DefaultGoldenVhdxPath $repoRootFinal }

    $seedScript = Join-Path $repoRootFinal 'windows-scripts\New-NoCloudSeedDisk.ps1'
    $vmScript = Join-Path $repoRootFinal 'windows-scripts\New-HyperVVmFromGolden.ps1'
    $templateRoot = Join-Path $repoRootFinal 'cloud-init'

    foreach ($requiredFile in @($seedScript, $vmScript, $templateRoot)) {
        if (-not (Test-Path $requiredFile)) {
            throw "Required project path not found: $requiredFile"
        }
    }

    Write-Section 'VM identity'
    $vmName = Read-SafeVmName -Default $DeviceName
    $hostnameFinal = Read-ValidatedText -Prompt 'Hostname' -Default $(if ($Hostname) { $Hostname } else { $vmName }) -Pattern '^(?=.{1,253}$)([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(\.([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?))*$' -ErrorMessage 'Enter a valid DNS hostname.'
    $adminUserFinal = Read-ValidatedText -Prompt 'Primary admin username' -Default $AdminUser -Pattern '^[a-z_][a-z0-9_-]{0,31}$' -ErrorMessage 'Enter a valid Linux username.'
    $defaultSshPublicKeyPath = if ($SshPublicKeyPath) { $SshPublicKeyPath } else { Join-Path $env:USERPROFILE '.ssh\id_ed25519.pub' }
    $sshPublicKeyPathFinal = Read-SshPublicKeyPath -Prompt 'Existing SSH public key, or path for a new key' -Default $defaultSshPublicKeyPath -AllowGenerate:$GenerateSshKey

    $autoMac = New-RandomHyperVMacAddress
    $macAddressFinal = Read-MacAddress -Prompt 'MAC address (same value will be used for seed + VM)' -Default $(if ($MacAddress) { $MacAddress } else { $autoMac })

    Write-Section 'Storage and switch'
    $seedOnlyFinal = if ($ConfigureOnly) { $false } else { Read-YesNo -Prompt 'Only create/overwrite the seed disk and skip VM creation?' -Default $seedOnlySetting }

    $goldenVhdxPathFinal = $null
    if (-not $seedOnlyFinal) {
        $goldenVhdxPathFinal = Read-RequiredPath -Prompt 'Golden VHDX path' -Default $GoldenVhdxPath
    }

    #if (-not $SeedDiskPath) {
    #    $seedRootFinal = Read-RequiredPath -Prompt 'Seed disks folder' -Default $SeedRoot -MustExist $false
    #    $seedDiskPathFinal = Join-Path $seedRootFinal ("{0}-seed.vhdx" -f $vmName)
    #}
    #else {
    #    $seedDiskPathFinal = $SeedDiskPath
    #}
    #Write-Host "Seed disk will be created at: $seedDiskPathFinal"

    $seedRootFinal = $SeedRoot
    if (-not $SeedDiskPath) {
        $seedRootFinal = Read-RequiredPath -Prompt 'Seed disks root folder' -Default $SeedRoot -MustExist $false
        $seedVmFolderFinal = Resolve-SafeChildPath -Root $seedRootFinal -ChildName $vmName
        $seedDiskPathFinal = Join-Path $seedVmFolderFinal ("{0}-seed.vhdx" -f $vmName)
    }
    else {
        # Explicit SeedDiskPath is treated as a full override and is not placed under a per-VM folder.
        $seedDiskPathFinal = $SeedDiskPath
        $seedVmFolderFinal = Split-Path -Parent $seedDiskPathFinal
    }

    Write-EngineValue -Label 'Seed folder will be: ' -Value $seedVmFolderFinal
    Write-EngineValue -Label 'Seed disk will be created at: ' -Value $seedDiskPathFinal

    $vmRootFinal = $null
    $switchNameFinal = $null
    if (-not $seedOnlyFinal) {
        $vmRootFinal = Read-RequiredPath -Prompt 'VM root folder' -Default $VmRoot -MustExist $false
    }

    Write-Section 'Network setup'
    $networkModeFinal = Read-NetworkMode -ConfiguredMode $NetworkMode -LegacyUseStatic $UseStatic
    $useStaticFinal = $networkModeFinal -ne 'Dhcp'
    $interfaceNameFinal = if ($networkModeFinal -eq 'Advanced') {
        Read-ValidatedText -Prompt 'Cloud-init interface name' -Default $InterfaceName -Pattern '^[a-zA-Z0-9_.-]{1,15}$' -ErrorMessage 'Enter a valid Linux interface name (1-15 characters).'
    }
    else { 'lan0' }

    $staticIpCidrFinal = $null
    $gatewayFinal = $null
    $dnsServersFinal = @()

    if ($networkModeFinal -eq 'PrivateNat') {
        $suggestedCidr = Get-SuggestedStaticCidr -StaticIpCidr $StaticIpCidr -IpPrefix $IpPrefix -IpOctet $IpOctet
        $suggestedIp = $suggestedCidr -replace '/.*$', ''
        $selectedIp = Read-IpAddressValue -Prompt 'VM IP address' -Default $suggestedIp
        $staticIpCidrFinal = "$selectedIp/24"
        Assert-IpAddressAvailable -IpAddress $selectedIp -VmName $vmName
        $suggestedGateway = if (-not [string]::IsNullOrWhiteSpace($Gateway)) { $Gateway } else { Get-SuggestedPrivateGateway $staticIpCidrFinal }
        $gatewayFinal = Read-IpAddressValue -Prompt 'Gateway' -Default $suggestedGateway
        $dnsServersFinal = @(ConvertFrom-DnsInput -Value $DnsServers)
        $dnsDefault = if ($dnsServersFinal.Count -gt 0) { $dnsServersFinal -join ', ' } else { '1.1.1.1, 8.8.8.8' }
        while ($true) {
            $dnsInput = Read-RequiredValue -Prompt 'DNS servers' -Default $dnsDefault
            $dnsServersFinal = @(ConvertFrom-DnsInput -Value @($dnsInput))
            if ($dnsServersFinal.Count -gt 0 -and @($dnsServersFinal | Where-Object { -not (Test-IpAddressValue $_) }).Count -eq 0) { break }
            if (-not $script:PromptAllowed) { throw 'At least one valid DNS server is required for private NAT.' }
            Write-Warning 'Enter one or more valid DNS IP addresses separated by commas.'
            $dnsDefault = ''
        }
    }
    elseif ($networkModeFinal -eq 'Advanced') {
        $staticIpCidrFinal = Resolve-StaticIp -ProvidedStaticIpCidr $StaticIpCidr -ProvidedIpPrefix $IpPrefix -ProvidedIpOctet $IpOctet
        Assert-IpAddressAvailable -IpAddress ($staticIpCidrFinal -replace '/.*$', '') -VmName $vmName
        $gatewayFinal = Read-IpAddressValue -Prompt 'Gateway' -Default $Gateway
        $dnsServersFinal = @(ConvertFrom-DnsInput -Value $DnsServers)
        while (-not $dnsServersFinal -or $dnsServersFinal.Count -eq 0 -or @($dnsServersFinal | Where-Object { -not (Test-IpAddressValue $_) }).Count -gt 0) {
            if (-not $script:PromptAllowed) { throw 'At least one valid DNS server is required for static networking.' }
            if ($dnsServersFinal.Count -gt 0) { Write-Warning 'One or more DNS server values are invalid.' }
            $dnsInput = Read-RequiredValue -Prompt 'DNS servers comma separated' -Default ''
            $dnsServersFinal = @(ConvertFrom-DnsInput -Value @($dnsInput))
        }
    }

    if (-not $seedOnlyFinal) {
        $switchDefault = Get-SuggestedSwitchName -Mode $networkModeFinal -ConfiguredName $SwitchName
        $switchNameFinal = Read-RequiredValue -Prompt 'Hyper-V switch' -Default $switchDefault
    }

    Write-Host ''
    Write-Host 'Network configuration:' -ForegroundColor Cyan
    Write-EngineValue -Label '  Mode       : ' -Value $(switch ($networkModeFinal) { 'Dhcp' {'Automatic (DHCP)'} 'PrivateNat' {'Private NAT with fixed IP'} default {'Advanced/custom'} })
    if ($useStaticFinal) {
        Write-EngineValue -Label '  VM address : ' -Value $staticIpCidrFinal
        Write-EngineValue -Label '  Network    : ' -Value (ConvertTo-IPv4NetworkPrefix $staticIpCidrFinal)
        Write-EngineValue -Label '  Gateway    : ' -Value $gatewayFinal
        Write-EngineValue -Label '  DNS        : ' -Value ($dnsServersFinal -join ', ')
    }
    else { Write-EngineValue -Label '  Address    : ' -Value 'Assigned automatically by DHCP' }
    if (-not $seedOnlyFinal) { Write-EngineValue -Label '  Switch     : ' -Value $switchNameFinal }

    Write-Section 'Rescue user'
    $enableRescueUserFinal = Read-YesNo -Prompt 'Enable rescue user?' -Default $EnableRescueUser
    $rescueUserFinal = $RescueUser
    $rescueSshPublicKeyPathFinal = $null
    $rescuePasswordFinal = $null
    $enableRescueSshPasswordFinal = $false

    if ($enableRescueUserFinal) {
        $rescueUserFinal = Read-ValidatedText -Prompt 'Rescue username' -Default $RescueUser -Pattern '^[a-z_][a-z0-9_-]{0,31}$' -ErrorMessage 'Enter a valid Linux username.'
        $useSeparateRescueKey = Read-YesNo -Prompt 'Use a different SSH public key for rescue user?' -Default (-not [string]::IsNullOrWhiteSpace($RescueSshPublicKeyPath))
        if ($useSeparateRescueKey) {
            $rescueSshPublicKeyPathFinal = Read-SshPublicKeyPath -Prompt 'Rescue SSH public key file' -Default $RescueSshPublicKeyPath
        }

        $enableRescueSshPasswordFinal = Read-YesNo -Prompt 'Enable password SSH login for rescue user?' -Default $EnableRescueSshPassword
        $shouldSetPassword = $enableRescueSshPasswordFinal -or $SetRescuePassword -or (-not [string]::IsNullOrWhiteSpace($Password))
        if ($shouldSetPassword -and -not $ConfigureOnly) {
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
        $seedControllerLocationFinal = Read-NonNegativeInt -Prompt 'Seed disk SCSI controller location' -Default $SeedControllerLocation -Maximum 63
        $startAfterCreateFinal = Read-YesNo -Prompt 'Start the VM immediately after creation?' -Default $StartAfterCreate
    }

    if ($ConfigureOnly) {
        Write-Host 'Configuration-only mode skips Hyper-V preflight and host changes.' -ForegroundColor Yellow
    }
    elseif (-not $seedOnlyFinal) {
        $requireNatFinal = $networkModeFinal -eq 'PrivateNat'
        [void](Invoke-IntegratedPreflight -RepoRoot $repoRootFinal -SwitchName $switchNameFinal -RequireNat $requireNatFinal -StaticIpCidr $staticIpCidrFinal -Gateway $gatewayFinal)
    }
    else {
        Assert-Command -Name @('New-VHD', 'Mount-VHD', 'Get-Disk', 'Initialize-Disk', 'New-Partition', 'Format-Volume', 'Dismount-DiskImage')
    }

    if (-not $ConfigureOnly) {
        foreach ($directory in @($defaultDataRoot, $seedRootFinal, $vmRootFinal) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) {
            if (-not (Test-Path -LiteralPath $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
        }
    }

    $settingsToSave = @{
        RepoRoot=$repoRootFinal; AdminUser=$adminUserFinal; SshPublicKeyPath=$sshPublicKeyPathFinal
        GoldenVhdxPath=$(if ($seedOnlyFinal) { $GoldenVhdxPath } else { $goldenVhdxPathFinal })
        VmRoot=$(if ($seedOnlyFinal) { $VmRoot } else { $vmRootFinal }); SeedRoot=$seedRootFinal
        SwitchName=$(if ($seedOnlyFinal) { $SwitchName } else { $switchNameFinal })
        SeedOnly=$false; UseStatic=$useStaticFinal; NetworkMode=$networkModeFinal
        StaticIpCidr=$staticIpCidrFinal; Gateway=$gatewayFinal; DnsServers=@($dnsServersFinal)
        InterfaceName=$interfaceNameFinal; EnableRescueUser=$enableRescueUserFinal; RescueUser=$rescueUserFinal
        RescueSshPublicKeyPath=$rescueSshPublicKeyPathFinal; EnableRescueSshPassword=$enableRescueSshPasswordFinal
        SetRescuePassword=$SetRescuePassword; MemoryStartupGb=$memoryStartupGbFinal
        MinimumMemoryGb=$minimumMemoryGbFinal; MaximumMemoryGb=$maximumMemoryGbFinal
        ProcessorCount=$processorCountFinal; SeedControllerLocation=$seedControllerLocationFinal
        StartAfterCreate=$startAfterCreateFinal
    }
    if ($ConfigureOnly) {
        $settingsToSave.DeviceName = $vmName
        $settingsToSave.Hostname = $hostnameFinal
        $settingsToSave.MacAddress = $macAddressFinal
    }
    $userConfigPath = if ($ConfigureOnly -and $ConfigOutputPath) { [System.IO.Path]::GetFullPath($ConfigOutputPath) } else { Resolve-UserConfigPath }

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
        'Mode' = $(if ($ConfigureOnly) { 'Configuration only (no Hyper-V changes)' } elseif ($seedOnlyFinal) { 'Seed only (overwrite if exists)' } else { 'Seed + VM creation' })
        'Switch' = $(if ($seedOnlyFinal) { '-' } else { $switchNameFinal })
        'MAC address' = $macAddressFinal
        'Interface name' = $interfaceNameFinal
        'Network mode' = $networkModeFinal
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

    $proceedPrompt = if ($ConfigureOnly) { 'Save this configuration file?' } elseif ($seedOnlyFinal) { 'Proceed with seed disk creation/overwrite?' } else { 'Proceed with seed + VM creation?' }
    if (-not (Read-YesNo -Prompt $proceedPrompt -Default $true)) {
        Write-Host 'Cancelled by user.' -ForegroundColor Yellow
        return
    }

    if ($ConfigureOnly) {
        Save-UserConfig -Settings $settingsToSave -Path $userConfigPath
        $script:ResolvedConfigPath = $userConfigPath
        Write-Section 'Done'
        Write-Host "Configuration saved: $userConfigPath" -ForegroundColor Green
        Write-Host "SSH public key  : $sshPublicKeyPathFinal" -ForegroundColor Green
        Write-Host 'No seed disk, VM, virtual switch, NAT, or IP reservation was created.' -ForegroundColor Green
        return
    }

    $ipAllocationMutex = $null
    if ($useStaticFinal) {
        $ipAllocationMutex = Enter-IpAllocationLock
        Assert-IpAddressAvailable -IpAddress ($staticIpCidrFinal -replace '/.*$', '') -VmName $vmName
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

    try {
        & $seedScript @seedParams

        if (-not $seedOnlyFinal) {
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

            if ($startAfterCreateFinal) { $vmParams.StartAfterCreate = $true }
            & $vmScript @vmParams
        }

        if ($useStaticFinal) {
            $reservationSwitch = if ($seedOnlyFinal) { $SwitchName } else { $switchNameFinal }
            Save-IpAllocation -VmName $vmName -StaticIpCidr $staticIpCidrFinal -SwitchName $reservationSwitch -SeedDiskPath $seedDiskPathFinal
        }

        try {
            Save-UserConfig -Settings $settingsToSave -Path $userConfigPath
            $script:ResolvedConfigPath = $userConfigPath
            Write-Host "User configuration saved: $userConfigPath" -ForegroundColor Green
        }
        catch {
            Write-Warning "Creation succeeded, but the user configuration could not be saved: $($_.Exception.Message)"
        }
    }
    finally {
        Exit-IpAllocationLock -Mutex $ipAllocationMutex
    }

    if ($seedOnlyFinal) {
        Write-Section 'Done'
        Write-Host "Seed disk created successfully: $seedDiskPathFinal" -ForegroundColor Green
        Write-Host "Seed summary file: $seedDiskPathFinal.rescue.txt"
        return
    }

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
