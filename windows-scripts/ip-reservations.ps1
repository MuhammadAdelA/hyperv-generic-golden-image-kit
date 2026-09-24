[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('List','Release')][string]$Action = 'List',
    [string]$VmName,
    [string]$IpAddress
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { throw 'USERPROFILE is unavailable.' }
$dataRoot = Join-Path $env:USERPROFILE 'HyperVGoldenImage-Data'
$registryPath = Join-Path $dataRoot 'state\ip-allocations.json'

function Get-Allocations {
    if (-not (Test-Path -LiteralPath $registryPath)) { return @() }
    $content = Get-Content -LiteralPath $registryPath -Raw
    if ([string]::IsNullOrWhiteSpace($content)) { return @() }
    return @(ConvertFrom-Json -InputObject $content)
}

function Enter-AllocationLock {
    $mutex = [System.Threading.Mutex]::new($false, 'Local\HyperVGoldenImage-IpAllocations')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(60)) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Timed out waiting for the static-IP reservation lock.' }
        return $mutex
    }
    catch {
        if (-not $acquired) { $mutex.Dispose() }
        throw
    }
}

$allocations = @(Get-Allocations)
if ($Action -eq 'List') {
    if ($allocations.Count -eq 0) { Write-Host "No static IP reservations exist: $registryPath" -ForegroundColor Yellow; return }
    $allocations | Sort-Object IpAddress | Format-Table VmName, IpAddress, Cidr, SwitchName, ReservedAt -AutoSize
    return
}

if ([string]::IsNullOrWhiteSpace($VmName) -and [string]::IsNullOrWhiteSpace($IpAddress)) { throw 'Release requires -VmName or -IpAddress.' }
$allocationMutex = Enter-AllocationLock
try {
    $allocations = @(Get-Allocations)
    $matches = @($allocations | Where-Object {
        (-not [string]::IsNullOrWhiteSpace($VmName) -and $_.VmName -eq $VmName) -or
        (-not [string]::IsNullOrWhiteSpace($IpAddress) -and $_.IpAddress -eq $IpAddress)
    })
    if ($matches.Count -eq 0) { Write-Host 'No matching reservation was found.' -ForegroundColor Yellow; return }

    $description = ($matches | ForEach-Object { "$($_.IpAddress) -> $($_.VmName)" }) -join ', '
    if ($PSCmdlet.ShouldProcess($description, 'Release static IP reservation')) {
        $remaining = @($allocations | Where-Object { $_ -notin $matches })
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $registryPath -Force
        }
        else {
            $temporaryPath = "$registryPath.tmp.$PID"
            $backupPath = "$registryPath.bak.$PID"
            try {
                [IO.File]::WriteAllText($temporaryPath, (ConvertTo-Json -InputObject $remaining -Depth 4), [Text.UTF8Encoding]::new($false))
                [IO.File]::Replace($temporaryPath, $registryPath, $backupPath, $true)
            }
            finally {
                if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
                if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
            }
        }
        Write-Host "Released: $description" -ForegroundColor Green
    }
}
finally {
    try { $allocationMutex.ReleaseMutex() }
    finally { $allocationMutex.Dispose() }
}
