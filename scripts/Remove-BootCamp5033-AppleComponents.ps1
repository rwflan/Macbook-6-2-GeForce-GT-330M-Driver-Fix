[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$BackupPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDir = Split-Path -Parent $PSScriptRoot
$currentBackupDir = Join-Path $baseDir ("backup-" + (Get-Date -Format "yyyyMMdd-HHmmss") + "-bootcamp5033-rollback")
$bootCampRegPath = "HKLM:\SOFTWARE\Apple Inc.\Boot Camp"
$bootCampExe = "C:\Program Files\Boot Camp\Bootcamp.exe"
$appleOssMgrExe = "C:\Windows\System32\AppleOSSMgr.exe"
$keyAgentServiceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\KeyAgent"
$backupStateFileName = "AppleDrivers-before.json"
$backupFileNames = @(
    "Bootcamp.exe",
    "AppleOSSMgr.exe",
    "KeyMagic.sys",
    "MacHalDriver.sys"
)
$driverRestoreTargets = @{
    "Bootcamp.exe" = $bootCampExe
    "AppleOSSMgr.exe" = $appleOssMgrExe
    "KeyMagic.sys" = "C:\Windows\System32\drivers\KeyMagic.sys"
    "MacHalDriver.sys" = "C:\Windows\System32\drivers\MacHalDriver.sys"
}

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

    $latest = Get-ChildItem -LiteralPath $baseDir -Directory |
        Where-Object {
            ($_.Name -like "backup-*-applecomponents" -or $_.Name -like "backup-*-bootcamp5033*") -and
            ($_.Name -notlike "*-rollback")
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "No Apple component backup directory was found under $baseDir"
    }

    return $latest.FullName
}

function Save-CurrentState {
    param([string]$ResolvedBackup)

    New-Item -ItemType Directory -Path $currentBackupDir -Force | Out-Null

    $state = [ordered]@{
        Timestamp = (Get-Date).ToString("o")
        SourceBackup = $ResolvedBackup
        Files = @{}
        CurrentAppleDrivers = @()
        BootCampRegistry = @{}
    }

    foreach ($destinationPath in $driverRestoreTargets.Values + "C:\Windows\System32\drivers\KeyAgent.sys" + "C:\Windows\System32\drivers\AppleBtBc.sys") {
        if (Test-Path -LiteralPath $destinationPath) {
            $item = Get-Item -LiteralPath $destinationPath
            Copy-Item -LiteralPath $destinationPath -Destination (Join-Path $currentBackupDir $item.Name) -Force
            $state.Files[$item.Name] = @{
                OriginalPath = $item.FullName
                Version = $item.VersionInfo.FileVersion
                LastWriteTime = $item.LastWriteTime.ToString("o")
            }
        }
    }

    $state.CurrentAppleDrivers = Get-CimInstance Win32_PnPSignedDriver |
        Where-Object { $_.DriverProviderName -eq "Apple Inc." } |
        Select-Object DeviceName, DriverVersion, DriverDate, InfName, DriverProviderName, Manufacturer

    if (Test-Path $bootCampRegPath) {
        $item = Get-ItemProperty -Path $bootCampRegPath
        foreach ($property in $item.PSObject.Properties) {
            if ($property.Name -notmatch '^PS') {
                $state.BootCampRegistry[$property.Name] = $property.Value
            }
        }
        reg export "HKLM\SOFTWARE\Apple Inc.\Boot Camp" (Join-Path $currentBackupDir "BootCamp.reg") /y | Out-Null
    }

    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $currentBackupDir "state-before.json")
}

function Disable-ServiceIfPresent {
    param([Parameter(Mandatory = $true)][string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        return
    }

    if ($PSCmdlet.ShouldProcess($Name, "disable service")) {
        sc.exe config $Name start= disabled | Out-Null
        if ($service.Status -ne "Stopped") {
            sc.exe stop $Name | Out-Null
        }
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath $($ArgumentList -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Queue-FileRestoreOnReboot {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $stagedSource = Join-Path $currentBackupDir ("queued-" + [IO.Path]::GetFileName($DestinationPath))
    Copy-Item -LiteralPath $SourcePath -Destination $stagedSource -Force

    if (-not ("BootCampRollback.NativeMethods" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace BootCampRollback
{
    public static class NativeMethods
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);
    }
}
"@
    }

    $flags = 0x1 -bor 0x4
    $queued = [BootCampRollback.NativeMethods]::MoveFileEx($stagedSource, $DestinationPath, $flags)
    if (-not $queued) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Failed to queue $DestinationPath for replacement at reboot. Win32 error: $errorCode"
    }
}

function Restore-BackedUpFiles {
    param([string]$ResolvedBackup)

    foreach ($fileName in $backupFileNames) {
        $sourcePath = Join-Path $ResolvedBackup $fileName
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            continue
        }

        $destinationPath = $driverRestoreTargets[$fileName]
        $destinationDir = Split-Path -Parent $destinationPath
        if ($PSCmdlet.ShouldProcess($destinationPath, "restore $fileName from backup")) {
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
            try {
                Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
            }
            catch [System.IO.IOException] {
                Write-Warning "$destinationPath is locked. Queueing restore for the next reboot."
                Queue-FileRestoreOnReboot -SourcePath $sourcePath -DestinationPath $destinationPath
            }
        }
    }
}

function Import-BackupRegistry {
    param([string]$ResolvedBackup)

    $regPath = Join-Path $ResolvedBackup "BootCamp.reg"
    if ((Test-Path -LiteralPath $regPath) -and $PSCmdlet.ShouldProcess($bootCampRegPath, "restore Boot Camp registry")) {
        Invoke-Native -FilePath "reg.exe" -ArgumentList @("import", $regPath)
    }
}

function Get-RollbackPlans {
    param([string]$ResolvedBackup)

    $backupStateFile = Join-Path $ResolvedBackup $backupStateFileName
    if (-not (Test-Path -LiteralPath $backupStateFile)) {
        Write-Warning "Backup driver manifest not found: $backupStateFile"
        return @()
    }

    $backupDrivers = @(Get-Content -LiteralPath $backupStateFile -Raw | ConvertFrom-Json)
    $currentDrivers = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DriverProviderName -eq "Apple Inc." })

    $plans = foreach ($savedDriver in $backupDrivers) {
        $currentDriver = $currentDrivers | Where-Object { $_.DeviceName -eq $savedDriver.DeviceName } | Select-Object -First 1
        if (-not $currentDriver) {
            continue
        }

        if (($currentDriver.InfName -ne $savedDriver.InfName) -or ($currentDriver.DriverVersion -ne $savedDriver.DriverVersion)) {
            [pscustomobject]@{
                DeviceName = $savedDriver.DeviceName
                CurrentInf = $currentDriver.InfName
                CurrentVersion = $currentDriver.DriverVersion
                FallbackInf = $savedDriver.InfName
                FallbackVersion = $savedDriver.DriverVersion
            }
        }
    }

    return @($plans)
}

function Get-FallbackRollbackPlans {
    $computerModel = $null
    try {
        $computerModel = (Get-CimInstance Win32_ComputerSystem).Model
    }
    catch {
        $computerModel = $null
    }

    if ($computerModel -ne "MacBookPro6,2") {
        return @()
    }

    return @(
        [pscustomobject]@{ DeviceName = "Apple panel backlight"; CurrentInf = "oem56.inf"; CurrentVersion = "5.0.0.0"; FallbackInf = "oem27.inf"; FallbackVersion = "3.2.0.8" },
        [pscustomobject]@{ DeviceName = "Apple graphics mux"; CurrentInf = "oem56.inf"; CurrentVersion = "5.0.0.0"; FallbackInf = "oem27.inf"; FallbackVersion = "3.2.0.8" },
        [pscustomobject]@{ DeviceName = "Apple SMC device"; CurrentInf = "oem56.inf"; CurrentVersion = "5.0.0.0"; FallbackInf = "oem27.inf"; FallbackVersion = "3.2.0.8" },
        [pscustomobject]@{ DeviceName = "Apple Built-in iSight"; CurrentInf = "oem56.inf"; CurrentVersion = "5.0.0.0"; FallbackInf = "oem27.inf"; FallbackVersion = "3.2.0.8" },
        [pscustomobject]@{ DeviceName = "Apple Multitouch Mouse"; CurrentInf = "oem59.inf"; CurrentVersion = "4.0.3.0"; FallbackInf = "oem37.inf"; FallbackVersion = "4.0.0.1" },
        [pscustomobject]@{ DeviceName = "Apple Multitouch"; CurrentInf = "oem60.inf"; CurrentVersion = "4.0.3.0"; FallbackInf = "oem38.inf"; FallbackVersion = "4.0.0.1" },
        [pscustomobject]@{ DeviceName = "Apple Keyboard"; CurrentInf = "oem15.inf"; CurrentVersion = "5.0.3.0"; FallbackInf = "oem22.inf"; FallbackVersion = "4.0.0.1" },
        [pscustomobject]@{ DeviceName = "Apple Broadcom Built-in Bluetooth"; CurrentInf = "oem63.inf"; CurrentVersion = "5.0.1.0"; FallbackInf = "oem44.inf"; FallbackVersion = "3.2.0.1" }
    )
}

function Remove-NewAppleDriverPackages {
    param([object[]]$RollbackPlans)

    $packagesToRemove = $RollbackPlans |
        Group-Object CurrentInf |
        ForEach-Object { $_.Group | Select-Object -First 1 } |
        Sort-Object CurrentInf

    foreach ($package in $packagesToRemove) {
        $fallbackPath = Join-Path $env:WINDIR ("INF\" + $package.FallbackInf)
        $currentPath = Join-Path $env:WINDIR ("INF\" + $package.CurrentInf)
        if (-not (Test-Path -LiteralPath $fallbackPath)) {
            Write-Warning "Skipping $($package.CurrentInf) because fallback package $($package.FallbackInf) is missing."
            continue
        }
        if (-not (Test-Path -LiteralPath $currentPath)) {
            Write-Warning "Skipping $($package.CurrentInf) because it is no longer installed."
            continue
        }

        if ($PSCmdlet.ShouldProcess($package.CurrentInf, "remove newer Apple driver package and fall back to $($package.FallbackInf)")) {
            Invoke-Native -FilePath "pnputil.exe" -ArgumentList @("/delete-driver", $package.CurrentInf, "/uninstall", "/force")
        }
    }
}

Assert-Administrator
$resolvedBackup = Resolve-BackupPath -RequestedPath $BackupPath
Save-CurrentState -ResolvedBackup $resolvedBackup

if ($PSCmdlet.ShouldProcess("Boot Camp tray", "stop Boot Camp process")) {
    Get-Process -Name Bootcamp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

Disable-ServiceIfPresent -Name "KeyAgent"

$rollbackPlans = @(Get-RollbackPlans -ResolvedBackup $resolvedBackup)
if ($rollbackPlans.Count -gt 0) {
    Remove-NewAppleDriverPackages -RollbackPlans $rollbackPlans
}
else {
    $rollbackPlans = @(Get-FallbackRollbackPlans)
    if ($rollbackPlans.Count -gt 0) {
        Write-Warning "Falling back to the known MacBookPro6,2 rollback package map."
        Remove-NewAppleDriverPackages -RollbackPlans $rollbackPlans
    }
    else {
        Write-Warning "No Apple driver package deltas were detected from the backup manifest."
    }
}

Restore-BackedUpFiles -ResolvedBackup $resolvedBackup
Import-BackupRegistry -ResolvedBackup $resolvedBackup

if ((Test-Path -LiteralPath $keyAgentServiceKey) -and $PSCmdlet.ShouldProcess($keyAgentServiceKey, "keep KeyAgent disabled")) {
    Set-ItemProperty -Path $keyAgentServiceKey -Name "Start" -Type DWord -Value 4
}

if ($PSCmdlet.ShouldProcess("Plug and Play", "rescan devices")) {
    Invoke-Native -FilePath "pnputil.exe" -ArgumentList @("/scan-devices")
}

Write-Host "Rollback completed."
Write-Host "Applied backup: $resolvedBackup"
Write-Host "Current state backup: $currentBackupDir"
Write-Host "Reboot Windows normally and verify that the 0x10d boot crash no longer occurs."
