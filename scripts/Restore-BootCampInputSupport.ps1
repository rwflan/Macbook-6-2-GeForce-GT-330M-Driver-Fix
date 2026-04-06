[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SourceBackupPath,
    [string]$KeyboardInstallerPath,
    [string]$BootCampArchivePath = "C:\Temp\BootCamp5.0.5033.zip",
    [string]$BootCampExtractPath = "C:\Temp\BootCamp5.0.5033"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDir = Split-Path -Parent $PSScriptRoot
$currentBackupDir = Join-Path $baseDir ("backup-" + (Get-Date -Format "yyyyMMdd-HHmmss") + "-bootcamp-input-repair")
$bootCampExe = "C:\Program Files\Boot Camp\Bootcamp.exe"
$appleOssMgrExe = "C:\Windows\System32\AppleOSSMgr.exe"
$bootCampVersionsKey = "HKLM:\SOFTWARE\Apple Inc.\Boot Camp\Versions"
$keyAgentServiceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\KeyAgent"
$appleKeyboardHardwareId = "USB\VID_05AC&PID_0237&MI_00"
$appleKeyboardTargetVersion = "5.0.3.0"
$repairTargets = @(
    @{ FileName = "Bootcamp.exe"; Destination = $bootCampExe },
    @{ FileName = "AppleOSSMgr.exe"; Destination = $appleOssMgrExe },
    @{ FileName = "KeyAgent.sys"; Destination = "C:\Windows\System32\drivers\KeyAgent.sys" }
)
$queuedRestores = New-Object System.Collections.Generic.List[string]

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

    $candidates = Get-ChildItem -LiteralPath $baseDir -Directory |
        Where-Object { $_.Name -like "backup-*-bootcamp5033-rollback" } |
        Sort-Object LastWriteTime -Descending

    foreach ($candidate in $candidates) {
        $bootCampPath = Join-Path $candidate.FullName "Bootcamp.exe"
        $keyAgentPath = Join-Path $candidate.FullName "KeyAgent.sys"

        if ((Test-Path -LiteralPath $bootCampPath) -and (Test-Path -LiteralPath $keyAgentPath)) {
            $bootCampVersion = (Get-Item -LiteralPath $bootCampPath).VersionInfo.FileVersion
            if ($bootCampVersion -eq "5.0.1.0") {
                return $candidate.FullName
            }
        }
    }

    throw "Unable to find a rollback backup containing the Boot Camp 5 keyboard/runtime files."
}

function Resolve-KeyboardInstaller {
    param([string]$RequestedPath)

    $defaultInstallerPath = Join-Path $BootCampExtractPath "BootCamp\Drivers\Apple\AppleKeyboardInstaller64.exe"
    $candidatePath = if ($RequestedPath) { $RequestedPath } else { $defaultInstallerPath }

    if (-not (Test-Path -LiteralPath $candidatePath)) {
        if (-not (Test-Path -LiteralPath $BootCampArchivePath)) {
            throw "Apple keyboard installer not found at '$candidatePath', and Boot Camp archive not found at '$BootCampArchivePath'."
        }

        if ($PSCmdlet.ShouldProcess($BootCampExtractPath, "extract Boot Camp 5.0.5033 to recover the keyboard installer")) {
            if (Test-Path -LiteralPath $BootCampExtractPath) {
                Remove-Item -LiteralPath $BootCampExtractPath -Recurse -Force
            }

            Expand-Archive -LiteralPath $BootCampArchivePath -DestinationPath $BootCampExtractPath -Force
        }
    }

    if (-not (Test-Path -LiteralPath $candidatePath)) {
        throw "Apple keyboard installer not found: $candidatePath"
    }

    return (Resolve-Path -LiteralPath $candidatePath).Path
}

function Get-AppleKeyboardDriver {
    Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.DeviceID -like "$appleKeyboardHardwareId*") -and
            ($_.DeviceName -eq "Apple Keyboard")
        } |
        Select-Object -First 1
}

function Get-AppleKeyboardDevice {
    Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -like "$appleKeyboardHardwareId*" } |
        Select-Object -First 1
}

function Wait-ForAppleKeyboardReady {
    param([int]$TimeoutSeconds = 120)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $driver = Get-AppleKeyboardDriver
        $device = Get-AppleKeyboardDevice

        if ($driver -and $device -and $driver.IsSigned -and ($driver.DriverVersion -eq $appleKeyboardTargetVersion) -and ($device.ConfigManagerErrorCode -eq 0)) {
            return $driver
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    $driverSummary = $driver | Select-Object DeviceName, DriverVersion, InfName, IsSigned | Format-List | Out-String
    $deviceSummary = $device | Select-Object Name, Status, ConfigManagerErrorCode, PNPDeviceID | Format-List | Out-String
    throw "Timed out waiting for the Apple keyboard driver to become healthy.`nDriver:`n$driverSummary`nDevice:`n$deviceSummary"
}

function Save-CurrentState {
    New-Item -ItemType Directory -Path $currentBackupDir -Force | Out-Null

    $state = [ordered]@{
        Timestamp = (Get-Date).ToString("o")
        Files = @{}
        Services = @{}
        BootCampVersions = @{}
        AppleKeyboardDriver = @{}
    }

    foreach ($target in $repairTargets) {
        if (-not (Test-Path -LiteralPath $target.Destination)) {
            continue
        }

        $item = Get-Item -LiteralPath $target.Destination
        Copy-Item -LiteralPath $target.Destination -Destination (Join-Path $currentBackupDir $item.Name) -Force
        $state.Files[$item.Name] = @{
            OriginalPath = $item.FullName
            Version = $item.VersionInfo.FileVersion
            LastWriteTime = $item.LastWriteTime.ToString("o")
        }
    }

    foreach ($serviceName in "AppleOSSMgr", "KeyAgent", "KeyMagic") {
        $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
        if ($service) {
            $state.Services[$serviceName] = @{
                StartMode = $service.StartMode
                State = $service.State
                PathName = $service.PathName
            }
        }
    }

    if (Test-Path -LiteralPath $bootCampVersionsKey) {
        $versions = Get-ItemProperty -Path $bootCampVersionsKey -ErrorAction SilentlyContinue
        foreach ($propertyName in "KeyMagic", "Multitouch", "MultitouchMouse") {
            if ($null -ne $versions.PSObject.Properties[$propertyName]) {
                $state.BootCampVersions[$propertyName] = $versions.$propertyName
            }
        }
    }

    $appleKeyboardDriver = Get-AppleKeyboardDriver
    if ($appleKeyboardDriver) {
        $state.AppleKeyboardDriver = @{
            DeviceId = $appleKeyboardDriver.DeviceID
            DriverVersion = $appleKeyboardDriver.DriverVersion
            InfName = $appleKeyboardDriver.InfName
            IsSigned = $appleKeyboardDriver.IsSigned
        }
    }

    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $currentBackupDir "state-before.json")
}

function Queue-FileRestoreOnReboot {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $stagedSource = Join-Path $currentBackupDir ("queued-" + [IO.Path]::GetFileName($DestinationPath))
    Copy-Item -LiteralPath $SourcePath -Destination $stagedSource -Force

    if (-not ("BootCampInputRepair.NativeMethods" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace BootCampInputRepair
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
    $queued = [BootCampInputRepair.NativeMethods]::MoveFileEx($stagedSource, $DestinationPath, $flags)
    if (-not $queued) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Failed to queue $DestinationPath for replacement at reboot. Win32 error: $errorCode"
    }

    $queuedRestores.Add($DestinationPath) | Out-Null
}

function Stop-ServiceIfPresent {
    param([Parameter(Mandatory = $true)][string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($service -and ($service.Status -ne "Stopped") -and $PSCmdlet.ShouldProcess($Name, "stop service")) {
        sc.exe stop $Name | Out-Null
    }
}

function Restore-File {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $destinationDir = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null

    if ($PSCmdlet.ShouldProcess($DestinationPath, "restore file")) {
        try {
            Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
        }
        catch [System.IO.IOException] {
            Write-Warning "$DestinationPath is locked. Queueing restore for the next reboot."
            Queue-FileRestoreOnReboot -SourcePath $SourcePath -DestinationPath $DestinationPath
        }
    }
}

function Install-AppleKeyboardPackage {
    param([Parameter(Mandatory = $true)][string]$InstallerPath)

    if ($PSCmdlet.ShouldProcess($InstallerPath, "install the signed Apple keyboard package")) {
        $process = Start-Process -FilePath $InstallerPath -ArgumentList "/S" -PassThru
        $null = $process.WaitForExit(120000)

        if (($null -ne $process.ExitCode) -and ($process.ExitCode -ne 0)) {
            throw "Apple keyboard installer failed with exit code $($process.ExitCode)."
        }

        $driver = Wait-ForAppleKeyboardReady
        Write-Host "Apple keyboard package restored with driver $($driver.InfName) version $($driver.DriverVersion)."
    }
}

Assert-Administrator
$resolvedSourceBackup = Resolve-SourceBackup -RequestedPath $SourceBackupPath
$resolvedKeyboardInstaller = Resolve-KeyboardInstaller -RequestedPath $KeyboardInstallerPath
Save-CurrentState

Get-Process -Name Bootcamp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Stop-ServiceIfPresent -Name "AppleOSSMgr"
Stop-ServiceIfPresent -Name "KeyAgent"

foreach ($target in $repairTargets) {
    $sourcePath = Join-Path $resolvedSourceBackup $target.FileName
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        Write-Warning "Skipping missing source file: $sourcePath"
        continue
    }

    Restore-File -SourcePath $sourcePath -DestinationPath $target.Destination
}

Install-AppleKeyboardPackage -InstallerPath $resolvedKeyboardInstaller

if ((Test-Path -LiteralPath $keyAgentServiceKey) -and $PSCmdlet.ShouldProcess($keyAgentServiceKey, "set KeyAgent start mode to auto")) {
    Set-ItemProperty -Path $keyAgentServiceKey -Name "Start" -Type DWord -Value 2
}

if ($PSCmdlet.ShouldProcess($bootCampVersionsKey, "record the Boot Camp 5 keyboard runtime version")) {
    if (-not (Test-Path -LiteralPath $bootCampVersionsKey)) {
        New-Item -Path $bootCampVersionsKey -Force | Out-Null
    }
    New-ItemProperty -Path $bootCampVersionsKey -Name "KeyMagic" -PropertyType String -Value "5.0.3.0" -Force | Out-Null
}

if ($PSCmdlet.ShouldProcess("Apple OS Switch Manager", "start service")) {
    Start-Service -Name AppleOSSMgr -ErrorAction SilentlyContinue
}

if ($queuedRestores -contains "C:\Windows\System32\drivers\KeyAgent.sys") {
    Write-Warning "Skipping KeyAgent start until the queued driver replacement finishes on the next reboot."
}
elseif ($PSCmdlet.ShouldProcess("KeyAgent", "start service")) {
    sc.exe start KeyAgent | Out-Null
}

if ($PSCmdlet.ShouldProcess($bootCampExe, "restart Boot Camp tray")) {
    Start-Process -FilePath $bootCampExe
}

Write-Host "Restored Boot Camp input support from: $resolvedSourceBackup"
Write-Host "Keyboard installer used: $resolvedKeyboardInstaller"
Write-Host "Current state backup: $currentBackupDir"
if ($queuedRestores.Count -gt 0) {
    Write-Host "A reboot is required to finish replacing locked files:"
    foreach ($path in $queuedRestores) {
        Write-Host " - $path"
    }
}
else {
    Write-Host "No reboot-queued file replacements were needed."
}
