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

```powershell
.\windows\New-NoCloudSeedDisk.ps1 `
  -SeedDiskPath "C:\Hyper-V\seed-disk.vhdx" `
  -InterfaceMacAddress "00-15-5D-32-10-01" `
  -Hostname "dev-vm-01"
```

### Step 3: Create New VM (on Windows)

```powershell
.\windows\New-HyperVVmFromGolden.ps1 `
  -GoldenImagePath "C:\Hyper-V\golden-image.vhdx" `
  -SeedDiskPath "C:\Hyper-V\seed-disk.vhdx" `
  -VmName "dev-vm-01" `
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
