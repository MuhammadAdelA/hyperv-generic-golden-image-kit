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
├── config-examples/                    # Full, DHCP, Private NAT, Advanced, and Seed-only examples
├── AUTO-CONFIG.md                      # Auto/config usage guide
├── scripts/                           # Linux-side preparation scripts
│   ├── prepare-current-image-for-golden.sh  # Initial system setup
│   └── seal-golden-image.sh                 # Finalize and clean image
├── cloud-init/                        # Cloud-init templates
│   ├── meta-data.template.yaml        # Instance metadata
│   ├── user-data.template.yaml        # User script template
│   ├── network-config.dhcp.yaml       # DHCP network config
│   └── network-config.static.template.yaml  # Static IP template
└── windows-scripts/                   # All executable PowerShell files
    ├── create-vm.ps1                  # The only VM creation entry point
    ├── Test-HyperVPreflight.ps1       # Internal environment checks/repair
    ├── New-NoCloudSeedDisk.ps1        # Internal seed-disk creation
    ├── New-HyperVVmFromGolden.ps1     # Internal VM creation
    ├── Migrate-SeedDisksToVmFolders.ps1
    ├── Remove-HyperVVmSafe.ps1
    ├── ip-reservations.ps1           # List/release persistent static-IP reservations
    ├── repair-vm-disk-access.ps1     # Repair per-VM ACLs on attached VHDX files
    └── uninstall.ps1                 # Remove only per-user application settings
```

## Quick Start

Run the main script from an elevated PowerShell session. It is the only supported user entry point and needs no prepared config file:

```powershell
.\windows-scripts\create-vm.ps1
```

### Interactive configuration and SSH key setup

Create or update the per-user configuration without creating a seed disk, VM, virtual switch, NAT, or IP reservation:

```powershell
.\windows-scripts\create-vm.ps1 -ConfigureOnly
```

The wizard accepts an existing OpenSSH public key such as `%USERPROFILE%\.ssh\id_ed25519.pub`. If the selected path does not exist, it offers to create a new Ed25519 key pair without a passphrase. Existing private or public key files are never overwritten.

To request key generation explicitly, including with `-NoPrompt`, provide the public-key destination and use:

```powershell
.\windows-scripts\create-vm.ps1 -ConfigureOnly -GenerateSshKey `
  -SshPublicKeyPath "$env:USERPROFILE\.ssh\hyperv-golden.pub"
```

The private key is created beside it without the `.pub` suffix and is never written to the configuration file. To write the generated configuration to a specific location, add `-ConfigOutputPath '<absolute-path>.psd1'`; otherwise the normal `%LOCALAPPDATA%\HyperVGoldenImage\New-GoldenVmInteractive.config.psd1` path is used.

Interactive prompts color engine-suggested defaults inside `[...]` in cyan, while calculated paths and values use dark cyan. User-entered text keeps the terminal's normal input color.

On first run, the default persistent data layout is created under the current user profile:

```text
%USERPROFILE%\HyperVGoldenImage-Data\
├── VMs\
├── Seeds\
└── state\ip-allocations.json
```

The golden VHDX is detected from the project's `Golden` directory when available. You can replace every suggested path interactively.

Ready-to-copy configuration examples:

- `New-GoldenVmInteractive.config.dhcp.example.psd1`: DHCP on an existing DHCP-capable switch.
- `New-GoldenVmInteractive.config.static.example.psd1`: ready Private NAT on `172.29.240.0/24`; preflight can create its switch, gateway, and NAT after approval.
- `New-GoldenVmInteractive.config.advanced-static.example.psd1`: static IP on a pre-existing custom or External switch; no NAT is created.
- `New-GoldenVmInteractive.config.seed-only.example.psd1`: build only the NoCloud seed disk.
- `New-GoldenVmInteractive.config.example.psd1`: fully commented field reference.

For static networking, a successful seed-only or VM creation reserves the address in `state\ip-allocations.json`. Reservation changes are serialized across concurrent local runs, and a later run refuses to assign that address to a different VM.

```powershell
# Show reservations
.\windows-scripts\ip-reservations.ps1

# Release a stale reservation after confirmation
.\windows-scripts\ip-reservations.ps1 -Action Release -VmName 'vm-old'
```

### Host preflight check

The entry point automatically runs a read-only preflight before creating a seed disk or VM:

```powershell
.\windows-scripts\create-vm.ps1
```

It checks elevation, the Hyper-V feature/module/service and required commands, the selected virtual switch, its management adapter, the host gateway address, and matching `NetNat`. For private NAT, if it finds only repairable switch/NAT problems, it describes the exact repair and asks once before changing the host. It then repeats verification. A missing DHCP switch is never synthesized because the program cannot infer whether the intended switch is external, internal, or private. Repair deliberately refuses to replace an existing switch, modify a conflicting NAT, reuse a gateway assigned to another adapter, or continue when the gateway is outside the expected prefix. `Test-HyperVPreflight.ps1` is an internal helper; users do not need to invoke it.


## Production Automation Example

The wrapper creates its config during first run. No copy or example file is required. The resulting file contains host-specific values such as:

- `GoldenVhdxPath`
- `VmRoot`
- `SeedRoot`
- `SwitchName`

> Seed layout: when `SeedDiskPath` is empty, the wrapper stores each seed disk under a per-VM folder:
> `<SeedRoot>\<DeviceName>\<DeviceName>-seed.vhdx`.
> Use `SeedDiskPath` only when you want a full custom seed disk path.

- `SshPublicKeyPath`
- networking values if `UseStatic = $true`

After first run, use bare automation:

```powershell
.\windows-scripts\create-vm.ps1 -Auto
```

CLI parameters override config values. For example, reuse the same config but create another VM:

```powershell
.\windows-scripts\create-vm.ps1 -Auto -DeviceName "vm-prod-02" -Hostname "vm-prod-02"
```

For static networking, override only the last octet:

```powershell
.\windows-scripts\create-vm.ps1 -Auto -DeviceName "vm-prod-02" -Hostname "vm-prod-02" -IpOctet 26
```

You can also use a different config file:

```powershell
.\windows-scripts\create-vm.ps1 -Auto -ConfigPath "<absolute-path-to-config.psd1>"
```

Config lookup order is: explicit `-ConfigPath`, then the current user's `%LOCALAPPDATA%\HyperVGoldenImage\New-GoldenVmInteractive.config.psd1`. On first run no config or example file is required: built-in defaults and environment detection seed the interactive questions. The entry point saves the user config atomically only after seed/VM creation succeeds; cancellation or creation failure does not overwrite it. A `SeedOnly` run preserves the saved golden-disk, VM-root, and switch settings and does not make `SeedOnly` the next-run default. Passwords are never stored. Path values support `~`, `%USERPROFILE%`, and `%LOCALAPPDATA%`.

To import settings from a migrated legacy project, pass either its config file or its backup root:

```powershell
.\windows-scripts\create-vm.ps1 -ImportConfigPath 'E:\Backup_D\HyperV'
```

When the root contains a migrated-backup directory, the program discovers its `New-GoldenVmInteractive.config.psd1` without modifying the source. Storage roots are normalized to `<import-root>\VMs` and `<import-root>\Seeds`; historical `VMss` and `Seedss` folders are reported as legacy typo locations but are never moved, registered, or deleted. A stale golden-VHDX path is discarded so the current project's `Golden` directory can be detected. `-ImportConfigPath` and `-ConfigPath` are mutually exclusive. The imported settings are written to the normal per-user config only after a successful creation.

`-Auto` uses valid supplied/configured/default values without prompting, but asks for missing or invalid values. Host repair always requires an explicit answer, even with `-Auto`. Add `-NoPrompt` for scheduled jobs or CI: it never prompts or repairs, and fails before creating a seed or VM when setup or preflight is incomplete:

```powershell
.\windows-scripts\create-vm.ps1 -Auto -NoPrompt
```

### Reset / uninstall user settings

Preview the operation without changing anything:

```powershell
.\windows-scripts\uninstall.ps1 -WhatIf
```

Remove `%LOCALAPPDATA%\HyperVGoldenImage` after PowerShell confirmation:

```powershell
.\windows-scripts\uninstall.ps1
```

For an explicitly unattended removal, use `-Confirm:$false`. This command never removes VMs, VHDX files, switches, NAT configuration, project files, `%USERPROFILE%\HyperVGoldenImage-Data`, or its IP reservation registry. Running `create-vm.ps1` afterward starts the complete first-run setup again while retaining existing VM data and reservations.

A full no-config command is still supported, but it is intentionally verbose because every host-specific value must be explicit:

```powershell
.\windows-scripts\create-vm.ps1 -Auto `
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
.\windows-scripts\create-vm.ps1 -SeedOnly -DeviceName "vm-prod-01"
```

Seed replacement is transactional: the new VHDX is built and dismounted under a staging name, then atomically replaces the previous seed only after all cloud-init files were written successfully.

Direct seed-disk creation is also available:

```powershell
.\windows-scripts\New-NoCloudSeedDisk.ps1 `
  -SeedDiskPath "<absolute-path-to-seed-disk.vhdx>" `
  -Hostname "dev-vm-01" `
  -AdminUser "ubuntu" `
  -SshPublicKeyPath "$env:USERPROFILE\.ssh\id_ed25519.pub" `
  -InterfaceMacAddress "00-15-5D-32-10-01"
```

### Step 3: Create New VM (on Windows)

For most users, the wrapper is preferred:

```powershell
.\windows-scripts\create-vm.ps1 -Auto
```

Direct VM creation is also available:

```powershell
.\windows-scripts\New-HyperVVmFromGolden.ps1 `
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
.\windows-scripts\Migrate-SeedDisksToVmFolders.ps1 -SeedRoot "D:\HyperV\Seeds"
```

Apply the migration only after reviewing the plan:

```powershell
.\windows-scripts\Migrate-SeedDisksToVmFolders.ps1 -SeedRoot "D:\HyperV\Seeds" -Apply
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
.\windows-scripts\Remove-HyperVVmSafe.ps1 -VmName "vm-prod-01"
```

Delete only after reviewing the preview output:

```powershell
.\windows-scripts\Remove-HyperVVmSafe.ps1 -VmName "vm-prod-01" -Action Delete
```

Paths under the VM's own dedicated Hyper-V folder are authorized automatically. The folder leaf must match the VM name. To delete an external per-VM seed folder, explicitly authorize its verified root; its leaf must also match the VM name:

```powershell
.\windows-scripts\Remove-HyperVVmSafe.ps1 -VmName "vm-prod-01" -Action Delete `
  -AllowedRoot "D:\HyperV\Seeds\vm-prod-01"
```

Safety behavior:

- Preview is the default action.
- The script shows hard disks that will be deleted before deletion and refuses shared, out-of-root, or broadly named paths.
- DVD/ISO paths are displayed only and are not deleted directly.
- Virtual switches, NAT networks, and `VM-NAT` are not deleted.
- Authorized files are removed individually. A VM or seed folder is deleted only if it becomes empty and its folder name matches the VM name; non-empty folders are preserved with a warning.

If VM registration was already removed but dedicated residual folders remain, preview their cleanup with explicit roots:

```powershell
.\windows-scripts\Remove-HyperVVmSafe.ps1 -VmName "vm-prod-01" -CleanupOrphans `
  -AllowedRoot "D:\HyperV\VMs\vm-prod-01","D:\HyperV\Seeds\vm-prod-01"
```

After reviewing the preview, add `-Action Delete`. Orphan cleanup removes only the standard `<vm>-seed.vhdx.rescue.txt` sidecar and empty directories. Any unexpected file is displayed and preserved.

## Configuration

### Network Configuration

The guided setup asks for the user's intent:

```text
[1] Automatic network (DHCP) - recommended
[2] Private NAT with a fixed IP
[3] Advanced/custom networking
```

DHCP hides CIDR, gateway, DNS, and interface details. Private NAT asks once for the VM address, then gateway, DNS, and switch, while deriving `/24` and the NAT network automatically. Only Advanced mode exposes the cloud-init interface and full CIDR controls. The selected mode is saved as `NetworkMode` for later Auto runs.

**DHCP (Default)**
```bash
# Uses cloud-init/network-config.dhcp.yaml
# Automatic IP assignment from your network
```

**Private NAT example**

```text
VM IP address [172.29.240.10]:
Gateway [172.29.240.1]:
DNS servers [1.1.1.1, 8.8.8.8]:
Hyper-V switch [HyperV-NAT]:
```

The ready example uses `172.29.240.0/24` to avoid the common `192.168.x.x` Wi-Fi ranges. The program shows a readable network summary before preflight and prevents an IP reserved for another VM from being reused. Always verify that the selected subnet does not overlap an existing host route or `NetNat` before approving creation.

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

   The interactive entry point requires an actual OpenSSH public-key file such as `%USERPROFILE%\.ssh\id_ed25519.pub`. Directories, missing files, private keys, and non-key text files are rejected.

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
