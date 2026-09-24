# DHCP example. The selected switch must already provide DHCP.
# The Windows-managed Default Switch is suitable for simple development VMs,
# but its subnet can change and should not be used when the VM needs a stable IP.

@{
    RepoRoot = ''
    DeviceName = 'vm-dhcp-01'
    Hostname = 'vm-dhcp-01'
    AdminUser = 'ubuntu'
    SshPublicKeyPath = '%USERPROFILE%\.ssh\id_ed25519.pub'
    MacAddress = ''

    GoldenVhdxPath = '' # Auto-detect the first VHDX under the project Golden folder.
    VmRoot = '%USERPROFILE%\HyperVGoldenImage-Data\VMs'
    SeedRoot = '%USERPROFILE%\HyperVGoldenImage-Data\Seeds'
    SeedDiskPath = ''
    SwitchName = 'Default Switch'
    SeedOnly = $false

    NetworkMode = 'Dhcp'
    UseStatic = $false
    StaticIpCidr = ''
    IpPrefix = ''
    IpOctet = 0
    Gateway = ''
    DnsServers = @()
    InterfaceName = 'lan0'

    EnableRescueUser = $true
    RescueUser = 'rescue'
    RescueSshPublicKeyPath = ''
    Password = ''
    EnableRescueSshPassword = $false
    SetRescuePassword = $false

    MemoryStartupGb = 4
    MinimumMemoryGb = 2
    MaximumMemoryGb = 8
    ProcessorCount = 2
    SeedControllerLocation = 1
    StartAfterCreate = $true
}
