# Hyper-V Golden Image Kit

> Create reproducible, development-ready Ubuntu VMs on Hyper-V quickly and consistently. Automate VM provisioning from a lightweight golden image using cloud-init NoCloud.

## ⚡ Quick Start (5 minutes)

### 1. Prepare the Golden Image (on Ubuntu VM)
```bash
sudo bash scripts/prepare-current-image-for-golden.sh
sudo golden-image-check
sudo bash scripts/seal-golden-image.sh
sudo poweroff
```

### 2. Create a Seed Disk (on Windows)
```powershell
.\windows\New-NoCloudSeedDisk.ps1 `
  -SeedDiskPath "D:\HyperV\Seeds\dev-vm-01-seed.vhdx" `
  -Hostname "dev-vm-01" `
  -AdminUser "ubuntuadmin" `
  -SshPublicKeyPath "$env:USERPROFILE\.ssh\id_ed25519.pub" `
  -InterfaceMacAddress "00-15-5D-32-10-01" `
  -TemplateRoot ".\cloud-init"
```

### 3. Create the VM (on Windows)
```powershell
.\windows\New-HyperVVmFromGolden.ps1 `
  -VmName "dev-vm-01" `
  -GoldenVhdxPath "D:\HyperV\Golden\ubuntu-golden.vhdx" `
  -VmRoot "D:\HyperV\VMs" `
  -SwitchName "Default Switch" `
  -SeedDiskPath "D:\HyperV\Seeds\dev-vm-01-seed.vhdx" `
  -StaticMacAddress "00-15-5D-32-10-01" `
  -StartAfterCreate
```

### 4. Access the VM
```bash
ssh -i ~/.ssh/id_ed25519 ubuntuadmin@<VM-IP>
```

---

## 📋 Overview

This toolkit solves a specific problem: **Create Ubuntu VMs on Hyper-V quickly and consistently without manual rebuild**.

### The Workflow
```
Golden Ubuntu VHDX (generic, reusable)
    ↓
Per-VM NoCloud Seed VHDX (unique identity)
    ↓
Hyper-V VM creation (automated)
    ↓
First-boot cloud-init customization
    ↓
Ready to use
```

### Why This Approach?
- **Fast**: Cloning is much faster than building from scratch
- **Consistent**: Every VM starts from the same base
- **Safe**: Clone-specific data doesn't pollute the golden image
- **Flexible**: Different networks (DHCP/static) per VM
- **Maintainable**: One golden image serves multiple projects

### Key Design Principle
The golden image stays **generic and clean**. Each clone gets personalized through a small seed disk that injects:
- Unique hostname
- Network configuration
- SSH keys
- User accounts
- Custom scripts

---

## 🔧 Prerequisites

### Windows Host
- Windows 10/11 Pro or Windows Server with Hyper-V enabled
- PowerShell 5.1 or later
- Hyper-V management tools
- Sufficient disk space for golden image and clones

### Ubuntu Source VM
- Ubuntu Server 20.04 LTS or later (minimal install recommended)
- Network connectivity (SSH or file copy method)
- At least 2 GB RAM, 20 GB disk for preparation

### Recommended Folder Structure
```
D:\HyperV\
├── Golden\          # Store golden VHDX files
├── Seeds/           # Per-VM NoCloud seed disks
└── VMs/             # Created VM folders
```

---

## 📁 Project Structure

```
hyperv-generic-golden-image-kit/
├── README.md
├── scripts/
│   ├── prepare-current-image-for-golden.sh   # Ubuntu prep script
│   └── seal-golden-image.sh                   # Ubuntu seal script
├── cloud-init/
│   ├── meta-data.template.yaml               # Instance metadata
│   ├── user-data.template.yaml               # First-boot customization
│   ├── network-config.dhcp.yaml              # DHCP networking
│   └── network-config.static.template.yaml   # Static IP networking
└── windows/
    ├── New-NoCloudSeedDisk.ps1               # Create seed disk
    └── New-HyperVVmFromGolden.ps1            # Create VM
```

---

## 📚 Documentation

For a more detailed, operations-focused guide, see [docs/README_DETAILED.md](docs/README_DETAILED.md).

---
## 🧭 Interactive Workflow (Optional)

If you are using the companion interactive launcher script for this workflow, you can answer prompts step by step instead of typing the seed and VM creation commands manually.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\New-GoldenVmInteractive.v2.ps1
```

The launcher asks for the same required values used by the project scripts, then calls:
- `windows/New-NoCloudSeedDisk.ps1`
- `windows/New-HyperVVmFromGolden.ps1`

It can also create or overwrite only the seed disk and skip VM creation when you choose that option.

---

## 🎯 Step-by-Step Walkthrough

### Phase 1: Prepare Golden Image on Ubuntu VM

#### What the prep script does:
- Installs: `cloud-init`, `openssh-server`, `qemu-guest-agent`, `curl`, `git`, `jq`, `tmux`
- Configures cloud-init for NoCloud datasource
- Sets up generic netplan with DHCP
- Locks default user password
- Disables SSH password authentication
- Removes host-specific SSH keys
- Creates `golden-image-check` helper command

#### Steps:
```bash
# Copy scripts to the Ubuntu VM first
# Then inside Ubuntu:
sudo ~/prepare-current-image-for-golden.sh

# Verify everything is correct
sudo golden-image-check
sudo sshd -t
sudo netplan generate

# Seal and shutdown
sudo ~/seal-golden-image.sh
sudo poweroff
```

#### What the seal script does:
- Clears machine-id
- Removes SSH host keys (new ones generated per clone)
- Clears shell history
- Removes authorized_keys
- Cleans apt metadata and temp files
- Runs `cloud-init clean --logs --machine-id --configs all --seed`

**After sealing, save this VHDX as your golden image** (e.g., `ubuntu-24.04-golden.vhdx`)

---

### Phase 2: Create a Seed Disk on Windows

The seed disk is a small FAT32 VHDX containing cloud-init metadata. It makes each clone unique.

#### Mandatory Parameters:
- `-SeedDiskPath`: Where to save the seed VHDX
- `-Hostname`: Hostname for the clone
- `-AdminUser`: Main admin username
- `-SshPublicKeyPath`: Path to your `.pub` SSH key file
- `-InterfaceMacAddress`: MAC address for network config

#### DHCP Example (Simplest):
```powershell
$Mac = "00-15-5D-32-10-01"
$SeedDisk = "D:\HyperV\Seeds\ubuntu-dev-01-seed.vhdx"

.\windows\New-NoCloudSeedDisk.ps1 `
  -SeedDiskPath $SeedDisk `
  -Hostname "ubuntu-dev-01" `
  -AdminUser "ubuntuadmin" `
  -SshPublicKeyPath "$env:USERPROFILE\.ssh\id_ed25519.pub" `
  -InterfaceMacAddress $Mac `
  -TemplateRoot ".\cloud-init"
```

#### Static IP Example:
```powershell
.\windows\New-NoCloudSeedDisk.ps1 `
  -SeedDiskPath $SeedDisk `
  -Hostname "ubuntu-panel-01" `
  -AdminUser "ubuntuadmin" `
  -SshPublicKeyPath "$env:USERPROFILE\.ssh\id_ed25519.pub" `
  -InterfaceMacAddress "00-15-5D-32-20-10" `
  -TemplateRoot ".\cloud-init" `
  -StaticIpCidr "192.168.201.10/24" `
  -Gateway "192.168.201.1" `
  -DnsServers "1.1.1.1","8.8.8.8"
```

#### With Rescue User:
```powershell
.\windows\New-NoCloudSeedDisk.ps1 `
  -SeedDiskPath $SeedDisk `
  -Hostname "ubuntu-dev-01" `
  -AdminUser "ubuntuadmin" `
  -SshPublicKeyPath "$env:USERPROFILE\.ssh\id_ed25519.pub" `
  -InterfaceMacAddress "00-15-5D-32-10-01" `
  -TemplateRoot ".\cloud-init" `
  -EnableRescueUser $true `
  -RescueUser "rescueadmin" `
  -RescuePassword "TempPassword123!"
```

**Important**: Save the MAC address—you'll need it again in the next step!

---

### Phase 3: Create VM from Golden Image on Windows

This script creates a Generation 2 Hyper-V VM with:
- Secure Boot enabled
- Dynamic memory (2-8 GB range, 4 GB default)
- 2 vCPUs (configurable)
- Seed disk attached as SCSI device
- **Same MAC address as the seed disk**

#### Mandatory Parameters:
- `-VmName`: Name of the new VM
- `-GoldenVhdxPath`: Path to your golden image VHDX
- `-VmRoot`: Parent folder for the new VM
- `-SwitchName`: Hyper-V virtual switch name
- `-SeedDiskPath`: Path to the seed disk you just created
- `-StaticMacAddress`: **Must match the seed disk MAC!**

#### Example:
```powershell
$VmName = "ubuntu-dev-01"
$Mac = "00-15-5D-32-10-01"  # Same as seed disk!
$GoldenVhdx = "D:\HyperV\Golden\ubuntu-24.04-golden.vhdx"
$SeedDisk = "D:\HyperV\Seeds\$VmName-seed.vhdx"

.\windows\New-HyperVVmFromGolden.ps1 `
  -VmName $VmName `
  -GoldenVhdxPath $GoldenVhdx `
  -VmRoot "D:\HyperV\VMs" `
  -SwitchName "Default Switch" `
  -SeedDiskPath $SeedDisk `
  -StaticMacAddress $Mac `
  -ProcessorCount 4 `
  -MemoryStartupBytes 4GB `
  -StartAfterCreate
```

---

### Phase 4: Boot and Verify

Once the VM starts, cloud-init will run automatically on first boot. This takes 1-3 minutes.

```bash
# SSH into the VM (use PRIVATE key, not .pub!)
ssh -i ~/.ssh/id_ed25519 ubuntuadmin@<VM-IP>

# Verify cloud-init completed
cloud-init status --long

# Check the datasource
cloud-init query ds

# Verify network configuration
ip -br a

# Check hostname
hostnamectl --static

# View cloud-init logs if needed
sudo tail -f /var/log/cloud-init-output.log
```

---

## ⚠️ Critical: MAC Address Matching

**The most important rule: The MAC address in the seed disk MUST match the MAC address on the VM network adapter.**

### Why?
Cloud-init uses MAC addresses to match network configuration templates to specific adapters. If they don't match, the network config may not apply to the interface you expect.

### Valid MAC Formats:
- `00-15-5D-32-10-01` (hyphen-separated, PowerShell input)
- `00:15:5d:32:10:01` (colon-separated, cloud-init format)
- `00155D321001` (no separators)

**Example checklist:**
```
Seed disk creation:  -InterfaceMacAddress "00-15-5D-32-10-01"  ✓
VM creation:         -StaticMacAddress "00-15-5D-32-10-01"     ✓
Verify on VM:        ip link show | grep 00:15:5d:32:10:01     ✓
```

---

## 🔧 Configuration Options

### Network Modes

#### DHCP (Default, Easiest)
No extra parameters needed. The VM will get an IP from your network.

#### Static IP
```powershell
.\windows\New-NoCloudSeedDisk.ps1 `
  ... `
  -StaticIpCidr "192.168.100.50/24" `
  -Gateway "192.168.100.1" `
  -DnsServers "1.1.1.1","8.8.8.8"
```

### Customizing User Data
Edit `cloud-init/user-data.template.yaml` to:
- Add additional packages
- Configure services
- Set environment variables
- Run custom scripts on first boot

### Customizing Network Config
For advanced networking, edit the template files or supply a custom path:
```powershell
-NetworkConfigPath "C:\path\to\custom-netplan.yaml"
```

---

## 🐛 Troubleshooting

### VM won't start
**Check:**
- Golden VHDX path exists: `Test-Path "D:\HyperV\Golden\ubuntu-golden.vhdx"`
- Seed disk path exists: `Test-Path "D:\HyperV\Seeds\dev-seed.vhdx"`
- Switch name is correct: `Get-VMSwitch`
- VM name not already used: `Get-VM`

### Network doesn't come up in VM
**Inside the VM, check:**
```bash
cloud-init status --long           # Should show 'done'
sudo cat /var/log/cloud-init-output.log
ip -br a                            # Check if interface has IP
sudo netplan apply                  # Try reapplying config
```

**Common causes:**
- MAC address mismatch (most common!)
- Seed disk not attached
- Network template misconfiguration
- Switch not properly configured

### SSH authentication fails
**Verify:**
```bash
# Use PRIVATE key, not .pub
ssh -i ~/.ssh/id_ed25519 ...  # ✓ Correct

# Not this:
ssh -i ~/.ssh/id_ed25519.pub ...  # ✗ Wrong

# Check cloud-init placed the key
cat ~/.ssh/authorized_keys
```

### Can't connect to VM from Windows
```powershell
# Find the VM's IP
Get-VMNetworkAdapter -VMName "ubuntu-dev-01"

# Or from inside the VM
ip -br a
```

### Need to inspect seed disk contents
```powershell
Mount-VHD -Path "D:\HyperV\Seeds\dev-seed.vhdx" -Passthru | `
  Get-Disk | Get-Partition | Get-Volume

# Then open in file explorer (usually E: drive)
Get-Content E:\network-config

# When done:
Dismount-VHD -Path "D:\HyperV\Seeds\dev-seed.vhdx"
```

---

## 🔐 Security Best Practices

- **Use SSH keys, not passwords**: Never rely on password authentication
- **Disable root login**: Enabled by default in cloud-init template
- **Keep golden image minimal**: No project-specific secrets
- **Lock down rescue users**: Use strong passwords if enabled
- **Rotate SSH keys periodically**: Regenerate and redeploy as needed
- **Update golden image regularly**: Reseal after Ubuntu security updates

---

## 🚀 Recommended Workflow

```
1. Keep one clean Ubuntu VM ready
2. Run prepare script → validate → seal script
3. Store sealed VHDX as golden image (power it off first)
4. For each new VM:
   a. Pick a hostname and unique MAC
   b. Create a seed disk with that MAC
   c. Create a VM using the same MAC
   d. Start and verify cloud-init
   e. Apply your project bootstrap
```

---

## ❌ Common Mistakes to Avoid

| Mistake | Problem | Solution |
|---------|---------|----------|
| Different MAC addresses | Network config won't apply | Use same MAC in seed AND VM creation |
| Using `.pub` key with `ssh -i` | SSH auth fails | Use the **private** key (no .pub) |
| Missing both `-StaticIpCidr` and `-Gateway` | Script fails | Provide **both** for static IP |
| Not matching VM name | VM creation fails | Choose unique names or delete old VMs |
| Forgetting PowerShell execution policy | Scripts won't run | Run `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` |

---

## 📊 Quick Reference

### File purposes:

| File | What it does |
|------|--------------|
| `prepare-current-image-for-golden.sh` | Sets up Ubuntu for golden image (run inside VM) |
| `seal-golden-image.sh` | Removes host keys and history (run inside VM) |
| `New-NoCloudSeedDisk.ps1` | Creates personalized seed VHDX (run on Windows) |
| `New-HyperVVmFromGolden.ps1` | Creates Hyper-V VM from golden image (run on Windows) |
| `user-data.template.yaml` | Cloud-init first-boot config template |
| `network-config.dhcp.yaml` | DHCP network template |
| `network-config.static.template.yaml` | Static IP network template |
| `meta-data.template.yaml` | Cloud-init instance metadata |

### Common command snippets:

```powershell
# Set PowerShell execution policy for session
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# List all VMs
Get-VM

# List Hyper-V switches
Get-VMSwitch

# Check VM network settings
Get-VMNetworkAdapter -VMName "ubuntu-dev-01"

# Start/Stop VM
Start-VM -Name "ubuntu-dev-01"
Stop-VM -Name "ubuntu-dev-01"
```

```bash
# Check cloud-init status
cloud-init status --long

# View cloud-init logs
sudo cat /var/log/cloud-init-output.log

# Check network
ip -br a

# SSH in (use private key!)
ssh -i ~/.ssh/id_ed25519 ubuntuadmin@<IP>
```

---

## 📚 Next Steps

1. ✅ Set up your Windows folder structure
2. ✅ Prepare a Ubuntu VM with the scripts
3. ✅ Create and test a DHCP clone (easiest)
4. ✅ Create a static IP clone (optional)
5. ✅ Add project-specific bootstrap scripts

---

## 💡 Tips

- **Start with DHCP** before trying static IP—it's simpler to debug
- **Test seed disk creation** separately from VM creation
- **Keep seeds and VMs organized** in separate folders
- **Document your MAC addresses** if managing many VMs
- **Version your golden image** (e.g., `ubuntu-24.04-golden-v1.vhdx`)
- **Refresh the golden image** quarterly with OS security updates

---

## 📞 Support

**If something fails:**
1. Check the **Troubleshooting** section above
2. Review cloud-init logs: `sudo cat /var/log/cloud-init-output.log`
3. Verify MAC addresses match exactly
4. Try DHCP before static IP
5. Check Hyper-V switch configuration

---

## 📄 License

MIT License — Use and modify freely for your needs.

---

**Happy VM provisioning! 🚀**
