# Static IP example.
# Copy this file to New-GoldenVmInteractive.config.psd1, then adjust it for your environment.

@{
    RepoRoot = ''
    DeviceName = 'vm-static-01'
    Hostname = 'vm-static-01'
    AdminUser = 'ubuntu'
    SshPublicKeyPath = 'C:\Users\YourUser\.ssh\id_ed25519.pub'
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
    IpOctet = 25
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
