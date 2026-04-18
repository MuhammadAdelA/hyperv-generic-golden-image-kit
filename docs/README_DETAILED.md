# Hyper-V Generic Golden Image Kit

A detailed, operations-focused guide for building a **generic Ubuntu golden image** on Hyper-V and then using that image to create clean, repeatable VM clones with **cloud-init NoCloud**.

This README merges the earlier overview README, the practical quick guide, and the behavior of the **current pruned project files**. It is written to be used as the main repository README for day-to-day work.

---

## 1) What this project is for

This kit solves a very specific problem:

You want to create Ubuntu VMs on Hyper-V **quickly and consistently** without rebuilding each machine manually.

Instead of installing and configuring Ubuntu from scratch every time, you:

1. Start from one well-prepared Ubuntu VM.
2. Convert it into a **generic golden image**.
3. Keep that image clean and reusable.
4. Generate a small **NoCloud seed disk** for each new VM.
5. Create a new Hyper-V VM from the golden VHDX.
6. Let **cloud-init** personalize the clone on first boot.

That gives you the speed of cloning with the safety of first-boot customization.

### The core design idea

The repository intentionally separates responsibilities:

- The **golden image** contains only generic operating system preparation.
- The **seed disk** contains clone-specific identity and first-boot data.
- The **new VM** is just a Hyper-V shell around the copied golden disk plus the seed disk.
- The **project bootstrap** happens **after** you log in to the VM, not inside the golden image.

This separation is the reason the workflow stays maintainable.

---

## 2) What is included in this pruned project

This repository is the **clean operational subset** of a larger working folder. It keeps only the files that matter for the supported workflow.

### Linux-side scripts

- `scripts/prepare-current-image-for-golden.sh`
- `scripts/seal-golden-image.sh`

### cloud-init templates

- `cloud-init/meta-data.template.yaml`
- `cloud-init/user-data.template.yaml`
- `cloud-init/network-config.dhcp.yaml`
- `cloud-init/network-config.static.template.yaml`

### Windows / Hyper-V automation

- `windows/New-NoCloudSeedDisk.ps1`
- `windows/New-HyperVVmFromGolden.ps1`

### What was intentionally removed

Older fixed, patched, duplicated, and GUI-oriented variants were removed from the pruned version so the repository documents **one supported path** instead of many experimental ones.

That makes this repo better for:

- repeatable provisioning,
- documentation,
- maintenance,
- onboarding,
- reducing operator confusion.

---

## 3) How the workflow works from start to finish

Think of the process as four distinct phases.

### Phase A — Prepare one Ubuntu VM

You begin with a normal Ubuntu VM that you trust and want to turn into a reusable base.

The preparation script installs and enables the right services, resets the machine into a generic state, and replaces host-specific assumptions with clone-friendly defaults.

### Phase B — Seal that Ubuntu VM

After preparation and validation, the sealing script removes machine identity, SSH host keys, shell history, old authorized keys, temporary caches, and cloud-init state.

After sealing, you shut the VM down and keep its VHDX as your **golden image**.

### Phase C — Generate a seed disk for a new clone

For each new VM, you create a small FAT32 VHDX labeled `cidata` that contains:

- `meta-data`
- `user-data`
- `network-config`

That seed disk is the local NoCloud datasource that cloud-init reads on first boot.

### Phase D — Create the Hyper-V VM from the golden VHDX

The VM creation script copies the golden VHDX into a new VM folder, builds a Generation 2 Hyper-V VM, applies memory and CPU settings, sets a static MAC address, attaches the seed disk, and optionally starts the VM.

---

## 4) Architecture and provisioning model

The repository uses a simple but powerful model:

```text
Golden Ubuntu VHDX (generic)
        +
Per-VM NoCloud seed VHDX (identity + user + network)
        +
Hyper-V VM definition (name + switch + memory + MAC)
        =
First boot cloud-init customization
```

This model has important advantages:

- **Fast cloning** because the operating system is already installed.
- **Consistency** because all VMs begin from the same base.
- **Safety** because clone-specific data does not pollute the golden image.
- **Flexibility** because DHCP/static networking and rescue behavior are injected per VM.

---

## 5) Prerequisites

## Windows host requirements

You should have:

- Windows 10/11 Pro or Enterprise, or Windows Server, with Hyper-V enabled
- PowerShell 5.1 or later
- Hyper-V management tools installed
- Permission to create VMs, VHDX files, switches, and mount virtual disks

## Ubuntu source VM requirements

Your source Ubuntu VM should be:

- a working Ubuntu Server installation,
- reachable enough to test before sealing,
- suitable to become a clean base image.

The project scripts will install the packages they need during preparation.

## Typical host folder layout

A clean layout helps a lot:

```text
D:\HyperV\Golden\   # stored golden VHDX files
D:\HyperV\Seeds\    # per-VM NoCloud seed disks
D:\HyperV\VMs\      # created VM folders and copied OS disks
D:\HyperV\ssh\      # optional SSH key storage
```

Example setup:

```powershell
mkdir D:\HyperV\Golden\
mkdir D:\HyperV\Seeds\
mkdir D:\HyperV\VMs\
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

---

## 6) The most important operational rule: MAC address matching

This repository relies on **MAC-based network matching**.

That means the network configuration written to the seed disk is tied to a specific MAC address, and the created Hyper-V VM must use that same MAC.

You must therefore reuse the same value in both places:

- `-InterfaceMacAddress` when creating the seed disk
- `-StaticMacAddress` when creating the VM

### Why this matters

The cloud-init network config matches the adapter by MAC address. If you generate the seed with one MAC but create the Hyper-V VM with another, cloud-init may not apply the intended network config to the interface you expect.

### Valid formats

The scripts accept common forms, such as:

- `00-15-5D-32-10-01`
- `00:15:5d:32:10:01`
- `00155D321001` for Hyper-V-facing input where applicable

Internally:

- the seed script normalizes to cloud-init style, such as `00:15:5d:32:10:01`
- the VM script normalizes to Hyper-V style, such as `00155D321001`

---

## 7) Repository structure

```text
hyperv-generic-golden-image-kit-pruned/
├── README.md
├── cloud-init/
│   ├── meta-data.template.yaml
│   ├── network-config.dhcp.yaml
│   ├── network-config.static.template.yaml
│   └── user-data.template.yaml
├── scripts/
│   ├── prepare-current-image-for-golden.sh
│   └── seal-golden-image.sh
└── windows/
    ├── New-HyperVVmFromGolden.ps1
    └── New-NoCloudSeedDisk.ps1
```

---

## 8) What each file actually does

## `scripts/prepare-current-image-for-golden.sh`

Run this **inside the current Ubuntu VM** before sealing it.

### What it does

It performs all of the following:

- installs required base packages such as `cloud-init`, `openssh-server`, `qemu-guest-agent`, `curl`, `git`, `jq`, `tmux`, and others,
- removes `/etc/cloud/cloud-init.disabled` if present,
- moves aside cloud-init config snippets that disable networking,
- forces datasource lookup to `NoCloud, None`,
- sets `preserve_hostname: false` and `manage_etc_hosts: true`,
- backs up existing netplan YAML files,
- replaces them with a generic DHCP-based netplan,
- resets the machine hostname to a generic template hostname,
- locks the existing primary user password,
- removes that user’s old `authorized_keys` file if present,
- disables SSH password authentication for future clones,
- enables cloud-init services, SSH, and the guest agent,
- installs a helper command called `golden-image-check`.

### What it does not do

It does **not**:

- shut down the VM,
- install project-specific software,
- permanently destroy old configs without making backups.

### Useful environment variables

The script supports these environment overrides:

- `PRIMARY_USER` (default: `ubuntuadmin`)
- `TEMPLATE_HOSTNAME` (default: `ubuntu-template`)
- `BACKUP_ROOT` (default: timestamped path under `/var/backups`)

Example:

```bash
sudo PRIMARY_USER=ubuntuadmin TEMPLATE_HOSTNAME=ubuntu-template \
  bash scripts/prepare-current-image-for-golden.sh
```

## `scripts/seal-golden-image.sh`

Run this **inside Ubuntu** only after you are satisfied with the prepared base VM.

### What it does

It:

- clears `/etc/machine-id`,
- recreates the D-Bus machine-id link,
- removes SSH host keys,
- removes root and user shell history,
- deletes old user `authorized_keys`,
- cleans apt metadata and temporary directories,
- runs `cloud-init clean --logs --machine-id --configs all --seed`.

### What it does not do

It does **not** automatically power off the VM. You should power it off yourself after sealing.

## `cloud-init/meta-data.template.yaml`

This template is minimal on purpose. It provides:

- `instance-id`
- `local-hostname`

That is enough for NoCloud identity in this workflow.

## `cloud-init/user-data.template.yaml`

This template creates the first-boot identity and access rules for the clone.

### Current behavior

It:

- disables the root account,
- controls whether SSH password authentication is enabled,
- deletes SSH host keys on first boot,
- creates the main admin user,
- optionally creates a rescue user,
- writes a simple `/etc/motd`,
- shows a final cloud-init completion message.

### Main admin user behavior

The admin user:

- is added to `adm` and `sudo`,
- gets passwordless sudo,
- has `lock_passwd: true`,
- authenticates with SSH keys.

That means the normal intended access path is **key-based SSH**, not password login.

### Rescue user behavior

If rescue mode is enabled in the seed script:

- a rescue user is created,
- that user gets the same admin-style group membership,
- the account has `lock_passwd: false`,
- a password is set through a generated or supplied `chpasswd` block,
- an SSH authorized key is also written for that rescue user.

## `cloud-init/network-config.dhcp.yaml`

This template defines a DHCP-based interface configuration that matches by MAC address.

It is the safest first test for a new environment.

## `cloud-init/network-config.static.template.yaml`

This template defines a static address, default route, and optional DNS block.

It is used when you supply both:

- `-StaticIpCidr`
- `-Gateway`

---

## 9) Detailed walkthrough: prepare the Ubuntu golden image

## Step 1 — Copy the scripts into the Ubuntu VM

From Windows, you can copy the Linux scripts to the running Ubuntu VM with `scp`.

Example:

```powershell
scp "C:\Users\Muhammed-Y520\Desktop\hyperv-generic-golden-image-kit\scripts\prepare-current-image-for-golden.sh" ubuntuadmin@192.168.200.10:/home/ubuntuadmin/
scp "C:\Users\Muhammed-Y520\Desktop\hyperv-generic-golden-image-kit\scripts\seal-golden-image.sh" ubuntuadmin@192.168.200.10:/home/ubuntuadmin/
```

## Step 2 — Run the preparation script inside Ubuntu

```bash
sudo ~/prepare-current-image-for-golden.sh
```

## Step 3 — Validate the prepared machine

The script installs a helper called `golden-image-check`.

Run:

```bash
sudo golden-image-check
sudo sshd -t
sudo netplan generate
```

You want to confirm that:

- cloud-init is installed,
- the hostname is generic,
- the SSH daemon config is valid,
- the netplan files are valid.

## Step 4 — Seal the image

```bash
sudo ~/seal-golden-image.sh
sudo poweroff
```

Once the VM is powered off, keep that disk as your golden VHDX.

Example path on Windows:

```powershell
$GoldenVhdx = "D:\HyperV\Golden\ubuntu-24.04-golden-base.vhdx"
```

---

## 10) Detailed walkthrough: create a new seed disk

The seed disk is what makes each clone unique.

The script reads the template files, replaces placeholders, creates a small dynamic VHDX, formats it as FAT32 with the label `cidata`, copies in `meta-data`, `user-data`, and `network-config`, and writes a rescue summary text file beside the VHDX.

## Mandatory parameters

`New-NoCloudSeedDisk.ps1` requires:

- `-SeedDiskPath`
- `-Hostname`
- `-AdminUser`
- `-SshPublicKeyPath`
- `-InterfaceMacAddress`

## Optional parameters

It also supports:

- `-InstanceId`
- `-TemplateRoot`
- `-NetworkConfigPath`
- `-InterfaceName`
- `-StaticIpCidr`
- `-Gateway`
- `-DnsServers`
- `-EnableRescueUser`
- `-RescueUser`
- `-RescueSshPublicKeyPath`
- `-RescuePassword`
- `-EnableRescueSshPassword`

## Important behavior notes

### DHCP vs static selection

The script chooses networking in this order:

1. If `-NetworkConfigPath` is supplied, it uses that custom file.
2. Else if either `-StaticIpCidr` or `-Gateway` is supplied, it expects **both** and uses the static template.
3. Otherwise it uses the DHCP template.

### Existing seed disks are overwritten

If the target seed VHDX already exists, the script deletes it and recreates it.

### Rescue summary file

After seed creation, the script writes:

```text
<SeedDiskPath>.rescue.txt
```

That file records the hostname, rescue user, rescue password, SSH password-auth setting, interface MAC, and seed path.

### A subtle template limitation

The PowerShell script exposes `-InterfaceName`, but the current network templates hardcode `lan0` instead of using an `__INTERFACE_NAME__` placeholder.

That means:

- passing `-InterfaceName` today does **not** change the generated interface key or `set-name` value,
- the rendered network config still uses `lan0`,
- to truly customize the interface name, you would need to update the templates.

This is important to understand so you do not expect that parameter to change current output by itself.

## DHCP example

```powershell
$VmName = "ubuntu-dev-01"
$Mac = "00-15-5D-32-10-01"
$SeedDisk = "D:\HyperV\Seeds\$VmName-seed.vhdx"

.\windows\New-NoCloudSeedDisk.ps1 `
  -SeedDiskPath $SeedDisk `
  -Hostname $VmName `
  -AdminUser "ubuntuadmin" `
  -SshPublicKeyPath "C:\Users\Muhammed-Y520\.ssh\id_ed25519.pub" `
  -InterfaceMacAddress $Mac `
  -TemplateRoot ".\cloud-init"
```

## Static IP example

```powershell
$VmName = "ubuntu-panel-static-01"
$Mac = "00-15-5D-32-20-10"
$SeedDisk = "D:\HyperV\Seeds\$VmName-seed.vhdx"

.\windows\New-NoCloudSeedDisk.ps1 `
  -SeedDiskPath $SeedDisk `
  -Hostname $VmName `
  -AdminUser "ubuntuadmin" `
  -SshPublicKeyPath "C:\Users\Muhammed-Y520\.ssh\id_ed25519.pub" `
  -InterfaceMacAddress $Mac `
  -TemplateRoot ".\cloud-init" `
  -StaticIpCidr "192.168.201.10/24" `
  -Gateway "192.168.201.1" `
  -DnsServers "1.1.1.1","8.8.8.8"
```

## Disable the rescue user example

Because `EnableRescueUser` is a **boolean parameter**, not a switch, disable it like this:

```powershell
.\windows\New-NoCloudSeedDisk.ps1 `
  -SeedDiskPath $SeedDisk `
  -Hostname $VmName `
  -AdminUser "ubuntuadmin" `
  -SshPublicKeyPath "C:\Users\Muhammed-Y520\.ssh\id_ed25519.pub" `
  -InterfaceMacAddress $Mac `
  -TemplateRoot ".\cloud-init" `
  -EnableRescueUser $false
```

## Enable rescue SSH password authentication

If you want the rescue account to also be reachable by SSH password authentication, add:

```powershell
-EnableRescueSshPassword
```

Be aware that this toggles `ssh_pwauth` in cloud-init, so document and use it intentionally.

---

## 11) Detailed walkthrough: create the new Hyper-V VM

The VM creation script is intentionally simple and strict.

It verifies that:

- the golden VHDX exists,
- the seed disk exists,
- the target Hyper-V switch exists,
- the VM name is not already in use,
- the VM path does not already exist.

It then:

- creates the VM folder,
- copies the golden VHDX to a new OS disk path,
- creates a Generation 2 VM,
- sets CPU count,
- enables dynamic memory,
- enables secure boot using `MicrosoftUEFICertificateAuthority`,
- applies the static MAC address,
- attaches the seed disk as a SCSI disk,
- optionally starts the VM.

## Mandatory parameters

`New-HyperVVmFromGolden.ps1` requires:

- `-VmName`
- `-GoldenVhdxPath`
- `-VmRoot`
- `-SwitchName`
- `-SeedDiskPath`
- `-StaticMacAddress`

## Optional parameters

It also supports:

- `-MemoryStartupBytes` (default: `4GB`)
- `-ProcessorCount` (default: `2`)
- `-MinimumMemoryBytes` (default: `2GB`)
- `-MaximumMemoryBytes` (default: `8GB`)
- `-SeedControllerLocation` (default: `1`)
- `-StartAfterCreate`

## Example

```powershell
.\windows\New-HyperVVmFromGolden.ps1 `
  -VmName $VmName `
  -GoldenVhdxPath $GoldenVhdx `
  -VmRoot "D:\HyperV\VMs" `
  -SwitchName "Default Switch" `
  -SeedDiskPath $SeedDisk `
  -StaticMacAddress $Mac `
  -StartAfterCreate
```

## Manual start example

If you do not pass `-StartAfterCreate`, start the VM yourself:

```powershell
Start-VM -Name $VmName
```

## Inspect the created VM

```powershell
Get-VM -Name $VmName | Format-List Name, State, Status
Get-VMNetworkAdapter -VMName $VmName | Format-List *
```

---

## 12) End-to-end example: DHCP clone

This is the simplest recommended first success path.

```powershell
$VmName = "ubuntu-dev-01"
$Mac = "00-15-5D-32-10-01"
$GoldenVhdx = "D:\HyperV\Golden\ubuntu-24.04-golden-base.vhdx"
$SeedDisk = "D:\HyperV\Seeds\$VmName-seed.vhdx"

.\windows\New-NoCloudSeedDisk.ps1 `
  -SeedDiskPath $SeedDisk `
  -Hostname $VmName `
  -AdminUser "ubuntuadmin" `
  -SshPublicKeyPath "C:\Users\Muhammed-Y520\.ssh\id_ed25519.pub" `
  -InterfaceMacAddress $Mac `
  -TemplateRoot ".\cloud-init"

.\windows\New-HyperVVmFromGolden.ps1 `
  -VmName $VmName `
  -GoldenVhdxPath $GoldenVhdx `
  -VmRoot "D:\HyperV\VMs" `
  -SwitchName "Default Switch" `
  -SeedDiskPath $SeedDisk `
  -StaticMacAddress $Mac `
  -StartAfterCreate
```

---

## 13) End-to-end example: static IP clone on an internal NAT switch

Use this after DHCP works, not before.

## Create the internal switch and NAT

```powershell
New-VMSwitch -Name "PanelNAT" -SwitchType Internal
New-NetIPAddress -InterfaceAlias "vEthernet (PanelNAT)" -IPAddress 192.168.201.1 -PrefixLength 24
New-NetNat -Name "PanelNAT" -InternalIPInterfaceAddressPrefix "192.168.201.0/24"
```

## Create the seed disk and VM

```powershell
$VmName = "ubuntu-panel-static-01"
$Mac = "00-15-5D-32-20-10"
$GoldenVhdx = "D:\HyperV\Golden\ubuntu-24.04-golden-base.vhdx"
$SeedDisk = "D:\HyperV\Seeds\$VmName-seed.vhdx"

.\windows\New-NoCloudSeedDisk.ps1 `
  -SeedDiskPath $SeedDisk `
  -Hostname $VmName `
  -AdminUser "ubuntuadmin" `
  -SshPublicKeyPath "C:\Users\Muhammed-Y520\.ssh\id_ed25519.pub" `
  -InterfaceMacAddress $Mac `
  -TemplateRoot ".\cloud-init" `
  -StaticIpCidr "192.168.201.10/24" `
  -Gateway "192.168.201.1" `
  -DnsServers "1.1.1.1","8.8.8.8"

.\windows\New-HyperVVmFromGolden.ps1 `
  -VmName $VmName `
  -GoldenVhdxPath $GoldenVhdx `
  -VmRoot "D:\HyperV\VMs" `
  -SwitchName "PanelNAT" `
  -SeedDiskPath $SeedDisk `
  -StaticMacAddress $Mac `
  -StartAfterCreate
```

---

## 14) How to access the new VM

Use the **private key**, not the `.pub` file.

Correct:

```powershell
ssh -i C:\Users\Muhammed-Y520\.ssh\id_ed25519 ubuntuadmin@<VM-IP>
```

Incorrect:

```powershell
ssh -i C:\Users\Muhammed-Y520\.ssh\id_ed25519.pub ubuntuadmin@<VM-IP>
```

The `.pub` file is for **installing** trust, not for authenticating as a client private key.

---

## 15) First-boot verification checklist inside the clone

Once you log in, verify that cloud-init applied what you expected.

Run:

```bash
ip -br a
hostnamectl --static
cloud-init status --long
sudo cloud-init query ds
getent passwd ubuntuadmin
getent passwd rescueadmin
```

### What you should expect

- the hostname should match the seed disk input,
- the datasource should be `NoCloud`,
- the admin user should exist,
- the rescue user should exist if you enabled it,
- the network should match DHCP or static expectations.

You can also check:

```bash
sudo cat /var/log/cloud-init-output.log
```

---

## 16) What to do after the VM boots successfully

This repository intentionally stops at **generic provisioning**.

After first login, you should apply your project-specific setup separately.

Typical next steps include:

- copying or cloning application repositories,
- creating workspace directories,
- installing project runtimes or dependencies,
- configuring environment files,
- enabling services,
- running app bootstrap or migration commands.

That separation is intentional. It keeps the golden image reusable across multiple projects.

---

## 17) Common mistakes and how to avoid them

## Mistake 1 — Using different MAC values

Symptom: cloud-init networking does not apply as expected.

Fix: use the exact same MAC in seed creation and VM creation.

## Mistake 2 — Using the public key file with `ssh -i`

Symptom: SSH authentication fails even though the key seems correct.

Fix: use the **private** key file with `ssh -i`.

## Mistake 3 — Supplying only one static networking value

Symptom: the seed script throws an error.

Fix: when using static networking, provide both `-StaticIpCidr` and `-Gateway`.

## Mistake 4 — Expecting `-InterfaceName` to rename the interface today

Symptom: generated config still says `lan0`.

Fix: edit the templates if you want that name to change, because the current templates hardcode `lan0`.

## Mistake 5 — Trying to reuse an existing VM name or VM path

Symptom: the VM creation script stops before creating the VM.

Fix: remove the old VM/path or pick a new name.

## Mistake 6 — Forgetting PowerShell execution policy for the session

Symptom: scripts do not run locally.

Fix:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

---

## 18) Troubleshooting

## VM does not get created

Check:

- whether the golden VHDX path exists,
- whether the seed disk path exists,
- whether the switch name is valid,
- whether the VM name is already taken,
- whether the target VM path already exists.

## VM boots but networking does not come up

Check inside the VM:

```bash
cloud-init status --long
sudo cloud-init query ds
sudo cat /var/log/cloud-init-output.log
ip -br a
```

Then verify:

- the seed disk was attached,
- the MAC matches,
- the selected network template is the one you intended,
- the Hyper-V switch is connected to the right network model.

## SSH access fails

Check:

- you used the private key,
- the correct username,
- the actual VM IP,
- cloud-init finished,
- the public key was read from the expected path.

## Static IP clone is unreachable

Check:

- subnet and gateway correctness,
- DNS server values,
- switch/NAT setup,
- whether the address conflicts with another device.

## Need to inspect the seed disk contents

You can mount the seed disk on Windows and inspect the files:

```powershell
Mount-VHD -Path $SeedDisk -Passthru | Get-Disk | Get-Partition | Get-Volume
Get-Content E:\network-config
Get-Content E:\user-data
Dismount-VHD -Path $SeedDisk
```

Adjust the drive letter if Windows assigns something other than `E:`.

---

## 19) Security and operational notes

This repo is designed around key-based admin access.

### Security defaults worth understanding

- root login is disabled in cloud-init user-data,
- admin access is designed for SSH keys,
- password auth is disabled unless you intentionally enable rescue SSH password authentication,
- the prepare script disables password authentication in SSH server config for future clones,
- the seal script removes host keys and authorized keys from the image before cloning.

### Practical advice

- do not store sensitive long-term secrets in the golden image,
- treat rescue passwords carefully,
- rotate SSH keys when needed,
- regenerate the golden image periodically after Ubuntu updates.

---

## 20) Recommended operator workflow

For best results, use this workflow every time:

1. Keep one clean Ubuntu source VM.
2. Prepare it with `prepare-current-image-for-golden.sh`.
3. Validate with `golden-image-check`.
4. Seal it with `seal-golden-image.sh`.
5. Store the powered-off VHDX as the golden image.
6. For each new VM, generate a fresh seed disk.
7. Create a new VM from the golden VHDX.
8. Start it and verify cloud-init.
9. Apply project-specific bootstrap only after login.

This pattern is simple, reliable, and easy to repeat.

---

## 21) Minimal quick checklist

```text
[ ] Prepare the Ubuntu VM
[ ] Validate cloud-init, SSH, and netplan
[ ] Seal the image
[ ] Power off and save the VHDX as golden
[ ] Pick a VM name and MAC
[ ] Create a seed disk with the same MAC
[ ] Create the VM from the golden VHDX using the same MAC
[ ] Start the VM
[ ] SSH in using the private key
[ ] Verify cloud-init and network
[ ] Run your project bootstrap
```

---

## 22) Suggested future cleanup or enhancement ideas

These are not required for using the current repo, but they would make the project even clearer:

- update the network templates to actually use `__INTERFACE_NAME__`,
- add a sample custom `NetworkConfigPath` file,
- add a validation script for rendered seed content before VHDX creation,
- add a small wrapper launcher for common operator prompts,
- add a table of tested Ubuntu versions and Hyper-V host versions.

---

## 23) Summary

This project is a focused, reusable Hyper-V golden image workflow.

Its strength is that it does **one job well**:

- prepare a generic Ubuntu base,
- seal it properly,
- render clone identity with cloud-init NoCloud,
- create new Hyper-V VMs from that base in a predictable way.

If you keep the golden image generic, keep the seed disk clone-specific, and always match the MAC across both steps, the workflow stays clean and repeatable.
