[CmdletBinding(SupportsShouldProcess = $true)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDir = Split-Path -Parent $PSScriptRoot
$backupDir = Join-Path $baseDir ("backup-" + (Get-Date -Format "yyyyMMdd-HHmmss") + "-wake-resume-ux")
$personalizationPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
$systemPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell session."
    }
}

function Get-RegistryValueState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return @{
            Exists = $false
            Value = $null
        }
    }

    return @{
        Exists = $true
        Value = $item.$Name
    }
}

Assert-Administrator

New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

$state = [ordered]@{
    Timestamp = (Get-Date).ToString("o")
    Policies = @{
        NoLockScreen = Get-RegistryValueState -Path $personalizationPolicyKey -Name "NoLockScreen"
        DisableAcrylicBackgroundOnLogon = Get-RegistryValueState -Path $systemPolicyKey -Name "DisableAcrylicBackgroundOnLogon"
    }
}

$state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backupDir "state-before.json")

if ($PSCmdlet.ShouldProcess($personalizationPolicyKey, "disable the lock screen so wake goes directly to sign-in")) {
    New-Item -Path $personalizationPolicyKey -Force | Out-Null
    New-ItemProperty -Path $personalizationPolicyKey -Name "NoLockScreen" -PropertyType DWord -Value 1 -Force | Out-Null
}

if ($PSCmdlet.ShouldProcess($systemPolicyKey, "disable acrylic blur on the sign-in screen")) {
    New-Item -Path $systemPolicyKey -Force | Out-Null
    New-ItemProperty -Path $systemPolicyKey -Name "DisableAcrylicBackgroundOnLogon" -PropertyType DWord -Value 1 -Force | Out-Null
}

Write-Host "Applied the wake-resume UX fix."
Write-Host "Backup saved to: $backupDir"
Write-Host "Windows should now skip the lock screen and go straight to the sign-in screen on the next lock or sleep/resume cycle."
