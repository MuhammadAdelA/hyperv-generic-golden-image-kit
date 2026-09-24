# Seed-only example. It prepares a NoCloud seed disk without creating a VM.
# No Hyper-V switch or NAT is created in this mode.

@{
    RepoRoot = ''
    DeviceName = 'vm-seed-only-01'
    Hostname = 'vm-seed-only-01'
    AdminUser = 'ubuntu'
    SshPublicKeyPath = '%USERPROFILE%\.ssh\id_ed25519.pub'
    MacAddress = ''

    GoldenVhdxPath = ''
    VmRoot = '%USERPROFILE%\HyperVGoldenImage-Data\VMs'
    SeedRoot = '%USERPROFILE%\HyperVGoldenImage-Data\Seeds'
    SeedDiskPath = ''
    SwitchName = ''
    SeedOnly = $true

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
    StartAfterCreate = $false
}
