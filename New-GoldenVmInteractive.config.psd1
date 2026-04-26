# Static IP Example.
# Copy it to New-GoldenVmInteractive.config.psd1 and don't forget to modify it.

@{
    RepoRoot = ''
    DeviceName = 'vm-dev-01'
    Hostname = 'vm-dev-01'
    AdminUser = 'ubuntu'
    SshPublicKeyPath = 'C:\Users\Muhammed-Y520\.ssh\id_ed25519.pub'
    MacAddress = ''

    GoldenVhdxPath = 'D:\HyperV\Golden\ubuntu-24.04-golden-base.vhdx'
    VmRoot = 'D:\HyperV\VMs'
    SeedRoot = 'D:\HyperV\Seeds'
    SeedDiskPath = ''
    SwitchName = 'PanelNAT'
    SeedOnly = $false

    UseStatic = $true
    StaticIpCidr = ''
    IpPrefix = '192.168.201'
    IpOctet = 31
    Gateway = '192.168.201.1'
    DnsServers = @('1.1.1.1', '8.8.8.8')
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
