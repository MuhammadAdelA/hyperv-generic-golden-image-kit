# Ready-to-create Private NAT with a fixed VM address.
# Run create-vm.ps1 from Administrator PowerShell. During preflight, the tool
# can offer to create the Internal switch, assign 172.29.240.1 to its vEthernet
# adapter, and create NetNat 172.29.240.0/24 after explicit confirmation.
# This example intentionally avoids the common 192.168.0.0/16 Wi-Fi ranges.

@{
    RepoRoot = ''
    DeviceName = 'vm-private-nat-01'
    Hostname = 'vm-private-nat-01'
    AdminUser = 'ubuntu'
    SshPublicKeyPath = '%USERPROFILE%\.ssh\id_ed25519.pub'
    MacAddress = ''

    GoldenVhdxPath = '' # Auto-detect from the project Golden folder.
    VmRoot = '%USERPROFILE%\HyperVGoldenImage-Data\VMs'
    SeedRoot = '%USERPROFILE%\HyperVGoldenImage-Data\Seeds'
    SeedDiskPath = ''
    SwitchName = 'HyperV-NAT'
    SeedOnly = $false

    NetworkMode = 'PrivateNat'
    UseStatic = $true
    StaticIpCidr = '172.29.240.10/24'
    IpPrefix = ''
    IpOctet = 0
    Gateway = '172.29.240.1'
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
