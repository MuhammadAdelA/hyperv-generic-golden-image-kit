# Hyper-V Golden Image Kit

> Create reproducible, development-ready Ubuntu VMs on Hyper-V with minimal overhead. Automate VM provisioning from a lightweight golden image using cloud-init.

## Overview

This project provides a streamlined toolkit for developers and DevOps engineers to:

- **Create a clean, reusable golden image** of Ubuntu that remains generic and minimal
- **Provision multiple VMs quickly** from the golden image with unique configurations
- **Automate network and system configuration** via cloud-init NoCloud provider
- **Maintain consistency** across development environments without repetition

The golden image stays clean and generic. Each VM clone gets its own identity injected via cloud-init, and project-specific bootstrapping happens after the VM boots.

## Key Features

✅ **Lightweight & Modular** — Stripped down to essentials only  
✅ **Cloud-Init Ready** — NoCloud provider for zero-cloud infrastructure  
✅ **Network Flexible** — Support for both DHCP and static IP configuration  
✅ **MAC-Based Matching** — Reliable network interface assignment  
✅ **PowerShell Automation** — Native Windows/Hyper-V integration  
✅ **SSH-Ready** — Key-based authentication out of the box

## Prerequisites

### Windows Host (Hyper-V)
- Windows Server 2016+ or Windows 10/11 Pro with Hyper-V enabled
- PowerShell 5.1 or higher
- Hyper-V role installed and configured

### Ubuntu Source Image
- Ubuntu Server 20.04 LTS or later (minimal installation recommended)
- SSH server installed and running
- SSH public key configured for passwordless access

## Project Structure

```
├── New-GoldenVmInteractive.ps1        # Config-aware wrapper for seed + VM creation
├── New-GoldenVmInteractive.config.example.psd1  # Fully commented config template
├── New-GoldenVmInteractive.config.dhcp.example.psd1    # DHCP example config
├── New-GoldenVmInteractive.config.static.example.psd1  # Static IP example config
├── AUTO-CONFIG.md                      # Auto/config usage guide
├── Migrate-SeedDisksToVmFolders.ps1    # Move legacy seed disks into per-VM folders
├── Remove-HyperVVmSafe.ps1             # Preview/delete a VM and its owned files safely
├── scripts/                           # Linux-side preparation scripts
│   ├── prepare-current-image-for-golden.sh  # Initial system setup
│   └── seal-golden-image.sh                 # Finalize and clean image
├── cloud-init/                        # Cloud-init templates
│   ├── meta-data.template.yaml        # Instance metadata
│   ├── user-data.template.yaml        # User script template
│   ├── network-config.dhcp.yaml       # DHCP network config
│   └── network-config.static.template.yaml  # Static IP template
└── windows/                           # PowerShell automation
    ├── New-NoCloudSeedDisk.ps1        # Create cloud-init seed disk
    └── New-HyperVVmFromGolden.ps1     # Create VM from golden image
```

## Quick Start

> For config-based automation, start with `AUTO-CONFIG.md`. The main config template is fully commented, and separate DHCP/Static examples are included.


## Production Automation Example

The wrapper supports a config-first automation model:

1. Copy the example config:

```powershell
Copy-Item .\New-GoldenVmInteractive.config.example.psd1 .\New-GoldenVmInteractive.config.psd1
```

2. Edit `New-GoldenVmInteractive.config.psd1` and fill your host-specific values:

- `GoldenVhdxPath`
- `VmRoot`
- `SeedRoot`
- `SwitchName`

> Seed layout: when `SeedDiskPath` is empty, the wrapper stores each seed disk under a per-VM folder:
> `<SeedRoot>\<DeviceName>\<DeviceName>-seed.vhdx`.
> Use `SeedDiskPath` only when you want a full custom seed disk path.

- `SshPublicKeyPath`
- networking values if `UseStatic = $true`

3. Run bare automation:

```powershell
.\New-GoldenVmInteractive.ps1 -Auto
```

CLI parameters override config values. For example, reuse the same config but create another VM:

```powershell
.\New-GoldenVmInteractive.ps1 -Auto -DeviceName "vm-prod-02" -Hostname "vm-prod-02"
```

For static networking, override only the last octet:

```powershell
.\New-GoldenVmInteractive.ps1 -Auto -DeviceName "vm-prod-02" -Hostname "vm-prod-02" -IpOctet 26
```

You can also use a different config file:

```powershell
.\New-GoldenVmInteractive.ps1 -Auto -ConfigPath "<absolute-path-to-config.psd1>"
```

A full no-config command is still supported, but it is intentionally verbose because every host-specific value must be explicit:

```powershell
.\New-GoldenVmInteractive.ps1 -Auto `
  -DeviceName "vm-prod-01" `
  -Hostname "vm-prod-01" `
  -AdminUser "ubuntu" `
  -SshPublicKeyPath "$env:USERPROFILE\.ssh\id_ed25519.pub" `
  -GoldenVhdxPath "<absolute-path-to-golden-vhdx>" `
  -VmRoot "<absolute-folder-for-vms>" `
  -SeedRoot "<absolute-folder-for-seed-disks>" `
  -SwitchName "<hyper-v-switch-name>" `
  -UseStatic $false `
  -EnableRescueSshPassword $false
```

For static IP automation, set these in the config or pass them as overrides:

```powershell
-UseStatic $true `
-IpPrefix "<network-prefix>" `
-IpOctet 25 `
-Gateway "<gateway-ip>" `
-DnsServers "1.1.1.1","8.8.8.8"
```

### Step 1: Prepare the Golden Image (on Ubuntu)

```bash
sudo bash scripts/prepare-current-image-for-golden.sh
```

Test that everything works as expected, then seal the image:

```bash
sudo bash scripts/seal-golden-image.sh
```

Shut down the VM when complete. Take a snapshot of this VM as your golden image.

### Step 2: Create NoCloud Seed Disk (on Windows)

For most users, the wrapper is preferred:

```powershell
.\New-GoldenVmInteractive.ps1 -Auto -SeedOnly $true
```

Direct seed-disk creation is also available:

```powershell
.\windows\New-NoCloudSeedDisk.ps1 `
  -SeedDiskPath "<absolute-path-to-seed-disk.vhdx>" `
  -Hostname "dev-vm-01" `
  -AdminUser "ubuntu" `
  -SshPublicKeyPath "C:\Users\YourUser\.ssh\id_ed25519.pub" `
  -InterfaceMacAddress "00-15-5D-32-10-01"
```

### Step 3: Create New VM (on Windows)

For most users, the wrapper is preferred:

```powershell
.\New-GoldenVmInteractive.ps1 -Auto
```

Direct VM creation is also available:

```powershell
.\windows\New-HyperVVmFromGolden.ps1 `
  -VmName "dev-vm-01" `
  -GoldenVhdxPath "<absolute-path-to-golden-image.vhdx>" `
  -VmRoot "<absolute-folder-for-vms>" `
  -SwitchName "<hyper-v-switch-name>" `
  -SeedDiskPath "<absolute-path-to-seed-disk.vhdx>" `
  -StaticMacAddress "00-15-5D-32-10-01"
```

**Important:** Use the same MAC address for both seed disk and VM creation.

### Step 4: Boot and Access

Start the VM and wait for cloud-init to complete (check VM console). Then SSH in:

```bash
ssh -i ~/.ssh/your-key user@<vm-ip>
```

### Step 5: Project Bootstrap

Once connected, run your project-specific bootstrap scripts:

```bash
./setup-dev-environment.sh
```

## Maintenance Utilities

The repository includes optional maintenance scripts for day-to-day Hyper-V cleanup and migration tasks. Run them from an elevated PowerShell session when they need to read or modify Hyper-V settings.

### Migrate legacy seed disks to per-VM folders

Use `Migrate-SeedDisksToVmFolders.ps1` after switching to the newer seed layout where each VM has its own seed folder:

```text
<SeedRoot>\<VMName>\<VMName>-seed.vhdx
```

The script looks for old root-level seed disks such as:

```text
D:\HyperV\Seeds\web-server-seed.vhdx
```

and plans to move them to:

```text
D:\HyperV\Seeds\web-server\web-server-seed.vhdx
```

It also moves the matching `.rescue.txt` file when present and updates the existing Hyper-V VM disk attachment to the new seed path.

Preview first:

```powershell
.\Migrate-SeedDisksToVmFolders.ps1 -SeedRoot "D:\HyperV\Seeds"
```

Apply the migration only after reviewing the plan:

```powershell
.\Migrate-SeedDisksToVmFolders.ps1 -SeedRoot "D:\HyperV\Seeds" -Apply
```

Recommended checks after migration:

```powershell
Get-VMHardDiskDrive |
  Where-Object { $_.Path -like "D:\HyperV\Seeds\*" } |
  Select-Object VMName, Path |
  Format-Table -AutoSize

Get-ChildItem "D:\HyperV\Seeds" -File -Filter "*-seed.vhdx"
```

Notes:

- The script is dry-run by default.
- By default, attached VMs must be `Off` before their seed disk path is changed.
- If related `.avhdx` files are found, the item is skipped so checkpoints or differencing disk chains are not moved unsafely.

### Safely remove a Hyper-V VM and owned files

Use `Remove-HyperVVmSafe.ps1` when you want to inspect and optionally delete a VM plus its directly owned VHD/VHDX and Hyper-V metadata folders.

Preview first:

```powershell
.\Remove-HyperVVmSafe.ps1 -VmName "vm-prod-01"
```

Delete only after reviewing the preview output:

```powershell
.\Remove-HyperVVmSafe.ps1 -VmName "vm-prod-01" -Action Delete
```

Safety behavior:

- Preview is the default action.
- The script shows hard disks that will be deleted before deletion.
- DVD/ISO paths are displayed only and are not deleted directly.
- Virtual switches, NAT networks, and `VM-NAT` are not deleted.
- The VM parent folder is deleted only if it becomes empty and its folder name matches the VM name.

## Configuration

### Network Configuration

The toolkit supports both DHCP and static IP assignment.

**DHCP (Default)**
```bash
# Uses cloud-init/network-config.dhcp.yaml
# Automatic IP assignment from your network
```

**Static IP**
Edit `cloud-init/network-config.static.template.yaml` and customize:
- IP address
- Gateway
- DNS servers
- Interface name (if needed)

### Cloud-Init Customization

Edit `cloud-init/user-data.template.yaml` to add:
- Additional packages
- System configuration
- User creation and permissions
- Custom initialization scripts

### SSH Key Configuration

1. Generate a keypair if needed:
   ```bash
   ssh-keygen -t rsa -b 4096 -f ~/.ssh/dev-vm-key
   ```

2. Set the public key path when creating the seed disk (edit the PowerShell scripts or pass as parameter)

3. Use the private key to access VMs:
   ```bash
   ssh -i ~/.ssh/dev-vm-key ubuntu@<vm-ip>
   ```

## Important Notes

### MAC Address Matching

This toolkit uses **MAC-based network matching** for reliability. The MAC address must be consistent between:
- `InterfaceMacAddress` parameter (seed disk creation)
- `StaticMacAddress` parameter (VM creation)

Example valid MAC format: `00-15-5D-32-10-01`

### Golden Image Best Practices

- Keep the golden image **minimal and clean**
- Avoid installing project-specific dependencies on the golden image
- Use cloud-init to customize each clone
- Document any system-level changes you make to the image
- Refresh the golden image periodically with OS updates

### Clone-Specific Configuration

Each VM clone should have:
- **Unique hostname**
- **Unique MAC address** (if multiple VMs on same network)
- **Project-specific bootstrap** script applied after boot

## Troubleshooting

### VM doesn't boot
- Verify the golden image path is correct
- Ensure Hyper-V has read permissions on image files
- Check that the seed disk was created with matching MAC address

### Network not configured
- Verify cloud-init ran: `sudo cloud-init status` on the VM
- Check cloud-init logs: `sudo cat /var/log/cloud-init-output.log`
- Ensure network config YAML is valid

### SSH access denied
- Verify public key is correctly placed in `authorized_keys`
- Check SSH service is running: `sudo systemctl status ssh`
- Confirm correct username and IP address

### System issues after boot
- Review `cloud-init-output.log` for error messages
- Check `user-data` template for script errors
- Test scripts locally before adding to cloud-init

## Contributing

Contributions are welcome! Please:

1. Test changes thoroughly on your Hyper-V setup
2. Document any new parameters or scripts
3. Keep scripts focused and modular
4. Submit pull requests with clear descriptions

## License

MIT License — Feel free to use and modify for your needs.

## Support

For issues or questions:
- Check the Troubleshooting section
- Review cloud-init logs on the VM
- Open an issue in the project repository

---

**Happy VM provisioning! 🚀**
