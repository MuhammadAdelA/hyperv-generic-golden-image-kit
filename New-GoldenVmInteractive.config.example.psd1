# New-GoldenVmInteractive.config.psd1
# Copy this file to: New-GoldenVmInteractive.config.psd1
# Then fill in the values for your environment once.
# After that, you can run automation with:
#   .\New-GoldenVmInteractive.ps1 -Auto
#
# Runtime priority:
#   1) Values passed from the CLI
#   2) Values defined in this config file
#   3) Safe built-in script defaults, such as RAM/CPU/DHCP
#
# Important note:
#   A psd1 file does not expand variables such as $HOME or $env:USERPROFILE inside strings.
#   Use full paths, or use ~ only if you have tested it on your Windows machine.

@{
    # RepoRoot:
    # Path to the project folder that contains the windows and cloud-init folders.
    # Leave it empty if this config file is next to New-GoldenVmInteractive.ps1 in the same project.
    # Example: 'C:\Tools\hyperv-generic-golden-image'
    RepoRoot = ''

    # DeviceName:
    # Hyper-V VM name. It must be unique and not already used by another VM.
    # Example: 'vm-prod-01'
    DeviceName = ''

    # Hostname:
    # Hostname inside Ubuntu. Usually this should match DeviceName.
    # Example: 'vm-prod-01'
    Hostname = ''

    # AdminUser:
    # Main user account to create inside Ubuntu.
    # Common Ubuntu value: 'ubuntu'
    AdminUser = 'ubuntu'

    # SshPublicKeyPath:
    # Path to the public SSH key file on the Windows host.
    # This must point to a .pub file, not the private key.
    # Correct: 'C:\Users\YourUser\.ssh\id_ed25519.pub'
    # Wrong:   '$HOME\.ssh\id_ed25519.pub' because psd1 reads it as a literal string.
    SshPublicKeyPath = ''

    # MacAddress:
    # Leave it empty to let the script generate a new MAC address for each VM.
    # Set a fixed value only if you need DHCP reservation or a mapping tied to a specific MAC.
    # Example: '00-15-5D-32-10-01'
    MacAddress = ''

    # GoldenVhdxPath:
    # Path to the golden image VHDX file.
    # This is the clean base disk that will be copied for each new VM.
    # Example: 'D:\HyperV\Golden\ubuntu-24.04-golden-base.vhdx'
    GoldenVhdxPath = ''

    # VmRoot:
    # Folder where generated VM files will be stored.
    # The script will create a subfolder under it using the VM name.
    # Example: 'D:\HyperV\VMs'
    VmRoot = ''

    # SeedRoot:
    # Folder where cloud-init seed disks will be stored.
    # Example: 'D:\HyperV\Seeds'
    SeedRoot = ''

    # SeedDiskPath:
    # Leave it empty to let the script build it automatically as:
    #   <SeedRoot>\<DeviceName>-seed.vhdx
    # Use it only when you want a custom path for the seed disk.
    # Example: 'D:\HyperV\Seeds\vm-prod-01-seed.vhdx'
    SeedDiskPath = ''

    # SwitchName:
    # Name of an existing Hyper-V Virtual Switch on the host.
    # List available switches with:
    #   Get-VMSwitch | Select-Object Name, SwitchType
    # Example: 'Default Switch' or 'PanelNAT'
    SwitchName = ''

    # SeedOnly:
    # $false = create the seed disk and then create the full VM.
    # $true  = create/update the seed disk only, without creating the VM.
    SeedOnly = $false

    # UseStatic:
    # $false = DHCP, which is the safest general default for automation.
    # $true  = Static IP. In this case, you must fill StaticIpCidr or IpPrefix/IpOctet + Gateway + DnsServers.
    UseStatic = $false

    # StaticIpCidr:
    # Optional. Use this when you want to provide the full IP address with CIDR.
    # When set, the script ignores IpPrefix and IpOctet.
    # Example: '192.168.201.25/24'
    # Leave it empty if you want to use IpPrefix + IpOctet.
    StaticIpCidr = ''

    # IpPrefix:
    # First three octets of the IP address when using Static mode without StaticIpCidr.
    # Do not put /24 here, and do not put the last octet here.
    # Correct: '192.168.200'
    # Wrong:   '24'
    # Wrong:   '192.168.200.'
    IpPrefix = ''

    # IpOctet:
    # Last IP address octet when using IpPrefix.
    # Must be between 1 and 254.
    # Example: IpPrefix='192.168.200' and IpOctet=10 produce: 192.168.200.10/24
    # Leave it as 0 when using DHCP or StaticIpCidr.
    IpOctet = 0

    # Gateway:
    # Network gateway when using Static IP.
    # Example: '192.168.200.1'
    # Leave it empty when using DHCP.
    Gateway = ''

    # DnsServers:
    # DNS server list when using Static IP.
    # Example: @('1.1.1.1', '8.8.8.8')
    # Leave it empty when using DHCP.
    DnsServers = @()

    # InterfaceName:
    # Interface name used inside the cloud-init network-config.
    # In this project, the intended default is lan0 because matching is done by MAC address.
    # Change it only if your cloud-init template uses another name, such as eth0.
    InterfaceName = 'lan0'

    # EnableRescueUser:
    # $true = create an additional rescue user for emergency access.
    # $false = do not create a rescue user.
    EnableRescueUser = $true

    # RescueUser:
    # Emergency user name inside Ubuntu.
    # Used only when EnableRescueUser = $true.
    RescueUser = 'rescue'

    # RescueSshPublicKeyPath:
    # Leave it empty to reuse the same SSH key as AdminUser.
    # Set a different .pub path if you want a separate emergency-access key.
    # Example: 'C:\Users\YourUser\.ssh\rescue_ed25519.pub'
    RescueSshPublicKeyPath = ''

    # Password:
    # Optional rescue user password.
    # For production, it is better to leave it empty and use SSH key authentication only.
    # If EnableRescueSshPassword=$true and Password is empty, the script will generate a password and write it to the rescue summary file.
    # If you type a password manually, it will not be written in plain text to the rescue summary file.
    Password = ''

    # EnableRescueSshPassword:
    # $false = disable SSH login by password. Login will require an SSH key.
    # $true  = allow rescue SSH login by password. Use this only for emergency access.
    EnableRescueSshPassword = $false

    # SetRescuePassword:
    # $false = do not set a rescue password unless EnableRescueSshPassword=$true or Password is not empty.
    # $true  = set a rescue user password even when SSH password login is disabled, for console access for example.
    SetRescuePassword = $false

    # MemoryStartupGb:
    # Initial VM RAM in GB.
    MemoryStartupGb = 4

    # MinimumMemoryGb:
    # Minimum RAM for Dynamic Memory. It must not be greater than MemoryStartupGb.
    MinimumMemoryGb = 2

    # MaximumMemoryGb:
    # Maximum RAM for Dynamic Memory. It must not be less than MemoryStartupGb.
    MaximumMemoryGb = 8

    # ProcessorCount:
    # Number of vCPUs assigned to the VM.
    ProcessorCount = 2

    # SeedControllerLocation:
    # Seed disk location number on the Hyper-V SCSI controller.
    # Usually leave it as 1. Change it only if there is a disk location conflict.
    SeedControllerLocation = 1

    # StartAfterCreate:
    # $true = start the VM immediately after creation.
    # $false = create the VM and leave it powered off.
    StartAfterCreate = $true
}
