# Auto Config Guide

The purpose of `-Auto` mode is to let the script read values from a fixed configuration file, while still allowing you to override one or two values from the command line when needed.

## Priority Order

```text
CLI parameters
  Highest priority

New-GoldenVmInteractive.config.psd1
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
.\New-GoldenVmInteractive.ps1 -Auto -DeviceName 'vm-prod-02' -IpOctet 26
```

The script will use `vm-prod-02` and `26` instead of the values from the config file.

## First Run

```powershell
Copy-Item .\New-GoldenVmInteractive.config.example.psd1 .\New-GoldenVmInteractive.config.psd1
notepad .\New-GoldenVmInteractive.config.psd1
```

Fill in the required base values:

```powershell
DeviceName = 'vm-prod-01'
Hostname = 'vm-prod-01'
SshPublicKeyPath = 'C:\Users\YourUser\.ssh\id_ed25519.pub'
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

Then run:

```powershell
.\New-GoldenVmInteractive.ps1 -Auto
```

## DHCP Example

Use DHCP if the Hyper-V switch or the connected network provides IP addresses automatically.

```powershell
UseStatic = $false
StaticIpCidr = ''
IpPrefix = ''
IpOctet = 0
Gateway = ''
DnsServers = @()
```

Run:

```powershell
.\New-GoldenVmInteractive.ps1 -Auto
```

## Static IP Example

Use Static IP when you want each VM to have a fixed IP address.

```powershell
UseStatic = $true
StaticIpCidr = ''
IpPrefix = '192.168.201'
IpOctet = 25
Gateway = '192.168.201.1'
DnsServers = @('1.1.1.1', '8.8.8.8')
```

The resulting IP address will be:

```text
192.168.201.25/24
```

To create another VM with the same settings but a different last IP octet:

```powershell
.\New-GoldenVmInteractive.ps1 -Auto -DeviceName 'vm-prod-02' -Hostname 'vm-prod-02' -IpOctet 26
```

## StaticIpCidr Instead of IpPrefix/IpOctet

You can provide the full IP address directly:

```powershell
UseStatic = $true
StaticIpCidr = '192.168.201.25/24'
IpPrefix = ''
IpOctet = 0
Gateway = '192.168.201.1'
DnsServers = @('1.1.1.1', '8.8.8.8')
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
Password = 'Temp-Rescue-Password'
EnableRescueSshPassword = $true
SetRescuePassword = $true
```

To set a password for Hyper-V console access only, while keeping SSH password login disabled:

```powershell
Password = 'Console-Only-Password'
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
Test-Path 'C:\Users\YourUser\.ssh\id_ed25519.pub'
```
