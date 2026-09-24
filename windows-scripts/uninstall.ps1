[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ApplicationDataPath {
    $localBase = if ($env:LOCALAPPDATA) {
        [IO.Path]::GetFullPath($env:LOCALAPPDATA)
    }
    elseif ($env:USERPROFILE) {
        [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'AppData\Local'))
    }
    else {
        throw 'LOCALAPPDATA and USERPROFILE are unavailable; the uninstall target cannot be resolved safely.'
    }

    $target = [IO.Path]::GetFullPath((Join-Path $localBase 'HyperVGoldenImage'))
    $expectedParent = [IO.Path]::GetFullPath($localBase).TrimEnd('\') + '\'
    if (-not $target.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $target) -ne 'HyperVGoldenImage') {
        throw "Refusing unsafe uninstall target: $target"
    }
    return $target
}

$targetPath = Resolve-ApplicationDataPath

if (-not (Test-Path -LiteralPath $targetPath)) {
    Write-Host "Nothing to uninstall. User settings do not exist: $targetPath" -ForegroundColor Yellow
    return
}

Write-Host 'This removes only the Hyper-V Golden Image user configuration.' -ForegroundColor Yellow
Write-Host 'VMs, VHDX files, virtual switches, NAT, project files, and %USERPROFILE%\HyperVGoldenImage-Data are not affected.'

if ($PSCmdlet.ShouldProcess($targetPath, 'Delete user configuration directory recursively')) {
    Remove-Item -LiteralPath $targetPath -Recurse -Force
    Write-Host "User configuration removed: $targetPath" -ForegroundColor Green
}
