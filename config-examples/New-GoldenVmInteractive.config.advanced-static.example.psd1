# Advanced static-IP example for a switch that already exists.
# The script will not create or repair NetNat in Advanced mode. Replace the
# example subnet and switch with values supplied by your LAN/network owner.

@{
    RepoRoot = ''
    DeviceName = 'vm-advanced-01'
    Hostname = 'vm-advanced-01'
    AdminUser = 'ubuntu'
    SshPublicKeyPath = '%USERPROFILE%\.ssh\id_ed25519.pub'
    MacAddress = ''

    GoldenVhdxPath = ''
    VmRoot = '%USERPROFILE%\HyperVGoldenImage-Data\VMs'
    SeedRoot = '%USERPROFILE%\HyperVGoldenImage-Data\Seeds'
    SeedDiskPath = ''
    SwitchName = 'External-LAN' # Must already exist; change this value.
    SeedOnly = $false

    NetworkMode = 'Advanced'
    UseStatic = $true
    StaticIpCidr = '192.168.50.25/24' # Change for the selected LAN.
    IpPrefix = ''
    IpOctet = 0
    Gateway = '192.168.50.1'
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
