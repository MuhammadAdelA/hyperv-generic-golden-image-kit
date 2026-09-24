$repoRoot = Split-Path -Parent $PSScriptRoot

Describe 'PowerShell syntax' {
    It 'parses every PowerShell script without errors' {
        $files = Get-ChildItem -Path $repoRoot -Recurse -File -Filter '*.ps1'
        foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should Be 0
        }
    }
}

Describe 'Configuration contract' {
    $wrapper = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\create-vm.ps1')

    It 'uses a per-user config and supports strict non-interactive mode' {
        ($wrapper -match 'LOCALAPPDATA') | Should Be $true
        ($wrapper -match '\[switch\]\$NoPrompt') | Should Be $true
        ($wrapper -match 'ExpandEnvironmentVariables') | Should Be $true
    }

    It 'accepts SCSI controller location zero' {
        ($wrapper -match 'Read-NonNegativeInt') | Should Be $true
    }

    It 'exposes SeedOnly as a native switch' {
        ($wrapper -match '\[switch\]\$SeedOnly') | Should Be $true
        ($wrapper -match '\[bool\]\$SeedOnly') | Should Be $false
        ($wrapper -match '\$SeedOnly\.IsPresent') | Should Be $true
    }

    It 'has one public entry point with integrated first-run, preflight, and persistence' {
        ($wrapper -match 'Invoke-IntegratedPreflight') | Should Be $true
        ($wrapper -match 'Save-UserConfig') | Should Be $true
        ($wrapper -match 'config-examples') | Should Be $false
        ($wrapper -match "Apply these Hyper-V host repairs\?") | Should Be $true
        ($wrapper -match 'Repair -Confirm:\$false') | Should Be $true
    }

    It 'supports configuration-only mode and explicit SSH key generation' {
        ($wrapper -match '\[switch\]\$ConfigureOnly') | Should Be $true
        ($wrapper -match '\[switch\]\$GenerateSshKey') | Should Be $true
        ($wrapper -match '\[string\]\$ConfigOutputPath') | Should Be $true
        ($wrapper -match 'Configuration-only mode skips Hyper-V preflight') | Should Be $true
        $wrapper.IndexOf('if ($ConfigureOnly) {') | Should BeLessThan $wrapper.IndexOf('& $seedScript @seedParams')
    }

    It 'validates VM names as a single safe path segment' {
        ($wrapper -match 'function Test-SafeVmName') | Should Be $true
        ($wrapper -match 'GetInvalidFileNameChars') | Should Be $true
        ($wrapper -match 'function Resolve-SafeChildPath') | Should Be $true
    }

    It 'preserves full-VM settings during SeedOnly and saves only after successful creation' {
        ($wrapper -match 'SeedOnly=\$false') | Should Be $true
        ($wrapper -match 'if \(\$seedOnlyFinal\) \{ \$GoldenVhdxPath \}') | Should Be $true
        $wrapper.LastIndexOf('Save-UserConfig -Settings') | Should BeGreaterThan $wrapper.IndexOf('& $seedScript @seedParams')
    }
}

Describe 'First-run config persistence' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'windows-scripts\create-vm.ps1'), [ref]$tokens, [ref]$errors)
        foreach ($functionName in @('ConvertTo-Psd1Literal', 'Save-UserConfig')) {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }

    It 'creates a valid config without a template and excludes passwords' {
        $path = Join-Path $TestDrive 'new-user\New-GoldenVmInteractive.config.psd1'
        Save-UserConfig -Path $path -Settings @{ SwitchName="Lab's NAT"; UseStatic=$true; DnsServers=@('1.1.1.1','8.8.8.8') }
        $saved = Import-PowerShellDataFile -Path $path
        $saved.SwitchName | Should Be "Lab's NAT"
        @($saved.DnsServers).Count | Should Be 2
        ((Get-Content -Raw -LiteralPath $path) -match 'Password\s*=') | Should Be $false

        Save-UserConfig -Path $path -Settings @{ SwitchName='Replacement'; UseStatic=$false }
        (Import-PowerShellDataFile -Path $path).SwitchName | Should Be 'Replacement'
    }
}

Describe 'Read-only legacy configuration import' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'windows-scripts\create-vm.ps1'), [ref]$tokens, [ref]$errors)
        foreach ($functionName in @('Expand-UserPath', 'Resolve-LegacyConfigImport', 'Normalize-LegacyImportedConfig')) {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }

    It 'discovers a migrated config and canonicalizes the historical extra-s roots without moving data' {
        $legacyRoot = Join-Path $TestDrive 'HyperV'
        $backup = Join-Path $legacyRoot '.hyperv-generic-golden-image.migrated-backup-20260816'
        foreach ($directory in @($backup, (Join-Path $legacyRoot 'VMs'), (Join-Path $legacyRoot 'VMss\old-vm'), (Join-Path $legacyRoot 'Seeds'), (Join-Path $legacyRoot 'Seedss\old-vm'))) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $legacyConfigPath = Join-Path $backup 'New-GoldenVmInteractive.config.psd1'
        Set-Content -LiteralPath $legacyConfigPath -Value "@{ VmRoot='D:\HyperV\VMss'; SeedRoot='D:\HyperV\Seedss'; GoldenVhdxPath='D:\missing.vhdx'; AdminUser='ubuntu' }"

        $resolved = Resolve-LegacyConfigImport -Path $legacyRoot
        [System.IO.Path]::GetFullPath($resolved.ConfigPath) | Should Be ([System.IO.Path]::GetFullPath((Get-Item -LiteralPath $legacyConfigPath).FullName))
        $imported = Normalize-LegacyImportedConfig -Config (Import-PowerShellDataFile -LiteralPath $resolved.ConfigPath) -ImportRoot $resolved.ImportRoot
        $imported.VmRoot | Should Be (Join-Path $resolved.ImportRoot 'VMs')
        $imported.SeedRoot | Should Be (Join-Path $resolved.ImportRoot 'Seeds')
        $imported.ContainsKey('GoldenVhdxPath') | Should Be $false
        (@($script:LegacyPluralizationReport.VmNames) -contains 'old-vm') | Should Be $true
        (@($script:LegacyPluralizationReport.SeedNames) -contains 'old-vm') | Should Be $true

        $normalizer = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Normalize-LegacyImportedConfig' }, $true).Extent.Text
        ($normalizer -match 'Move-Item|Import-VM|Remove-Item') | Should Be $false
    }
}

Describe 'Dynamic path and Auto fallback behavior' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'windows-scripts\create-vm.ps1'), [ref]$tokens, [ref]$errors)
        foreach ($functionName in @('Expand-UserPath', 'Resolve-UserConfigPath', 'Resolve-DefaultDataRoot', 'Read-ColoredInput', 'Read-Default', 'Read-RequiredPath')) {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $script:SuggestionColor = 'Cyan'
    }

    It 'expands current-user environment tokens' {
        (Expand-UserPath '%USERPROFILE%\.ssh\id_ed25519.pub') | Should Be (Join-Path $env:USERPROFILE '.ssh\id_ed25519.pub')
        (Resolve-UserConfigPath) | Should Be (Join-Path $env:LOCALAPPDATA 'HyperVGoldenImage\New-GoldenVmInteractive.config.psd1')
        (Resolve-DefaultDataRoot) | Should Be (Join-Path $env:USERPROFILE 'HyperVGoldenImage-Data')
    }

    It 'prompts for a replacement when Auto receives an invalid path' {
        $validPath = Join-Path $TestDrive 'valid-path'
        New-Item -ItemType Directory -Path $validPath | Out-Null
        $script:AutoMode = $true
        $script:PromptAllowed = $true
        Mock Read-Host { $validPath }

        (Read-RequiredPath -Prompt 'Required path' -Default (Join-Path $TestDrive 'missing')) | Should Be $validPath
        Assert-MockCalled Read-Host -Times 1
    }
}

Describe 'Hyper-V preflight helpers' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'windows-scripts\Test-HyperVPreflight.ps1'), [ref]$tokens, [ref]$errors)
        foreach ($functionName in @('ConvertTo-IPv4NetworkPrefix', 'Test-IPv4InCidr')) {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }

    It 'calculates the expected NAT network prefix' {
        (ConvertTo-IPv4NetworkPrefix '192.168.200.25/24') | Should Be '192.168.200.0/24'
        (ConvertTo-IPv4NetworkPrefix '10.20.31.7/20') | Should Be '10.20.16.0/20'
    }

    It 'checks whether a gateway belongs to a NAT prefix' {
        (Test-IPv4InCidr -Address '192.168.200.1' -Cidr '192.168.200.0/24') | Should Be $true
        (Test-IPv4InCidr -Address '192.168.201.1' -Cidr '192.168.200.0/24') | Should Be $false
    }

    It 'requires explicit repair mode and ShouldProcess approval for changes' {
        $preflight = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\Test-HyperVPreflight.ps1')
        ($preflight -match 'SupportsShouldProcess\s*=\s*\$true') | Should Be $true
        ($preflight -match '\[switch\]\$Repair') | Should Be $true
        ($preflight -match '\$PSCmdlet\.ShouldProcess') | Should Be $true
        ($preflight -match 'New-VMSwitch') | Should Be $true
        ($preflight -match 'New-NetIPAddress') | Should Be $true
        ($preflight -match 'New-NetNat') | Should Be $true
        ($preflight -match 'DHCP mode does not define whether it should be external, internal, or private') | Should Be $true
    }

    It 'requires host NAT only for PrivateNat and not for Advanced static networking' {
        $wrapper = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\create-vm.ps1')
        ($wrapper -match '\$requireNatFinal = \$networkModeFinal -eq ''PrivateNat''') | Should Be $true
        ($wrapper -match 'RequireNat \$useStaticFinal') | Should Be $false
    }
}

Describe 'Secret and deletion safety contract' {
    $seedScript = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\New-NoCloudSeedDisk.ps1')
    $removeScript = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\Remove-HyperVVmSafe.ps1')

    It 'does not write the rescue password into the rescue summary' {
        ($seedScript -match 'Rescue password: \$RescuePassword"') | Should Be $false
        ($seedScript -match '<configured; not stored>') | Should Be $true
    }

    It 'quotes YAML values and validates authorized deletion roots' {
        ($seedScript -match 'ConvertTo-YamlSingleQuotedScalar') | Should Be $true
        ($removeScript -match 'Test-PathWithinRoot') | Should Be $true
        ($removeScript -match 'also attached to VM') | Should Be $true
        ($removeScript -match 'VM root leaf does not match the VM name') | Should Be $true
        ($removeScript -match 'Preserving non-empty authorized folder') | Should Be $true
        ($removeScript -match 'Remove-Item -LiteralPath \$candidate\.Path -Recurse') | Should Be $false
        ($removeScript -match '\[switch\]\$CleanupOrphans') | Should Be $true
        ($removeScript -match 'Unexpected files were found and will be preserved') | Should Be $true
    }

    It 'builds a replacement seed in staging and uses literal paths' {
        ($seedScript -match '\$stagingSeedPath') | Should Be $true
        ($seedScript -match '\[System\.IO\.File\]::Replace\(\$stagingSeedPath, \$SeedDiskPath') | Should Be $true
        ($seedScript -match 'SeedDiskPath points to a directory') | Should Be $true
        ($seedScript -match 'Remove-Item \$SeedDiskPath') | Should Be $false
    }
}

Describe 'User configuration uninstall contract' {
    $uninstallScript = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\uninstall.ps1')

    It 'is confirmation-aware and limited to the per-user application directory' {
        ($uninstallScript -match 'SupportsShouldProcess\s*=\s*\$true') | Should Be $true
        ($uninstallScript.Contains("Join-Path `$localBase 'HyperVGoldenImage'")) | Should Be $true
        ($uninstallScript.Contains("Split-Path -Leaf `$target) -ne 'HyperVGoldenImage'")) | Should Be $true
        ($uninstallScript -match 'Remove-Item -LiteralPath \$targetPath -Recurse -Force') | Should Be $true
        ($uninstallScript -match 'Remove-VM|Remove-VMSwitch|Remove-NetNat') | Should Be $false
        ($uninstallScript -match 'HyperVGoldenImage-Data.*not affected') | Should Be $true
    }
}

Describe 'Static IP reservation contract' {
    $wrapper = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\create-vm.ps1')
    $manager = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\ip-reservations.ps1')

    It 'checks before creation and saves only after seed or VM success' {
        ($wrapper -match 'Assert-IpAddressAvailable') | Should Be $true
        ($wrapper -match 'Save-IpAllocation') | Should Be $true
        ($wrapper -match "state\\ip-allocations\.json") | Should Be $true
        ($wrapper.IndexOf("& `$vmScript @vmParams")) | Should BeLessThan ($wrapper.LastIndexOf('Save-IpAllocation'))
    }

    It 'provides explicit list and release operations outside uninstall scope' {
        ($manager -match "ValidateSet\('List','Release'\)") | Should Be $true
        ($manager -match 'SupportsShouldProcess\s*=\s*\$true') | Should Be $true
        ($manager -match 'HyperVGoldenImage-Data') | Should Be $true
        ($manager -match 'Remove-VM|Remove-VMSwitch|Remove-NetNat') | Should Be $false
    }


    It 'serializes reservation changes across creator and manager processes' {
        ($wrapper -match 'HyperVGoldenImage-IpAllocations') | Should Be $true
        ($manager -match 'HyperVGoldenImage-IpAllocations') | Should Be $true
        ($wrapper -match 'WaitOne') | Should Be $true
        ($manager -match 'WaitOne') | Should Be $true
    }
}

Describe 'Guided network experience contract' {
    $wrapper = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\create-vm.ps1')

    It 'offers three intent-based modes and keeps basic modes concise' {
        ($wrapper -match 'Automatic network \(DHCP\) - recommended') | Should Be $true
        ($wrapper -match 'Private NAT with a fixed IP') | Should Be $true
        ($wrapper -match 'Advanced/custom networking') | Should Be $true
        ($wrapper -match "-Prompt 'VM IP address'") | Should Be $true
        ($wrapper.Contains("if (`$networkModeFinal -eq 'Advanced')")) | Should Be $true
        ($wrapper.Contains("-Prompt 'Cloud-init interface name'")) | Should Be $true
    }

    It 'persists the selected mode while retaining legacy UseStatic compatibility' {
        ($wrapper -match 'NetworkMode=\$networkModeFinal') | Should Be $true
        ($wrapper -match 'LegacyUseStatic \$UseStatic') | Should Be $true
        ($wrapper -match "ValidateSet\('','Dhcp','PrivateNat','Advanced'\)") | Should Be $true
    }
}

Describe 'DNS input normalization' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'windows-scripts\create-vm.ps1'), [ref]$tokens, [ref]$errors)
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertFrom-DnsInput' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    It 'supports zero, one, and multiple DNS values as arrays at the call site' {
        @(ConvertFrom-DnsInput -Value @()).Count | Should Be 0
        @(ConvertFrom-DnsInput -Value @('1.1.1.1')).Count | Should Be 1
        @(ConvertFrom-DnsInput -Value @('1.1.1.1, 8.8.8.8')).Count | Should Be 2
        $wrapper = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\create-vm.ps1')
        ([regex]::Matches($wrapper, '\$dnsServersFinal = @\(ConvertFrom-DnsInput')).Count | Should Be 4
    }
}

Describe 'SSH public key validation' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'windows-scripts\create-vm.ps1'), [ref]$tokens, [ref]$errors)
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-SshPublicKeyFile' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    It 'accepts OpenSSH public keys and rejects folders and private keys' {
        $publicKey = Join-Path $TestDrive 'id_ed25519.pub'
        $privateKey = Join-Path $TestDrive 'id_ed25519'
        Set-Content -LiteralPath $publicKey -Value 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyMaterial user@test'
        Set-Content -LiteralPath $privateKey -Value '-----BEGIN OPENSSH PRIVATE KEY-----'
        (Test-SshPublicKeyFile $publicKey) | Should Be $true
        (Test-SshPublicKeyFile $privateKey) | Should Be $false
        (Test-SshPublicKeyFile $TestDrive) | Should Be $false
        (Test-SshPublicKeyFile (Join-Path $TestDrive 'missing.pub')) | Should Be $false
    }

    It 'uses strict public-key validation for primary and rescue users' {
        $wrapper = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\create-vm.ps1')
        ([regex]::Matches($wrapper, 'Read-SshPublicKeyPath -Prompt')).Count | Should Be 2
        ($wrapper -match 'Test-Path -LiteralPath \$Path -PathType Leaf') | Should Be $true
    }
}

Describe 'SSH key preparation' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'windows-scripts\create-vm.ps1'), [ref]$tokens, [ref]$errors)
        foreach ($functionName in @('Expand-UserPath', 'Test-SshPublicKeyFile', 'New-SshKeyPair')) {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }

    It 'creates an Ed25519 key pair and refuses to overwrite it' {
        $publicPath = Join-Path (Join-Path $TestDrive 'ssh') 'hyperv-test.pub'
        $createdPath = New-SshKeyPair -PublicKeyPath $publicPath
        $createdPath | Should Not BeNullOrEmpty
        (Test-SshPublicKeyFile $createdPath) | Should Be $true
        $privatePath = $createdPath.Substring(0, $createdPath.Length - 4)
        (Test-Path -LiteralPath $privatePath -PathType Leaf) | Should Be $true
        $privateHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $privatePath).Hash

        $threw = $false
        try { New-SshKeyPair -PublicKeyPath $createdPath | Out-Null } catch { $threw = $true }
        $threw | Should Be $true
        (Get-FileHash -Algorithm SHA256 -LiteralPath $privatePath).Hash | Should Be $privateHash
    }

    It 'refuses generation when only the private-key destination already exists' {
        $publicPath = Join-Path $TestDrive 'existing-private.pub'
        $normalizedPublicPath = [System.IO.Path]::GetFullPath((Expand-UserPath $publicPath))
        $privatePath = $normalizedPublicPath.Substring(0, $normalizedPublicPath.Length - 4)
        Set-Content -LiteralPath $privatePath -Value 'do-not-overwrite'
        $threw = $false
        try { New-SshKeyPair -PublicKeyPath $normalizedPublicPath | Out-Null } catch { $threw = $true }
        $threw | Should Be $true
        (Get-Content -LiteralPath $privatePath -Raw).Trim() | Should Be 'do-not-overwrite'
        (Test-Path -LiteralPath $normalizedPublicPath) | Should Be $false
    }
}

Describe 'Static network YAML packaging' {
    It 'does not wrap already quoted YAML scalar placeholders in another pair of quotes' {
        $template = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'cloud-init\network-config.static.template.yaml')
        ($template -match '"__IP_CIDR__"') | Should Be $false
        ($template -match '"__GATEWAY__"') | Should Be $false
        ($template -match '(?m)^\s*- __IP_CIDR__$') | Should Be $true
        ($template -match '(?m)^\s*via: __GATEWAY__$') | Should Be $true
    }

    It 'renders address and gateway as single YAML-quoted scalar values' {
        $template = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'cloud-init\network-config.static.template.yaml')
        $rendered = $template.Replace('__IP_CIDR__', "'192.168.200.10/24'").Replace('__GATEWAY__', "'192.168.200.1'")
        ($rendered -match '"''192\.168\.200\.10/24''"') | Should Be $false
        ($rendered -match "(?m)^\s*- '192\.168\.200\.10/24'$") | Should Be $true
        ($rendered -match "(?m)^\s*via: '192\.168\.200\.1'$") | Should Be $true
    }
}

Describe 'Colored terminal response contract' {
    $wrapper = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\create-vm.ps1')

    It 'renders suggested defaults and computed engine values with distinct colors' {
        ($wrapper -match 'function Read-ColoredInput') | Should Be $true
        ($wrapper -match "SuggestionColor = 'Cyan'") | Should Be $true
        ($wrapper -match "EngineValueColor = 'DarkCyan'") | Should Be $true
        ($wrapper -match 'ForegroundColor \$script:SuggestionColor') | Should Be $true
        ($wrapper -match 'function Write-EngineValue') | Should Be $true
    }
}

Describe 'Rollback contract' {
    It 'tracks and removes only resources created by the current VM creation run' {
        $creator = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\New-HyperVVmFromGolden.ps1')
        ($creator -match '\$createdVmPath = \$false') | Should Be $true
        ($creator -match '\$createdVm = \$false') | Should Be $true
        ($creator -match 'rolling back resources created by this run') | Should Be $true
        ($creator -match '\$vmStillRegistered') | Should Be $true
    }


    It 'wraps seed migration file moves and attachment update in one rollback block' {
        $migrator = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\Migrate-SeedDisksToVmFolders.ps1')
        ($migrator -match 'Target rescue note already exists') | Should Be $true
        ($migrator -match 'Rolling back every file moved by this item') | Should Be $true
    }
}

Describe 'Golden image preparation cleanup contract' {
    It 'records the preparation backup and only removes the expected internal backup during sealing' {
        $prepare = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts\prepare-current-image-for-golden.sh')
        $seal = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts\seal-golden-image.sh')
        ($prepare -match 'PREP_BACKUP_RECORD') | Should Be $true
        ($seal -match '/var/backups/golden-image-prep-\*') | Should Be $true
        ($seal -match 'Refusing to remove unexpected preparation backup') | Should Be $true
    }
}

Describe 'Repository hygiene contract' {
    It 'ignores local VM images and host-specific scratch configuration' {
        $ignore = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.gitignore')
        ($ignore -match '(?m)^Golden/$') | Should Be $true
        ($ignore -match '(?m)^\*\.vhdx$') | Should Be $true
        ($ignore -match '(?m)^config1\.psd1$') | Should Be $true
    }
}

Describe 'Configuration examples contract' {
    $examplesRoot = Join-Path $repoRoot 'config-examples'

    It 'provides valid examples for DHCP, Private NAT, Advanced static, and Seed-only modes' {
        $expected = @{
            'New-GoldenVmInteractive.config.dhcp.example.psd1' = 'Dhcp'
            'New-GoldenVmInteractive.config.static.example.psd1' = 'PrivateNat'
            'New-GoldenVmInteractive.config.advanced-static.example.psd1' = 'Advanced'
            'New-GoldenVmInteractive.config.seed-only.example.psd1' = 'Dhcp'
        }
        foreach ($name in $expected.Keys) {
            $path = Join-Path $examplesRoot $name
            (Test-Path -LiteralPath $path -PathType Leaf) | Should Be $true
            $config = Import-PowerShellDataFile -LiteralPath $path
            $config.NetworkMode | Should Be $expected[$name]
            [string]::IsNullOrEmpty([string]$config.Password) | Should Be $true
        }
        (Import-PowerShellDataFile -LiteralPath (Join-Path $examplesRoot 'New-GoldenVmInteractive.config.seed-only.example.psd1')).SeedOnly | Should Be $true
    }

    It 'uses a complete non-overlapping ready Private NAT example' {
        $config = Import-PowerShellDataFile -LiteralPath (Join-Path $examplesRoot 'New-GoldenVmInteractive.config.static.example.psd1')
        $config.SwitchName | Should Be 'HyperV-NAT'
        $config.StaticIpCidr | Should Be '172.29.240.10/24'
        $config.Gateway | Should Be '172.29.240.1'
        @($config.DnsServers).Count | Should BeGreaterThan 0
        $config.InterfaceName | Should Be 'lan0'
    }
}

Describe 'Hyper-V disk access contract' {
    $creator = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\New-HyperVVmFromGolden.ps1')
    $repair = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows-scripts\repair-vm-disk-access.ps1')

    It 'grants the specific VM identity access after attaching the seed and before start' {
        ($creator -match 'NT VIRTUAL MACHINE\\\$\(\$vm\.VMId\)') | Should Be $true
        ($creator -match 'icacls\.exe') | Should Be $true
        $creator.IndexOf('Add-VMHardDiskDrive') | Should BeLessThan $creator.LastIndexOf('Grant-VmDiskAccess')
        $creator.LastIndexOf('Grant-VmDiskAccess') | Should BeLessThan $creator.IndexOf('Start-VM -Name $VmName')
    }

    It 'provides a confirmation-aware repair limited to attached disks' {
        ($repair -match 'SupportsShouldProcess\s*=\s*\$true') | Should Be $true
        ($repair -match 'Get-VMHardDiskDrive') | Should Be $true
        ($repair -match 'not attached to VM') | Should Be $true
        ($repair -match 'NT VIRTUAL MACHINE') | Should Be $true
    }
}

Describe 'Hyper-V behavior with mocked commands' {
    BeforeAll {
        foreach ($name in @('Get-VM','Get-VMHardDiskDrive','Get-VMDvdDrive','Stop-VM','Remove-VM','Get-VMSwitch','New-VM','Set-VMProcessor','Set-VMMemory','Set-VMFirmware','Set-VMNetworkAdapter','Add-VMHardDiskDrive','Start-VM')) {
            if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
                Set-Item -Path "function:global:$name" -Value { }
            }
        }
    }

    It 'refuses deletion when a disk is shared with another VM' {
        $vmPath = Join-Path $TestDrive 'vm-one'
        $diskPath = Join-Path $vmPath 'shared.vhdx'
        Mock Get-VM {
            if ($PSBoundParameters.ContainsKey('Name')) { return [pscustomobject]@{ Name='vm-one'; State='Off'; Path=$vmPath; ConfigurationLocation=$vmPath; SnapshotFileLocation=$vmPath; SmartPagingFilePath=$vmPath } }
            return @([pscustomobject]@{ Name='vm-one' }, [pscustomobject]@{ Name='vm-two' })
        }
        Mock Get-VMHardDiskDrive {
            if ($VMName -eq 'vm-two') { return [pscustomobject]@{ VMName='vm-two'; Path=$diskPath } }
            return [pscustomobject]@{ VMName='vm-one'; Path=$diskPath }
        }
        Mock Get-VMDvdDrive { @() }
        Mock Remove-VM { }

        $threw = $false
        try { & (Join-Path $repoRoot 'windows-scripts\Remove-HyperVVmSafe.ps1') -VmName 'vm-one' -Action Delete } catch { $threw = $true }
        $threw | Should Be $true
        Assert-MockCalled Remove-VM -Times 0
    }

    It 'refuses deletion when Hyper-V reports a broadly named VM root' {
        $vmPath = Join-Path $TestDrive 'shared-root'
        New-Item -ItemType Directory -Path $vmPath | Out-Null
        Mock Get-VM { [pscustomobject]@{ Name='vm-one'; State='Off'; Path=$vmPath } }
        Mock Remove-VM { }

        $threw = $false
        try { & (Join-Path $repoRoot 'windows-scripts\Remove-HyperVVmSafe.ps1') -VmName 'vm-one' -Action Delete } catch { $threw = $true }
        $threw | Should Be $true
        Assert-MockCalled Remove-VM -Times 0
        (Test-Path -LiteralPath $vmPath) | Should Be $true
    }

    It 'preserves an authorized VM folder when unknown files remain' {
        $vmPath = Join-Path $TestDrive 'vm-one'
        New-Item -ItemType Directory -Path $vmPath | Out-Null
        Set-Content -LiteralPath (Join-Path $vmPath 'keep.txt') -Value 'unknown file'
        Mock Get-VM { [pscustomobject]@{ Name='vm-one'; State='Off'; Path=$vmPath; ConfigurationLocation=$vmPath; SnapshotFileLocation=$vmPath; SmartPagingFilePath=$vmPath } }
        Mock Get-VMHardDiskDrive { @() }
        Mock Get-VMDvdDrive { @() }
        Mock Remove-VM { }

        & (Join-Path $repoRoot 'windows-scripts\Remove-HyperVVmSafe.ps1') -VmName 'vm-one' -Action Delete
        Assert-MockCalled Remove-VM -Times 1
        (Test-Path -LiteralPath $vmPath) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $vmPath 'keep.txt')) | Should Be $true
    }

    It 'cleans a standard rescue sidecar and empty folders after VM registration is gone' {
        $vmRoot = Join-Path (Join-Path $TestDrive 'vms') 'vm-one'
        $seedRoot = Join-Path (Join-Path $TestDrive 'seeds') 'vm-one'
        New-Item -ItemType Directory -Path (Join-Path $vmRoot 'vm-one\Snapshots') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $vmRoot 'vm-one\Virtual Machines') -Force | Out-Null
        New-Item -ItemType Directory -Path $seedRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $seedRoot 'vm-one-seed.vhdx.rescue.txt') -Value 'summary'
        Mock Get-VM { $null }

        & (Join-Path $repoRoot 'windows-scripts\Remove-HyperVVmSafe.ps1') -VmName 'vm-one' -CleanupOrphans -AllowedRoot @($vmRoot, $seedRoot) -Action Delete

        (Test-Path -LiteralPath $vmRoot) | Should Be $false
        (Test-Path -LiteralPath $seedRoot) | Should Be $false
    }

    It 'rolls back a newly created VM after a configuration failure' {
        $golden = Join-Path $TestDrive 'golden.vhdx'
        $seed = Join-Path $TestDrive 'seed.vhdx'
        $vmRoot = Join-Path $TestDrive 'vms'
        New-Item -ItemType Directory -Path $vmRoot -Force | Out-Null
        Set-Content -LiteralPath $golden -Value 'golden'
        Set-Content -LiteralPath $seed -Value 'seed'
        $script:vmWasCreated = $false

        Mock Get-VMSwitch { [pscustomobject]@{ Name='test-switch' } }
        Mock Get-VM { if ($script:vmWasCreated) { [pscustomobject]@{ Name='vm-test' } } }
        Mock New-VM { $script:vmWasCreated = $true }
        Mock Set-VMProcessor { throw 'simulated failure' }
        Mock Stop-VM { }
        Mock Remove-VM { $script:vmWasCreated = $false }

        $threw = $false
        try { & (Join-Path $repoRoot 'windows-scripts\New-HyperVVmFromGolden.ps1') -VmName 'vm-test' -GoldenVhdxPath $golden -VmRoot $vmRoot -SwitchName 'test-switch' -SeedDiskPath $seed -StaticMacAddress '00-15-5D-32-10-01' } catch { $threw = $true }
        $threw | Should Be $true
        Assert-MockCalled Remove-VM -Times 1
        (Test-Path -LiteralPath (Join-Path $vmRoot 'vm-test')) | Should Be $false
    }

    It 'rolls back a VM that was registered before New-VM reported failure' {
        $golden = Join-Path $TestDrive 'golden-partial.vhdx'
        $seed = Join-Path $TestDrive 'seed-partial.vhdx'
        $vmRoot = Join-Path $TestDrive 'vms-partial'
        $vmPath = Join-Path $vmRoot 'vm-partial'
        New-Item -ItemType Directory -Path $vmRoot -Force | Out-Null
        Set-Content -LiteralPath $golden -Value 'golden'
        Set-Content -LiteralPath $seed -Value 'seed'
        $script:vmWasCreated = $false

        Mock Get-VMSwitch { [pscustomobject]@{ Name='test-switch' } }
        Mock Get-VM {
            if ($script:vmWasCreated) {
                return [pscustomobject]@{ Name='vm-partial'; State='Off'; Path=$vmPath }
            }
        }
        Mock New-VM {
            $script:vmWasCreated = $true
            throw 'simulated failure after registration'
        }
        Mock Stop-VM { }
        Mock Remove-VM { $script:vmWasCreated = $false }

        $threw = $false
        try { & (Join-Path $repoRoot 'windows-scripts\New-HyperVVmFromGolden.ps1') -VmName 'vm-partial' -GoldenVhdxPath $golden -VmRoot $vmRoot -SwitchName 'test-switch' -SeedDiskPath $seed -StaticMacAddress '00-15-5D-32-10-04' } catch { $threw = $true }
        $threw | Should Be $true
        Assert-MockCalled Remove-VM -Times 1
        (Test-Path -LiteralPath $vmPath) | Should Be $false
    }

    It 'preserves VM files when rollback cannot unregister the VM' {
        $golden = Join-Path $TestDrive 'golden-preserve.vhdx'
        $seed = Join-Path $TestDrive 'seed-preserve.vhdx'
        $vmRoot = Join-Path $TestDrive 'vms-preserve'
        New-Item -ItemType Directory -Path $vmRoot -Force | Out-Null
        Set-Content -LiteralPath $golden -Value 'golden'
        Set-Content -LiteralPath $seed -Value 'seed'
        $script:vmWasCreated = $false

        Mock Get-VMSwitch { [pscustomobject]@{ Name='test-switch' } }
        Mock Get-VM { if ($script:vmWasCreated) { [pscustomobject]@{ Name='vm-preserve' } } }
        Mock New-VM { $script:vmWasCreated = $true }
        Mock Set-VMProcessor { throw 'simulated configuration failure' }
        Mock Stop-VM { }
        Mock Remove-VM { throw 'simulated unregister failure' }

        $threw = $false
        try { & (Join-Path $repoRoot 'windows-scripts\New-HyperVVmFromGolden.ps1') -VmName 'vm-preserve' -GoldenVhdxPath $golden -VmRoot $vmRoot -SwitchName 'test-switch' -SeedDiskPath $seed -StaticMacAddress '00-15-5D-32-10-02' } catch { $threw = $true }
        $threw | Should Be $true
        (Test-Path -LiteralPath (Join-Path $vmRoot 'vm-preserve')) | Should Be $true
    }

    It 'rejects a VM name that would escape VmRoot' {
        $golden = Join-Path $TestDrive 'golden-name.vhdx'
        $seed = Join-Path $TestDrive 'seed-name.vhdx'
        $vmRoot = Join-Path $TestDrive 'vms-name'
        New-Item -ItemType Directory -Path $vmRoot -Force | Out-Null
        Set-Content -LiteralPath $golden -Value 'golden'
        Set-Content -LiteralPath $seed -Value 'seed'
        Mock Get-VMSwitch { [pscustomobject]@{ Name='test-switch' } }

        $threw = $false
        try { & (Join-Path $repoRoot 'windows-scripts\New-HyperVVmFromGolden.ps1') -VmName '..\escaped' -GoldenVhdxPath $golden -VmRoot $vmRoot -SwitchName 'test-switch' -SeedDiskPath $seed -StaticMacAddress '00-15-5D-32-10-03' } catch { $threw = $true }
        $threw | Should Be $true
        (Test-Path -LiteralPath (Join-Path $TestDrive 'escaped')) | Should Be $false
    }
}
