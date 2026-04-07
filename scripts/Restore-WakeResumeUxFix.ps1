[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SourceBackupPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDir = Split-Path -Parent $PSScriptRoot
$personalizationPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
$systemPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell session."
    }
}

function Resolve-SourceBackup {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath $RequestedPath)) {
            throw "Source backup path not found: $RequestedPath"
        }

        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $candidate = Get-ChildItem -LiteralPath $baseDir -Directory |
        Where-Object { $_.Name -like "backup-*-wake-resume-ux" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $candidate) {
        throw "Unable to find a wake-resume UX backup directory."
    }

    return $candidate.FullName
}

function Restore-RegistryValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$SavedState
    )

    if ($SavedState.Exists) {
        if ($PSCmdlet.ShouldProcess($Path, "restore $Name")) {
            New-Item -Path $Path -Force | Out-Null
            New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value ([int]$SavedState.Value) -Force | Out-Null
        }
    }
    elseif ($PSCmdlet.ShouldProcess($Path, "remove $Name")) {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    }
}

Assert-Administrator
$resolvedSourceBackup = Resolve-SourceBackup -RequestedPath $SourceBackupPath
$statePath = Join-Path $resolvedSourceBackup "state-before.json"

if (-not (Test-Path -LiteralPath $statePath)) {
    throw "Backup state file not found: $statePath"
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable

Restore-RegistryValue -Path $personalizationPolicyKey -Name "NoLockScreen" -SavedState $state.Policies.NoLockScreen
Restore-RegistryValue -Path $systemPolicyKey -Name "DisableAcrylicBackgroundOnLogon" -SavedState $state.Policies.DisableAcrylicBackgroundOnLogon

Write-Host "Restored the previous wake-resume UX settings from: $resolvedSourceBackup"
