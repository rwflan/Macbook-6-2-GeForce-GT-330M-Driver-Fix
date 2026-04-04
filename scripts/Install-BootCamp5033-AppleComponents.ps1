[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$DownloadUrl = "https://download.info.apple.com/Mac_OS_X/041-9675.20130314.f8Ji7/BootCamp5.0.5033.zip",
    [string]$ArchivePath = "C:\Temp\BootCamp5.0.5033.zip",
    [string]$ExtractPath = "C:\Temp\BootCamp5.0.5033"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDir = Split-Path -Parent $PSScriptRoot
$backupDir = Join-Path $baseDir ("backup-" + (Get-Date -Format "yyyyMMdd-HHmmss") + "-bootcamp5033")
$bootCampRegPath = "HKLM:\SOFTWARE\Apple Inc.\Boot Camp"
$runOnceKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
$sessionPowerKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
$bootCampExe = "C:\Program Files\Boot Camp\Bootcamp.exe"
$appleOssMgrExe = "C:\Windows\System32\AppleOSSMgr.exe"
$driverPaths = @(
    "C:\Windows\System32\drivers\KeyMagic.sys",
    "C:\Windows\System32\drivers\KeyAgent.sys",
    "C:\Windows\System32\drivers\MacHalDriver.sys"
)
$msiPath = Join-Path $ExtractPath "BootCamp\Drivers\Apple\BootCamp.msi"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell session."
    }
}

function Save-CurrentState {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $state = [ordered]@{
        Timestamp = (Get-Date).ToString("o")
        DownloadUrl = $DownloadUrl
        Files = @{}
        BootCampRegistry = @{}
        RunOnce = @{}
    }

    foreach ($path in @($bootCampExe, $appleOssMgrExe) + $driverPaths) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path
            $copyTarget = Join-Path $backupDir $item.Name
            Copy-Item -LiteralPath $path -Destination $copyTarget -Force
            $state.Files[$item.Name] = @{
                OriginalPath = $path
                Version = $item.VersionInfo.FileVersion
                LastWriteTime = $item.LastWriteTime.ToString("o")
            }
        }
    }

    if (Test-Path $bootCampRegPath) {
        $item = Get-ItemProperty -Path $bootCampRegPath
        foreach ($property in $item.PSObject.Properties) {
            if ($property.Name -notmatch '^PS') {
                $state.BootCampRegistry[$property.Name] = $property.Value
            }
        }
        reg export "HKLM\SOFTWARE\Apple Inc.\Boot Camp" (Join-Path $backupDir "BootCamp.reg") /y | Out-Null
    }

    if (Test-Path $runOnceKey) {
        $item = Get-ItemProperty -Path $runOnceKey
        foreach ($property in $item.PSObject.Properties) {
            if ($property.Name -notmatch '^PS') {
                $state.RunOnce[$property.Name] = $property.Value
            }
        }
    }

    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backupDir "state-before.json")
}

function Download-Package {
    New-Item -ItemType Directory -Path (Split-Path -Parent $ArchivePath) -Force | Out-Null
    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $ArchivePath
    }
}

function Expand-Package {
    if (Test-Path -LiteralPath $ExtractPath) {
        Remove-Item -LiteralPath $ExtractPath -Recurse -Force
    }
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractPath -Force
    if (-not (Test-Path -LiteralPath $msiPath)) {
        throw "Boot Camp MSI not found after extraction: $msiPath"
    }
}

function Install-BootCampMsi {
    $arguments = @(
        "/i",
        ('"' + $msiPath + '"'),
        "/qn",
        "/norestart"
    )

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Boot Camp MSI install failed with exit code $($process.ExitCode)."
    }
}

Assert-Administrator
Save-CurrentState

if ($PSCmdlet.ShouldProcess($ArchivePath, "download Apple Boot Camp Support Software 5.0.5033")) {
    Download-Package
}

if ($PSCmdlet.ShouldProcess($ExtractPath, "extract Apple Boot Camp Support Software 5.0.5033")) {
    Expand-Package
}

if ($PSCmdlet.ShouldProcess($msiPath, "install Apple Boot Camp 5.0.5033 user-space components")) {
    Install-BootCampMsi
}

if (Get-ItemProperty -Path $runOnceKey -Name "Set_Hibernation" -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess($runOnceKey, "remove queued hibernation enable action")) {
        Remove-ItemProperty -Path $runOnceKey -Name "Set_Hibernation"
    }
}

if ($PSCmdlet.ShouldProcess($sessionPowerKey, "keep hibernation and fast startup disabled")) {
    New-ItemProperty -Path $sessionPowerKey -Name "HiberbootEnabled" -PropertyType DWord -Value 0 -Force | Out-Null
    powercfg /HIBERNATE OFF | Out-Null
}

if ($PSCmdlet.ShouldProcess("Apple OS Switch Manager", "ensure the service is running")) {
    Start-Service -Name AppleOSSMgr -ErrorAction SilentlyContinue
}

if ($PSCmdlet.ShouldProcess($bootCampExe, "restart Boot Camp tray process")) {
    Get-Process -Name Bootcamp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath $bootCampExe
}

Get-Item $bootCampExe, $appleOssMgrExe, "C:\Windows\System32\drivers\KeyAgent.sys", "C:\Windows\System32\drivers\MacHalDriver.sys" -ErrorAction SilentlyContinue |
    Select-Object FullName, @{ Name = "Version"; Expression = { $_.VersionInfo.FileVersion } }, LastWriteTime |
    Format-Table -AutoSize

Write-Host "Installed Apple Boot Camp 5.0.5033 user-space components."
Write-Host "Backup saved to: $backupDir"
Write-Host "Reboot Windows before re-testing local sleep/resume and the function row."
