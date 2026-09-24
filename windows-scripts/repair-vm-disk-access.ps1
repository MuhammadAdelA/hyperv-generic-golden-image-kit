[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)][string]$VmName,
    [string]$DiskPath,
    [switch]$Start
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$vm = Get-VM -Name $VmName -ErrorAction Stop
$attachedPaths = @(Get-VMHardDiskDrive -VMName $VmName | Where-Object Path | Select-Object -ExpandProperty Path)
if ($DiskPath) {
    $resolvedDiskPath = [IO.Path]::GetFullPath($DiskPath)
    if ($resolvedDiskPath -notin @($attachedPaths | ForEach-Object { [IO.Path]::GetFullPath($_) })) {
        throw "The disk is not attached to VM '$VmName': $resolvedDiskPath"
    }
    $targets = @($resolvedDiskPath)
}
else { $targets = @($attachedPaths) }

if ($targets.Count -eq 0) { throw "VM '$VmName' has no attached virtual hard disks." }
$identity = "NT VIRTUAL MACHINE\$($vm.VMId)"

foreach ($target in $targets) {
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Attached disk not found: $target" }
    if ($PSCmdlet.ShouldProcess($target, "Grant Full Control to $identity")) {
        $output = & icacls.exe $target /grant "${identity}:(F)" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "icacls failed for '$target': $($output -join ' ')" }
        Write-Host "Access repaired: $target" -ForegroundColor Green
    }
}

if ($Start) {
    if ($WhatIfPreference) { Write-Host "What if: Start VM '$VmName'" }
    else { Start-VM -Name $VmName; Write-Host "VM started: $VmName" -ForegroundColor Green }
}
