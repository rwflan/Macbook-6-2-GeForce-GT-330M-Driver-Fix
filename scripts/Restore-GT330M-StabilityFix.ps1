[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$BackupPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDir = Split-Path -Parent $PSScriptRoot
$graphicsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
$dwmKey = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"
$sessionPowerKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
$personalizeKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
$explorerAdvancedKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
$searchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
$searchSettingsKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"
$windowMetricsKey = "HKCU:\Control Panel\Desktop\WindowMetrics"
$runKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$werLocalDumpsKey = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps"
$stereo3DKey = "HKLM:\SOFTWARE\WOW6432Node\NVIDIA Corporation\Global\Stereo3D"
$visionDir = "C:\Program Files (x86)\NVIDIA Corporation\3D Vision"
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

$savedPowerSettings = @{}
if ($null -ne $state.PSObject.Properties["PowerSettings"]) {
    foreach ($property in $state.PowerSettings.PSObject.Properties) {
        $savedPowerSettings[$property.Name] = $property.Value
    }
}

foreach ($setting in $powerSettings) {
    if ($savedPowerSettings.ContainsKey($setting.Name)) {
        $saved = $savedPowerSettings[$setting.Name]
        if (($null -ne $saved.AC) -and ($null -ne $saved.DC)) {
            if ($PSCmdlet.ShouldProcess("power plan", "restore $($setting.Name)")) {
                powercfg /SETACVALUEINDEX SCHEME_CURRENT $($setting.Subgroup) $($setting.Setting) ([int]$saved.AC) | Out-Null
                powercfg /SETDCVALUEINDEX SCHEME_CURRENT $($setting.Subgroup) $($setting.Setting) ([int]$saved.DC) | Out-Null
            }
        }
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

$savedDwmValues = @{}
if ($state.DwmRegistryValues) {
    foreach ($property in $state.DwmRegistryValues.PSObject.Properties) {
        $savedDwmValues[$property.Name] = $property.Value
    }
}

foreach ($name in "OverlayTestMode") {
    if ($savedDwmValues.ContainsKey($name)) {
        if ($PSCmdlet.ShouldProcess($dwmKey, "restore $name")) {
            New-ItemProperty -Path $dwmKey -Name $name -PropertyType DWord -Value ([int]$savedDwmValues[$name]) -Force | Out-Null
        }
    }
    elseif (Get-ItemProperty -Path $dwmKey -Name $name -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($dwmKey, "remove $name")) {
            Remove-ItemProperty -Path $dwmKey -Name $name -ErrorAction Stop
        }
    }
}

$savedSessionPowerValues = @{}
if ($null -ne $state.PSObject.Properties["SessionPowerValues"]) {
    foreach ($property in $state.SessionPowerValues.PSObject.Properties) {
        $savedSessionPowerValues[$property.Name] = $property.Value
    }
}

if ($savedSessionPowerValues.ContainsKey("HiberbootEnabled")) {
    if ([int]$savedSessionPowerValues["HiberbootEnabled"] -eq 0) {
        if ($PSCmdlet.ShouldProcess($sessionPowerKey, "restore hibernation disabled state")) {
            powercfg /HIBERNATE OFF | Out-Null
            New-ItemProperty -Path $sessionPowerKey -Name "HiberbootEnabled" -PropertyType DWord -Value 0 -Force | Out-Null
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($sessionPowerKey, "restore hibernation enabled state")) {
            powercfg /HIBERNATE ON | Out-Null
            New-ItemProperty -Path $sessionPowerKey -Name "HiberbootEnabled" -PropertyType DWord -Value ([int]$savedSessionPowerValues["HiberbootEnabled"]) -Force | Out-Null
        }
    }
}

$savedUserRegistryValues = @{}
if ($null -ne $state.PSObject.Properties["UserRegistryValues"]) {
    foreach ($property in $state.UserRegistryValues.PSObject.Properties) {
        $savedUserRegistryValues[$property.Name] = $property.Value
    }
}

if ($savedUserRegistryValues.ContainsKey("Personalize")) {
    $property = $savedUserRegistryValues["Personalize"].PSObject.Properties["EnableTransparency"]
    if ($null -ne $property) {
        $value = $property.Value
        if ($PSCmdlet.ShouldProcess($personalizeKey, "restore EnableTransparency")) {
            New-ItemProperty -Path $personalizeKey -Name "EnableTransparency" -PropertyType DWord -Value ([int]$value) -Force | Out-Null
        }
    }
    elseif (Get-ItemProperty -Path $personalizeKey -Name "EnableTransparency" -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($personalizeKey, "remove EnableTransparency")) {
            Remove-ItemProperty -Path $personalizeKey -Name "EnableTransparency" -ErrorAction Stop
        }
    }
}
elseif (Get-ItemProperty -Path $personalizeKey -Name "EnableTransparency" -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess($personalizeKey, "remove EnableTransparency")) {
        Remove-ItemProperty -Path $personalizeKey -Name "EnableTransparency" -ErrorAction Stop
    }
}

if ($savedUserRegistryValues.ContainsKey("ExplorerAdvanced")) {
    $property = $savedUserRegistryValues["ExplorerAdvanced"].PSObject.Properties["TaskbarAnimations"]
    if ($null -ne $property) {
        $value = $property.Value
        if ($PSCmdlet.ShouldProcess($explorerAdvancedKey, "restore TaskbarAnimations")) {
            New-ItemProperty -Path $explorerAdvancedKey -Name "TaskbarAnimations" -PropertyType DWord -Value ([int]$value) -Force | Out-Null
        }
    }
    elseif (Get-ItemProperty -Path $explorerAdvancedKey -Name "TaskbarAnimations" -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($explorerAdvancedKey, "remove TaskbarAnimations")) {
            Remove-ItemProperty -Path $explorerAdvancedKey -Name "TaskbarAnimations" -ErrorAction Stop
        }
    }
}
elseif (Get-ItemProperty -Path $explorerAdvancedKey -Name "TaskbarAnimations" -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess($explorerAdvancedKey, "remove TaskbarAnimations")) {
        Remove-ItemProperty -Path $explorerAdvancedKey -Name "TaskbarAnimations" -ErrorAction Stop
    }
}

if ($savedUserRegistryValues.ContainsKey("Search")) {
    $property = $savedUserRegistryValues["Search"].PSObject.Properties["SearchboxTaskbarMode"]
    if ($null -ne $property) {
        $value = $property.Value
        if ($PSCmdlet.ShouldProcess($searchKey, "restore SearchboxTaskbarMode")) {
            New-ItemProperty -Path $searchKey -Name "SearchboxTaskbarMode" -PropertyType DWord -Value ([int]$value) -Force | Out-Null
        }
    }
    elseif (Get-ItemProperty -Path $searchKey -Name "SearchboxTaskbarMode" -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($searchKey, "remove SearchboxTaskbarMode")) {
            Remove-ItemProperty -Path $searchKey -Name "SearchboxTaskbarMode" -ErrorAction Stop
        }
    }
}
elseif (Get-ItemProperty -Path $searchKey -Name "SearchboxTaskbarMode" -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess($searchKey, "remove SearchboxTaskbarMode")) {
        Remove-ItemProperty -Path $searchKey -Name "SearchboxTaskbarMode" -ErrorAction Stop
    }
}

if ($savedUserRegistryValues.ContainsKey("SearchSettings")) {
    $property = $savedUserRegistryValues["SearchSettings"].PSObject.Properties["IsDynamicSearchBoxEnabled"]
    if ($null -ne $property) {
        $value = $property.Value
        if ($PSCmdlet.ShouldProcess($searchSettingsKey, "restore IsDynamicSearchBoxEnabled")) {
            New-ItemProperty -Path $searchSettingsKey -Name "IsDynamicSearchBoxEnabled" -PropertyType DWord -Value ([int]$value) -Force | Out-Null
        }
    }
    elseif (Get-ItemProperty -Path $searchSettingsKey -Name "IsDynamicSearchBoxEnabled" -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($searchSettingsKey, "remove IsDynamicSearchBoxEnabled")) {
            Remove-ItemProperty -Path $searchSettingsKey -Name "IsDynamicSearchBoxEnabled" -ErrorAction Stop
        }
    }
}
elseif (Get-ItemProperty -Path $searchSettingsKey -Name "IsDynamicSearchBoxEnabled" -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess($searchSettingsKey, "remove IsDynamicSearchBoxEnabled")) {
        Remove-ItemProperty -Path $searchSettingsKey -Name "IsDynamicSearchBoxEnabled" -ErrorAction Stop
    }
}

if ($savedUserRegistryValues.ContainsKey("WindowMetrics")) {
    $property = $savedUserRegistryValues["WindowMetrics"].PSObject.Properties["MinAnimate"]
    if ($null -ne $property) {
        $value = $property.Value
        if ($PSCmdlet.ShouldProcess($windowMetricsKey, "restore MinAnimate")) {
            Set-RegistryString -Path $windowMetricsKey -Name "MinAnimate" -Value ([string]$value)
        }
    }
    elseif (Get-ItemProperty -Path $windowMetricsKey -Name "MinAnimate" -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($windowMetricsKey, "remove MinAnimate")) {
            Remove-ItemProperty -Path $windowMetricsKey -Name "MinAnimate" -ErrorAction Stop
        }
    }
}
elseif (Get-ItemProperty -Path $windowMetricsKey -Name "MinAnimate" -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess($windowMetricsKey, "remove MinAnimate")) {
        Remove-ItemProperty -Path $windowMetricsKey -Name "MinAnimate" -ErrorAction Stop
    }
}

$savedStereoValues = @{}
if ($state.Stereo3DRegistryValues) {
    foreach ($property in $state.Stereo3DRegistryValues.PSObject.Properties) {
        $savedStereoValues[$property.Name] = $property.Value
    }
}

foreach ($name in "DrsEnable", "StereoDefaultOn", "StereoDefaultONSet", "StereoAdjustEnable", "EnableWindowedMode", "EnableNvMsStereoSync") {
    if ($savedStereoValues.ContainsKey($name)) {
        if ($PSCmdlet.ShouldProcess($stereo3DKey, "restore $name")) {
            New-ItemProperty -Path $stereo3DKey -Name $name -PropertyType DWord -Value ([int]$savedStereoValues[$name]) -Force | Out-Null
        }
    }
    elseif (Get-ItemProperty -Path $stereo3DKey -Name $name -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($stereo3DKey, "remove $name")) {
            Remove-ItemProperty -Path $stereo3DKey -Name $name -ErrorAction Stop
        }
    }
}

if ($null -ne $state.PSObject.Properties["RunValues"]) {
    foreach ($property in $state.RunValues.PSObject.Properties) {
        if ($PSCmdlet.ShouldProcess($runKey, "restore autorun $($property.Name)")) {
            New-ItemProperty -Path $runKey -Name $property.Name -PropertyType String -Value ([string]$property.Value) -Force | Out-Null
        }
    }
}

$knownRunValues = "NvBackend", "ShadowPlay"
foreach ($name in $knownRunValues) {
    $savedRunValueNames = @()
    if ($null -ne $state.PSObject.Properties["RunValues"]) {
        $savedRunValueNames = @($state.RunValues.PSObject.Properties | ForEach-Object Name)
    }
    if (($null -eq $state.PSObject.Properties["RunValues"]) -or (-not ($savedRunValueNames -contains $name))) {
        if (Get-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue) {
            if ($PSCmdlet.ShouldProcess($runKey, "remove autorun $name")) {
                Remove-ItemProperty -Path $runKey -Name $name -ErrorAction Stop
            }
        }
    }
}

if ($null -ne $state.PSObject.Properties["ServiceStartModes"]) {
    foreach ($property in $state.ServiceStartModes.PSObject.Properties) {
        $service = Get-Service -Name $property.Name -ErrorAction SilentlyContinue
        if ($service) {
            $targetStartType = switch -Exact ($property.Value) {
                "Auto" { "Automatic" }
                "Manual" { "Manual" }
                "Disabled" { "Disabled" }
                default { $null }
            }
            if ($targetStartType) {
                if ($PSCmdlet.ShouldProcess($property.Name, "restore service startup type to $targetStartType")) {
                    Set-Service -Name $property.Name -StartupType $targetStartType
                }
            }
        }
    }
}

foreach ($processName in $werDumpProcessNames) {
    $dumpKey = Join-Path $werLocalDumpsKey $processName
    if (Test-Path -Path $dumpKey) {
        if ($PSCmdlet.ShouldProcess($dumpKey, "remove local dump configuration")) {
            Remove-Item -Path $dumpKey -Recurse -Force
        }
    }
}

$quarantineDir = Join-Path $resolvedBackup "3dvision-quarantine"
if (Test-Path -LiteralPath $quarantineDir) {
    foreach ($backupFile in Get-ChildItem -LiteralPath $quarantineDir -File) {
        $targetPath = Join-Path $visionDir $backupFile.Name
        $disabledPath = $targetPath + ".disabled"
        if (Test-Path -LiteralPath $disabledPath) {
            if ($PSCmdlet.ShouldProcess($disabledPath, "remove quarantined disabled file")) {
                Remove-Item -LiteralPath $disabledPath -Force
            }
        }
        if ($PSCmdlet.ShouldProcess($targetPath, "restore 3D Vision file")) {
            New-Item -ItemType Directory -Path $visionDir -Force | Out-Null
            Copy-Item -LiteralPath $backupFile.FullName -Destination $targetPath -Force
        }
    }
}

powercfg /SETACTIVE SCHEME_CURRENT | Out-Null

Write-Host "Restored GT 330M stability settings from: $resolvedBackup"
Write-Host "Reboot Windows to fully return the graphics stack to its prior state."
