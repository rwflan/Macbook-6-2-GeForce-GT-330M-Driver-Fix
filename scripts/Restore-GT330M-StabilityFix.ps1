[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$BackupPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDir = Split-Path -Parent $PSScriptRoot
$graphicsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell session."
    }
}

function Resolve-BackupPath {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath $RequestedPath)) {
            throw "Backup path not found: $RequestedPath"
        }

        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $latest = Get-ChildItem -LiteralPath $baseDir -Directory -Filter "backup-*" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "No backup-* directory was found under $baseDir"
    }

    return $latest.FullName
}

Assert-Administrator
$resolvedBackup = Resolve-BackupPath -RequestedPath $BackupPath
$stateFile = Join-Path $resolvedBackup "state-before.json"

if (-not (Test-Path -LiteralPath $stateFile)) {
    throw "Missing backup state file: $stateFile"
}

$state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json

if ($state.ActiveSchemeRaw -match "Power Scheme GUID:\s+([a-f0-9-]+)") {
    $schemeGuid = $matches[1]
    if ($PSCmdlet.ShouldProcess("power plan", "restore original active scheme")) {
        powercfg /SETACTIVE $schemeGuid | Out-Null
    }
}

if ($state.PcieAspmRaw -match "Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)") {
    $acAspm = [Convert]::ToInt32($matches[1], 16)
    if ($PSCmdlet.ShouldProcess("power plan", "restore original AC PCIe ASPM value")) {
        powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM $acAspm | Out-Null
    }
}

if ($state.PcieAspmRaw -match "Current DC Power Setting Index:\s+0x([0-9a-fA-F]+)") {
    $dcAspm = [Convert]::ToInt32($matches[1], 16)
    if ($PSCmdlet.ShouldProcess("power plan", "restore original DC PCIe ASPM value")) {
        powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM $dcAspm | Out-Null
    }
}

$expectedNames = "TdrLevel", "TdrDelay", "TdrDdiDelay", "TdrLimitTime", "TdrLimitCount"
$savedValues = @{}
if ($state.GraphicsRegistryValues) {
    foreach ($property in $state.GraphicsRegistryValues.PSObject.Properties) {
        $savedValues[$property.Name] = $property.Value
    }
}

foreach ($name in $expectedNames) {
    if ($savedValues.ContainsKey($name)) {
        if ($PSCmdlet.ShouldProcess($graphicsKey, "restore $name")) {
            New-ItemProperty -Path $graphicsKey -Name $name -PropertyType DWord -Value ([int]$savedValues[$name]) -Force | Out-Null
        }
    }
    elseif (Get-ItemProperty -Path $graphicsKey -Name $name -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($graphicsKey, "remove $name")) {
            Remove-ItemProperty -Path $graphicsKey -Name $name -ErrorAction Stop
        }
    }
}

powercfg /SETACTIVE SCHEME_CURRENT | Out-Null

Write-Host "Restored GT 330M stability settings from: $resolvedBackup"
Write-Host "Reboot Windows to fully return the graphics stack to its prior state."
