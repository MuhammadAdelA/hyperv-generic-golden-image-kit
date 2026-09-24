# Auto Config Guide

The purpose of `-Auto` mode is to let the script read values from a fixed configuration file, while still allowing you to override one or two values from the command line when needed.

## Priority Order

```text
CLI parameters
  Highest priority

%LOCALAPPDATA%\HyperVGoldenImage\New-GoldenVmInteractive.config.psd1
  Your machine and environment settings

Built-in defaults
  Safe generic defaults such as CPU/RAM/DHCP
```

Example: if the config file contains:

```powershell
DeviceName = 'vm-prod-01'
IpOctet = 25
```

Then you run:

```powershell
.\windows-scripts\create-vm.ps1 -Auto -DeviceName 'vm-prod-02' -IpOctet 26
```

The script will use `vm-prod-02` and `26` instead of the values from the config file.

## First Run (no config or example required)

```powershell
.\windows-scripts\create-vm.ps1
```

To prepare the configuration and SSH key without creating a VM or changing Hyper-V, run:

```powershell
.\windows-scripts\create-vm.ps1 -ConfigureOnly
```

You can select an existing OpenSSH public key. If the chosen `.pub` path does not exist, the wizard can generate a new Ed25519 key pair without a passphrase and will refuse to overwrite either half of an existing pair. Use `-ConfigOutputPath` for a custom output file and `-GenerateSshKey` for explicit non-interactive key generation.

This is the only user entry point. It detects the project and host, gathers missing values, runs preflight, offers safe Hyper-V/NAT repairs for explicit approval, and saves the validated user settings under `%LOCALAPPDATA%\HyperVGoldenImage` only after creation succeeds. It does not copy or depend on an example file.

For a read-only import from a migrated legacy configuration root:

```powershell
.\windows-scripts\create-vm.ps1 -ImportConfigPath 'E:\Backup_D\HyperV'
```

The importer discovers the migrated `New-GoldenVmInteractive.config.psd1`, normalizes storage to `VMs` and `Seeds`, and reports any folders left under the historical typo paths `VMss` and `Seedss`. It never moves or registers those existing VMs and never writes to the import root.

If storage paths are not supplied, it creates and uses `%USERPROFILE%\HyperVGoldenImage-Data\VMs` and `%USERPROFILE%\HyperVGoldenImage-Data\Seeds`. The uninstall command removes only the LocalAppData configuration and never deletes this persistent data directory.

Successful static-IP creations are recorded in `%USERPROFILE%\HyperVGoldenImage-Data\state\ip-allocations.json`. Reusing an address for another VM is rejected. List or release stale entries with `windows-scripts\ip-reservations.ps1`; uninstall intentionally preserves this registry.

The first-run wizard gathers values equivalent to:

```powershell
DeviceName = 'vm-prod-01'
Hostname = 'vm-prod-01'
SshPublicKeyPath = '%USERPROFILE%\.ssh\id_ed25519.pub'
GoldenVhdxPath = 'D:\HyperV\Golden\ubuntu-24.04-golden-base.vhdx'
VmRoot = 'D:\HyperV\VMs'
SeedRoot = 'D:\HyperV\Seeds'
SwitchName = 'PanelNAT'
```

With the default `SeedDiskPath = ''`, seed files are stored in a per-VM folder:

```text
D:\HyperV\Seeds\vm-prod-01\vm-prod-01-seed.vhdx
D:\HyperV\Seeds\vm-prod-01\vm-prod-01-seed.vhdx.rescue.txt
```

The rescue summary records whether a password was configured, but never stores the password itself. A generated password is displayed once in the terminal.

Then run:

```powershell
.\windows-scripts\create-vm.ps1 -Auto
```

Auto mode prompts only when a value is missing or invalid, and still asks before host repair. Use `-Auto -NoPrompt` for unattended jobs: it never prompts or repairs and fails before creation if input or preflight is incomplete. Config discovery checks an explicit `-ConfigPath`, then the current-user location above.

## Included Examples

The `config-examples` directory contains independently usable examples:

```text
New-GoldenVmInteractive.config.dhcp.example.psd1
New-GoldenVmInteractive.config.static.example.psd1
New-GoldenVmInteractive.config.advanced-static.example.psd1
New-GoldenVmInteractive.config.seed-only.example.psd1
New-GoldenVmInteractive.config.example.psd1
```

The static example is a ready Private NAT definition using `172.29.240.0/24`. The Advanced example assumes its switch and upstream network already exist. Copy an example to a non-repository path and pass it through `-ConfigPath`, or use `-ConfigureOnly -ConfigOutputPath` to generate a validated personal file.

## DHCP Example

Use DHCP if the Hyper-V switch or the connected network provides IP addresses automatically.

```powershell
NetworkMode = 'Dhcp'
UseStatic = $false
StaticIpCidr = ''
IpPrefix = ''
IpOctet = 0
Gateway = ''
DnsServers = @()
```

Run:

```powershell
.\windows-scripts\create-vm.ps1 -Auto
```

## Static IP Example

Use Private NAT when you want a fixed VM address that does not change with the host Wi-Fi subnet. The ready example can create the Internal switch, host gateway, and NetNat after explicit approval.

```powershell
NetworkMode = 'PrivateNat'
UseStatic = $true
StaticIpCidr = '172.29.240.10/24'
IpPrefix = ''
IpOctet = 0
Gateway = '172.29.240.1'
DnsServers = @('1.1.1.1', '8.8.8.8')
SwitchName = 'HyperV-NAT'
```

The resulting IP address will be:

```text
172.29.240.10/24
```

To create another VM with the same settings but a different last IP octet:

```powershell
.\windows-scripts\create-vm.ps1 -Auto -DeviceName 'vm-prod-02' -Hostname 'vm-prod-02' -StaticIpCidr '172.29.240.11/24'
```

## StaticIpCidr Instead of IpPrefix/IpOctet

You can provide the full IP address directly:

```powershell
NetworkMode = 'Advanced'
UseStatic = $true
StaticIpCidr = '192.168.50.25/24'
IpPrefix = ''
IpOctet = 0
Gateway = '192.168.50.1'
DnsServers = @('1.1.1.1', '8.8.8.8')
SwitchName = 'External-LAN'
```

In this case, the script ignores `IpPrefix` and `IpOctet`.

## SSH and Rescue Access

Recommended production setting:

```powershell
Password = ''
EnableRescueSshPassword = $false
SetRescuePassword = $false
```

This means:

- SSH access uses keys only.
- SSH password login is not enabled.
- The rescue password is not set unless you explicitly request it.

To enable emergency rescue access through SSH password login:

```powershell
Password = '' # Generated and displayed once when left blank
EnableRescueSshPassword = $true
SetRescuePassword = $true
```

To set a password for Hyper-V console access only, while keeping SSH password login disabled:

```powershell
Password = '' # Generated and displayed once when left blank
EnableRescueSshPassword = $false
SetRescuePassword = $true
```

## Helpful Commands

Show available Hyper-V switch names:

```powershell
Get-VMSwitch | Select-Object Name, SwitchType
```

Verify that the golden VHDX exists:

```powershell
Test-Path 'D:\HyperV\Golden\ubuntu-24.04-golden-base.vhdx'
```

Verify that the SSH public key exists:

```powershell
Test-Path "$env:USERPROFILE\.ssh\id_ed25519.pub"
```
