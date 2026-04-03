[CmdletBinding(SupportsShouldProcess = $true)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDir = Split-Path -Parent $PSScriptRoot
$backupDir = Join-Path $baseDir ("backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
$graphicsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
$graphicsRegPath = "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell session."
    }
}

function Save-CurrentState {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $beforeState = [ordered]@{
        Timestamp = (Get-Date).ToString("o")
        ComputerName = $env:COMPUTERNAME
        ActiveSchemeRaw = (powercfg /GETACTIVESCHEME | Out-String).Trim()
        PcieAspmRaw = (powercfg /Q SCHEME_CURRENT SUB_PCIEXPRESS ASPM | Out-String).Trim()
        GraphicsRegistryValues = @{}
    }

    if (Test-Path $graphicsKey) {
        $item = Get-ItemProperty -Path $graphicsKey
        foreach ($property in "TdrLevel", "TdrDelay", "TdrDdiDelay", "TdrLimitTime", "TdrLimitCount", "HwSchMode") {
            if ($null -ne $item.PSObject.Properties[$property]) {
                $beforeState.GraphicsRegistryValues[$property] = $item.$property
            }
        }
    }

    $beforeState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupDir "state-before.json")
    reg export $graphicsRegPath (Join-Path $backupDir "GraphicsDrivers-before.reg") /y | Out-Null
}

function Set-RegistryDword {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [int]$Value
    )

    New-Item -Path $Path -Force | Out-Null
    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}

Assert-Administrator
Save-CurrentState

if ($PSCmdlet.ShouldProcess("power plan", "switch to High performance and disable PCIe ASPM")) {
    powercfg /SETACTIVE SCHEME_MIN | Out-Null
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0 | Out-Null
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0 | Out-Null
    powercfg /SETACTIVE SCHEME_CURRENT | Out-Null
}

if ($PSCmdlet.ShouldProcess($graphicsKey, "set conservative TDR thresholds")) {
    Set-RegistryDword -Path $graphicsKey -Name "TdrDelay" -Value 10
    Set-RegistryDword -Path $graphicsKey -Name "TdrDdiDelay" -Value 20
    Set-RegistryDword -Path $graphicsKey -Name "TdrLimitTime" -Value 180
    Set-RegistryDword -Path $graphicsKey -Name "TdrLimitCount" -Value 10
}

$afterState = [ordered]@{
    Timestamp = (Get-Date).ToString("o")
    ActiveSchemeRaw = (powercfg /GETACTIVESCHEME | Out-String).Trim()
    PcieAspmRaw = (powercfg /Q SCHEME_CURRENT SUB_PCIEXPRESS ASPM | Out-String).Trim()
    GraphicsRegistryValues = Get-ItemProperty -Path $graphicsKey | Select-Object TdrDelay, TdrDdiDelay, TdrLimitTime, TdrLimitCount
}

$afterState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupDir "state-after.json")

Write-Host "Applied GT 330M stability fix."
Write-Host "Backup saved to: $backupDir"
Write-Host "Reboot Windows before evaluating local-display stability."
