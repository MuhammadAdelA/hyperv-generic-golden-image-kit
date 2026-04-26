# DHCP Example.
# Copy it to New-GoldenVmInteractive.config.psd1 and don't forget to modify it.

@{
    RepoRoot = ''
    DeviceName = 'vm-dhcp-01'
    Hostname = 'vm-dhcp-01'
    AdminUser = 'ubuntu'
    SshPublicKeyPath = 'C:\Users\YourUser\.ssh\id_ed25519.pub'
    MacAddress = ''

    GoldenVhdxPath = 'D:\HyperV\Golden\ubuntu-24.04-golden-base.vhdx'
    VmRoot = 'D:\HyperV\VMs'
    SeedRoot = 'D:\HyperV\Seeds'
    SeedDiskPath = ''
    SwitchName = 'Default Switch'
    SeedOnly = $false

    UseStatic = $false
    StaticIpCidr = ''
    IpPrefix = ''
    IpOctet = 0
    Gateway = ''
    DnsServers = @()
    InterfaceName = 'eth0'

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
