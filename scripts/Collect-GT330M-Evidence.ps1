[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDir = Split-Path -Parent $PSScriptRoot
$captureDir = Join-Path (Join-Path $baseDir "logs") ("capture-" + (Get-Date -Format "yyyyMMdd-HHmmss"))

New-Item -ItemType Directory -Path $captureDir -Force | Out-Null

$systemEvents = Join-Path $captureDir "system-events.txt"
$appEvents = Join-Path $captureDir "application-events.txt"
$machineState = Join-Path $captureDir "machine-state.txt"
$summaryFile = Join-Path $captureDir "summary.txt"

Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddDays(-2)} |
    Where-Object { $_.ProviderName -in @('Display','BugCheck','Microsoft-Windows-WHEA-Logger') -or $_.Id -in @(4101,14,41,117,141) } |
    Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
    Format-List | Set-Content -LiteralPath $systemEvents

Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=(Get-Date).AddDays(-2)} |
    Where-Object { $_.ProviderName -in @('Application Error','Windows Error Reporting') } |
    Where-Object { $_.Message -match 'dwm.exe|explorer.exe|LiveKernelEvent|nvlddmkm' } |
    Select-Object TimeCreated, Id, ProviderName, Message |
    Format-List | Set-Content -LiteralPath $appEvents

$watchdogFiles = @(Get-ChildItem 'C:\Windows\LiveKernelReports\WATCHDOG' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 5)

foreach ($file in $watchdogFiles) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $captureDir $file.Name) -Force
}

$werDirs = @(Get-ChildItem 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive' -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'Kernel_141*' -or $_.Name -like 'AppCrash_dwm.exe*' -or $_.Name -like 'AppCrash_explorer.exe*' } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 6)

foreach ($dir in $werDirs) {
    $target = Join-Path $captureDir $dir.Name
    Copy-Item -LiteralPath $dir.FullName -Destination $target -Recurse -Force
}

@(
    "Timestamp: $((Get-Date).ToString('o'))"
    ""
    "Video controller:"
    (Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, DriverDate | Format-List | Out-String).Trim()
    ""
    "Display PnP devices:"
    (pnputil /enum-devices /class Display /drivers | Out-String).Trim()
    ""
    "Recent NVIDIA helper processes:"
    (Get-CimInstance Win32_Process |
        Where-Object { $_.Name -in 'nvvsvc.exe','nvxdsync.exe','nvtray.exe','NvBackend.exe','nvsmartmaxapp.exe','nvsmartmaxapp64.exe' } |
        Select-Object Name, ProcessId, ParentProcessId, CommandLine |
        Format-List | Out-String).Trim()
    ""
    "Relevant services:"
    (Get-Service | Where-Object { $_.Name -match 'nvsvc|Stereo Service|GfExperienceService|NvNetworkService|NvStreamSvc|NvStreamNetworkSvc' } |
        Select-Object Status, StartType, Name, DisplayName |
        Format-Table -AutoSize | Out-String).Trim()
    ""
    "Relevant power settings:"
    (powercfg /Q SCHEME_CURRENT SUB_PCIEXPRESS ASPM | Out-String).Trim()
    (powercfg /Q SCHEME_CURRENT SUB_SLEEP | Out-String).Trim()
    (powercfg /Q SCHEME_CURRENT SUB_BUTTONS | Out-String).Trim()
    (powercfg /Q SCHEME_CURRENT SUB_VIDEO | Out-String).Trim()
    ""
    "GraphicsDrivers registry:"
    ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue |
        Select-Object TdrDelay, TdrDdiDelay, TdrLimitTime, TdrLimitCount, TdrLevel) |
        Format-List | Out-String).Trim()
    ""
    "DWM registry:"
    ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -ErrorAction SilentlyContinue |
        Select-Object OverlayTestMode) |
        Format-List | Out-String).Trim()
    ""
    "User desktop effects:"
    ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue |
        Select-Object EnableTransparency) |
        Format-List | Out-String).Trim()
    ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -ErrorAction SilentlyContinue |
        Select-Object TaskbarAnimations) |
        Format-List | Out-String).Trim()
    ((Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -ErrorAction SilentlyContinue |
        Select-Object MinAnimate) |
        Format-List | Out-String).Trim()
    ""
    "nvidia-smi:"
    (& 'C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe' -q 2>&1 | Out-String).Trim()
) | Set-Content -LiteralPath $machineState

@(
    "Capture directory: $captureDir"
    "Generated: $((Get-Date).ToString('o'))"
    "Watchdog dumps copied: $($watchdogFiles.Count)"
    "WER directories copied: $($werDirs.Count)"
    "Machine state file: $machineState"
) | Set-Content -LiteralPath $summaryFile

Write-Host "Collected GT 330M evidence in: $captureDir"
