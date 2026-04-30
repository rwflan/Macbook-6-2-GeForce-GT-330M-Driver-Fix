[CmdletBinding(SupportsShouldProcess = $true)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDir = Split-Path -Parent $PSScriptRoot
$backupDir = Join-Path $baseDir ("backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
$logsDir = Join-Path $baseDir "logs"
$localDumpsDir = Join-Path $logsDir "LocalDumps"
$quarantineDir = Join-Path $backupDir "3dvision-quarantine"
$graphicsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
$graphicsRegPath = "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
$dwmKey = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"
$sessionPowerKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
$personalizeKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
$explorerAdvancedKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
$searchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
$searchSettingsKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"
$widgetsPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
$windowMetricsKey = "HKCU:\Control Panel\Desktop\WindowMetrics"
$runKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$werLocalDumpsKey = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps"
$stereo3DKey = "HKLM:\SOFTWARE\WOW6432Node\NVIDIA Corporation\Global\Stereo3D"
$visionDir = "C:\Program Files (x86)\NVIDIA Corporation\3D Vision"
$nvidiaSmi = "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
$visionFilesToQuarantine = @(
    "nvSCPAPI64.dll",
    "nvSCPAPI.dll",
    "NV3DVisionExt.dll"
)
$nvidiaServiceNames = @(
    "nvsvc",
    "Stereo Service",
    "GfExperienceService",
    "NvNetworkService",
    "NvStreamSvc",
    "NvStreamNetworkSvc"
)
$runValueNames = @("NvBackend", "ShadowPlay")
$nvidiaProcessNames = @(
    "nvtray",
    "nvxdsync",
    "NvBackend",
    "nvsmartmaxapp",
    "nvsmartmaxapp64"
)
$werDumpProcessNames = @(
    "dwm.exe",
    "explorer.exe",
    "SearchHost.exe",
    "SearchApp.exe",
    "ShellExperienceHost.exe",
    "StartMenuExperienceHost.exe"
)
$powerSettings = @(
    @{ Name = "PcieAspm"; Subgroup = "SUB_PCIEXPRESS"; Setting = "ASPM" },
    @{ Name = "VideoIdle"; Subgroup = "SUB_VIDEO"; Setting = "VIDEOIDLE" },
    @{ Name = "StandbyIdle"; Subgroup = "SUB_SLEEP"; Setting = "STANDBYIDLE" },
    @{ Name = "HybridSleep"; Subgroup = "SUB_SLEEP"; Setting = "HYBRIDSLEEP" },
    @{ Name = "HibernateIdle"; Subgroup = "SUB_SLEEP"; Setting = "HIBERNATEIDLE" },
    @{ Name = "RtcWake"; Subgroup = "SUB_SLEEP"; Setting = "RTCWAKE" },
    @{ Name = "LidAction"; Subgroup = "SUB_BUTTONS"; Setting = "LIDACTION" },
    @{ Name = "PowerButtonAction"; Subgroup = "SUB_BUTTONS"; Setting = "PBUTTONACTION" },
    @{ Name = "SleepButtonAction"; Subgroup = "SUB_BUTTONS"; Setting = "SBUTTONACTION" },
    @{ Name = "UiButtonAction"; Subgroup = "SUB_BUTTONS"; Setting = "UIBUTTON_ACTION" }
)

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
        PowerSettings = @{}
        GraphicsRegistryValues = @{}
        DwmRegistryValues = @{}
        SessionPowerValues = @{}
        UserRegistryValues = @{}
        PolicyRegistryValues = @{}
        Stereo3DRegistryValues = @{}
        RunValues = @{}
        ServiceStartModes = @{}
        VisionFiles = @()
    }

    foreach ($setting in $powerSettings) {
        $beforeState.PowerSettings[$setting.Name] = @{
            AC = Get-PowerSettingIndex -Subgroup $setting.Subgroup -Setting $setting.Setting -PowerSource AC
            DC = Get-PowerSettingIndex -Subgroup $setting.Subgroup -Setting $setting.Setting -PowerSource DC
        }
    }

    if (Test-Path $graphicsKey) {
        $item = Get-ItemProperty -Path $graphicsKey
        foreach ($property in "TdrLevel", "TdrDelay", "TdrDdiDelay", "TdrLimitTime", "TdrLimitCount", "HwSchMode") {
            if ($null -ne $item.PSObject.Properties[$property]) {
                $beforeState.GraphicsRegistryValues[$property] = $item.$property
            }
        }
    }

    if (Test-Path $dwmKey) {
        $item = Get-ItemProperty -Path $dwmKey
        foreach ($property in "OverlayTestMode") {
            if ($null -ne $item.PSObject.Properties[$property]) {
                $beforeState.DwmRegistryValues[$property] = $item.$property
            }
        }
    }

    if (Test-Path $sessionPowerKey) {
        $item = Get-ItemProperty -Path $sessionPowerKey
        foreach ($property in "HiberbootEnabled") {
            if ($null -ne $item.PSObject.Properties[$property]) {
                $beforeState.SessionPowerValues[$property] = $item.$property
            }
        }
    }

    $userRegistryTargets = @(
        @{ Bucket = "Personalize"; Path = $personalizeKey; Names = @("EnableTransparency") },
        @{ Bucket = "ExplorerAdvanced"; Path = $explorerAdvancedKey; Names = @("TaskbarAnimations", "TaskbarDa") },
        @{ Bucket = "Search"; Path = $searchKey; Names = @("SearchboxTaskbarMode") },
        @{ Bucket = "SearchSettings"; Path = $searchSettingsKey; Names = @("IsDynamicSearchBoxEnabled") },
        @{ Bucket = "WindowMetrics"; Path = $windowMetricsKey; Names = @("MinAnimate") }
    )

    foreach ($target in $userRegistryTargets) {
        $beforeState.UserRegistryValues[$target.Bucket] = @{}
        if (Test-Path $target.Path) {
            $item = Get-ItemProperty -Path $target.Path
            foreach ($property in $target.Names) {
                if ($null -ne $item.PSObject.Properties[$property]) {
                    $beforeState.UserRegistryValues[$target.Bucket][$property] = $item.$property
                }
            }
        }
    }

    if (Test-Path $widgetsPolicyKey) {
        $beforeState.PolicyRegistryValues["Dsh"] = @{}
        $item = Get-ItemProperty -Path $widgetsPolicyKey
        foreach ($property in "AllowNewsAndInterests") {
            if ($null -ne $item.PSObject.Properties[$property]) {
                $beforeState.PolicyRegistryValues["Dsh"][$property] = $item.$property
            }
        }
    }

    if (Test-Path $stereo3DKey) {
        $item = Get-ItemProperty -Path $stereo3DKey
        foreach ($property in "DrsEnable", "StereoDefaultOn", "StereoDefaultONSet", "StereoAdjustEnable", "EnableWindowedMode", "EnableNvMsStereoSync") {
            if ($null -ne $item.PSObject.Properties[$property]) {
                $beforeState.Stereo3DRegistryValues[$property] = $item.$property
            }
        }
    }

    if (Test-Path $runKey) {
        $item = Get-ItemProperty -Path $runKey
        foreach ($valueName in $runValueNames) {
            if ($null -ne $item.PSObject.Properties[$valueName]) {
                $beforeState.RunValues[$valueName] = $item.$valueName
            }
        }
    }

    foreach ($serviceName in $nvidiaServiceNames) {
        $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
        if ($service) {
            $beforeState.ServiceStartModes[$serviceName] = $service.StartMode
        }
    }

    foreach ($fileName in $visionFilesToQuarantine) {
        $fullPath = Join-Path $visionDir $fileName
        if (Test-Path -LiteralPath $fullPath) {
            $file = Get-Item -LiteralPath $fullPath
            $beforeState.VisionFiles += [pscustomobject]@{
                Name = $file.Name
                FullPath = $file.FullName
                Length = $file.Length
                LastWriteTime = $file.LastWriteTime.ToString("o")
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

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}

function Set-RegistryExpandString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -PropertyType ExpandString -Value $Value -Force | Out-Null
}

function Set-RegistryString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -PropertyType String -Value $Value -Force | Out-Null
}

function Get-PowerSettingIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subgroup,
        [Parameter(Mandatory = $true)]
        [string]$Setting,
        [Parameter(Mandatory = $true)]
        [ValidateSet("AC", "DC")]
        [string]$PowerSource
    )

    $raw = powercfg /Q SCHEME_CURRENT $Subgroup $Setting | Out-String
    $pattern = if ($PowerSource -eq "AC") {
        "Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)"
    }
    else {
        "Current DC Power Setting Index:\s+0x([0-9a-fA-F]+)"
    }

    if ($raw -match $pattern) {
        return [Convert]::ToInt32($matches[1], 16)
    }

    return $null
}

function Set-PowerSettingIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subgroup,
        [Parameter(Mandatory = $true)]
        [string]$Setting,
        [Parameter(Mandatory = $true)]
        [int]$ACValue,
        [Parameter(Mandatory = $true)]
        [int]$DCValue
    )

    powercfg /SETACVALUEINDEX SCHEME_CURRENT $Subgroup $Setting $ACValue | Out-Null
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT $Subgroup $Setting $DCValue | Out-Null
}

function Backup-And-QuarantineFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return
    }

    New-Item -ItemType Directory -Path $quarantineDir -Force | Out-Null
    $fileName = Split-Path -Path $SourcePath -Leaf
    $backupPath = Join-Path $quarantineDir $fileName

    if (-not (Test-Path -LiteralPath $backupPath)) {
        Copy-Item -LiteralPath $SourcePath -Destination $backupPath -Force
    }

    $disabledPath = $SourcePath + ".disabled"
    if (-not (Test-Path -LiteralPath $disabledPath)) {
        Rename-Item -LiteralPath $SourcePath -NewName (Split-Path -Leaf $disabledPath)
    }
}

Assert-Administrator
Save-CurrentState
New-Item -ItemType Directory -Path $localDumpsDir -Force | Out-Null

if ($PSCmdlet.ShouldProcess("power plan", "switch to High performance and disable PCIe ASPM")) {
    powercfg /SETACTIVE SCHEME_MIN | Out-Null
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0 | Out-Null
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0 | Out-Null
    Set-PowerSettingIndex -Subgroup SUB_VIDEO -Setting VIDEOIDLE -ACValue 0 -DCValue 0
    Set-PowerSettingIndex -Subgroup SUB_SLEEP -Setting STANDBYIDLE -ACValue 0 -DCValue 0
    Set-PowerSettingIndex -Subgroup SUB_SLEEP -Setting HYBRIDSLEEP -ACValue 0 -DCValue 0
    Set-PowerSettingIndex -Subgroup SUB_SLEEP -Setting HIBERNATEIDLE -ACValue 0 -DCValue 0
    Set-PowerSettingIndex -Subgroup SUB_SLEEP -Setting RTCWAKE -ACValue 0 -DCValue 0
    powercfg /SETACTIVE SCHEME_CURRENT | Out-Null
}

if ($PSCmdlet.ShouldProcess($graphicsKey, "set conservative TDR thresholds")) {
    Set-RegistryDword -Path $graphicsKey -Name "TdrDelay" -Value 20
    Set-RegistryDword -Path $graphicsKey -Name "TdrDdiDelay" -Value 30
    Set-RegistryDword -Path $graphicsKey -Name "TdrLimitTime" -Value 600
    Set-RegistryDword -Path $graphicsKey -Name "TdrLimitCount" -Value 20
}

if ($PSCmdlet.ShouldProcess($dwmKey, "disable multiplane overlay test mode")) {
    Set-RegistryDword -Path $dwmKey -Name "OverlayTestMode" -Value 5
}

if ($PSCmdlet.ShouldProcess($sessionPowerKey, "disable fast startup and hibernation")) {
    Set-RegistryDword -Path $sessionPowerKey -Name "HiberbootEnabled" -Value 0
    powercfg /HIBERNATE OFF | Out-Null
}

if ($PSCmdlet.ShouldProcess("current user desktop effects", "disable transparency and window animations")) {
    Set-RegistryDword -Path $personalizeKey -Name "EnableTransparency" -Value 0
    Set-RegistryDword -Path $explorerAdvancedKey -Name "TaskbarAnimations" -Value 0
    Set-RegistryString -Path $windowMetricsKey -Name "MinAnimate" -Value "0"
}

if ($PSCmdlet.ShouldProcess("current user taskbar search surface", "reduce search-box compositing and dynamic highlights")) {
    Set-RegistryDword -Path $searchKey -Name "SearchboxTaskbarMode" -Value 1
    Set-RegistryDword -Path $searchSettingsKey -Name "IsDynamicSearchBoxEnabled" -Value 0
}

if ($PSCmdlet.ShouldProcess("widgets and news surfaces", "disable the taskbar Widgets entry point and stop the Widgets host")) {
    Set-RegistryDword -Path $explorerAdvancedKey -Name "TaskbarDa" -Value 0
    Set-RegistryDword -Path $widgetsPolicyKey -Name "AllowNewsAndInterests" -Value 0
    Get-Process -Name "Widgets" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

if ($PSCmdlet.ShouldProcess($stereo3DKey, "force Stereo3D state off")) {
    Set-RegistryDword -Path $stereo3DKey -Name "DrsEnable" -Value 0
    Set-RegistryDword -Path $stereo3DKey -Name "StereoDefaultOn" -Value 0
    Set-RegistryDword -Path $stereo3DKey -Name "StereoDefaultONSet" -Value 0
    Set-RegistryDword -Path $stereo3DKey -Name "StereoAdjustEnable" -Value 0
    Set-RegistryDword -Path $stereo3DKey -Name "EnableWindowedMode" -Value 0
    Set-RegistryDword -Path $stereo3DKey -Name "EnableNvMsStereoSync" -Value 0
}

if ($PSCmdlet.ShouldProcess($werLocalDumpsKey, "configure full local dumps for taskbar and search shell processes")) {
    foreach ($processName in $werDumpProcessNames) {
        $dumpKey = Join-Path $werLocalDumpsKey $processName
        Set-RegistryExpandString -Path $dumpKey -Name "DumpFolder" -Value $localDumpsDir
        Set-RegistryDword -Path $dumpKey -Name "DumpCount" -Value 10
        Set-RegistryDword -Path $dumpKey -Name "DumpType" -Value 2
    }
}

if ($PSCmdlet.ShouldProcess("NVIDIA services", "disable unnecessary desktop-hooking services")) {
    foreach ($serviceName in $nvidiaServiceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            if ($service.Status -eq "Running") {
                Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name $serviceName -StartupType Disabled
        }
    }
}

if ($PSCmdlet.ShouldProcess("NVIDIA helper processes", "stop tray, sync, and update helper processes")) {
    foreach ($processName in $nvidiaProcessNames) {
        Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

if ($PSCmdlet.ShouldProcess($runKey, "disable NVIDIA autoruns")) {
    foreach ($valueName in $runValueNames) {
        Remove-ItemProperty -Path $runKey -Name $valueName -ErrorAction SilentlyContinue
    }
}

if ($PSCmdlet.ShouldProcess($visionDir, "quarantine 3D Vision user-mode DLLs")) {
    foreach ($fileName in $visionFilesToQuarantine) {
        $sourcePath = Join-Path $visionDir $fileName
        Backup-And-QuarantineFile -SourcePath $sourcePath
    }
}

$afterState = [ordered]@{
    Timestamp = (Get-Date).ToString("o")
    ActiveSchemeRaw = (powercfg /GETACTIVESCHEME | Out-String).Trim()
    PcieAspmRaw = (powercfg /Q SCHEME_CURRENT SUB_PCIEXPRESS ASPM | Out-String).Trim()
    PowerSettings = foreach ($setting in $powerSettings) {
        [pscustomobject]@{
            Name = $setting.Name
            AC = Get-PowerSettingIndex -Subgroup $setting.Subgroup -Setting $setting.Setting -PowerSource AC
            DC = Get-PowerSettingIndex -Subgroup $setting.Subgroup -Setting $setting.Setting -PowerSource DC
        }
    }
    GraphicsRegistryValues = Get-ItemProperty -Path $graphicsKey | Select-Object TdrDelay, TdrDdiDelay, TdrLimitTime, TdrLimitCount
    DwmRegistryValues = Get-ItemProperty -Path $dwmKey -ErrorAction SilentlyContinue | Select-Object OverlayTestMode
    SessionPowerValues = Get-ItemProperty -Path $sessionPowerKey -ErrorAction SilentlyContinue | Select-Object HiberbootEnabled
    UserRegistryValues = [pscustomobject]@{
        Personalize = Get-ItemProperty -Path $personalizeKey -ErrorAction SilentlyContinue | Select-Object EnableTransparency
        ExplorerAdvanced = Get-ItemProperty -Path $explorerAdvancedKey -ErrorAction SilentlyContinue | Select-Object TaskbarAnimations, TaskbarDa
        Search = Get-ItemProperty -Path $searchKey -ErrorAction SilentlyContinue | Select-Object SearchboxTaskbarMode
        SearchSettings = Get-ItemProperty -Path $searchSettingsKey -ErrorAction SilentlyContinue | Select-Object IsDynamicSearchBoxEnabled
        WindowMetrics = Get-ItemProperty -Path $windowMetricsKey -ErrorAction SilentlyContinue | Select-Object MinAnimate
    }
    PolicyRegistryValues = [pscustomobject]@{
        Dsh = Get-ItemProperty -Path $widgetsPolicyKey -ErrorAction SilentlyContinue | Select-Object AllowNewsAndInterests
    }
    Stereo3DRegistryValues = Get-ItemProperty -Path $stereo3DKey -ErrorAction SilentlyContinue | Select-Object DrsEnable, StereoDefaultOn, StereoDefaultONSet, StereoAdjustEnable, EnableWindowedMode, EnableNvMsStereoSync
    ServiceStartModes = foreach ($serviceName in $nvidiaServiceNames) {
        $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
        if ($service) {
            [pscustomobject]@{
                Name = $service.Name
                StartMode = $service.StartMode
                State = $service.State
            }
        }
    }
    VisionFiles = foreach ($fileName in $visionFilesToQuarantine) {
        $sourcePath = Join-Path $visionDir $fileName
        $disabledPath = $sourcePath + ".disabled"
        [pscustomobject]@{
            File = $fileName
            SourceExists = Test-Path -LiteralPath $sourcePath
            DisabledExists = Test-Path -LiteralPath $disabledPath
        }
    }
    NvidiaSessionProcesses = foreach ($processName in $nvidiaProcessNames) {
        Get-Process -Name $processName -ErrorAction SilentlyContinue |
            Select-Object ProcessName, Id
    }
    NvidiaThermals = if (Test-Path -LiteralPath $nvidiaSmi) {
        (& $nvidiaSmi -q 2>$null | Select-String -Pattern 'Performance State','GPU Current Temp').Line
    }
}

$afterState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupDir "state-after.json")

Write-Host "Applied GT 330M stability fix."
Write-Host "Backup saved to: $backupDir"
Write-Host "Reboot Windows before evaluating local-display stability."
Write-Host "If the issue reproduces again, run Collect-GT330M-Evidence.ps1 from the scripts folder."
