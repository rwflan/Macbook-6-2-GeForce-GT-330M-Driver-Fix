# MacBookPro6,2 GT 330M Stability Fix

This workspace documents and applies a conservative Windows-side mitigation for the recurring `nvlddmkm` resets seen on the Mid-2010 15-inch MacBook Pro (`MacBookPro6,2`) under Boot Camp.

## What the evidence says

The live machine shows all of the following:

- Hardware model: `Apple Inc. MacBookPro6,2`
- GPU: `NVIDIA GeForce GT 330M`
- Driver after rollback: `9.18.13.4181` (`341.81`, dated 2015-08-17)
- OS build: `22000` (`21H2`)
- System log: repeated `Display` event `4101` (`Display driver nvlddmkm stopped responding and has successfully recovered`)
- Windows Error Reporting: `LiveKernelEvent 141`
- Active power plan before fix: `Balanced`
- PCIe Link State Power Management before fix: `Maximum power savings` on AC and DC
- Post-rollback evidence still showed fresh `4101` / `141` recoveries after sleep-style display transitions
- `nvidia-smi` showed the GT 330M sitting at roughly `81 C` and `P0` on the desktop, which makes thermal margin part of the problem

That combination strongly suggests this is not a simple "wrong driver version" issue. The machine is already using the legacy NVIDIA branch expected for the GT 330M. The practical Windows trigger is the GPU/PCIe/display path timing out and being reset by WDDM TDR. On this model, that is commonly aggravated by power-state transitions and by the age-related fragility of the discrete GPU/logic board.

## What this fix changes

`Apply-GT330M-StabilityFix.ps1` makes only reversible, low-risk changes:

- Backs up the current graphics-driver registry branch and active power scheme
- Switches the system to `High performance`
- Disables PCIe Link State Power Management on AC and battery
- Disables remaining suspend/resume triggers that still hit the failing display path:
  - display idle timeout
  - hibernation / fast startup
  - wake timers
- Preserves the existing lid-close and hardware button actions so normal sleep behavior still works
- Sets conservative TDR values:
  - `TdrDelay = 10`
  - `TdrDdiDelay = 20`
  - `TdrLimitTime = 180`
  - `TdrLimitCount = 10`
- Disables DWM multiplane overlay testing by setting `OverlayTestMode = 5`
- Configures full local dumps for `dwm.exe` and `explorer.exe`
- Disables unnecessary NVIDIA components that commonly hook desktop composition on legacy systems:
  - `NVIDIA Display Driver Service`
  - `NVIDIA Stereoscopic 3D Driver Service`
  - `NVIDIA GeForce Experience Service`
  - `NVIDIA Network Service`
  - `NVIDIA Streamer Service`
  - `NVIDIA Streamer Network Service`
  - `NvBackend`, `nvtray`, `nvxdsync`, and related helper processes
- Forces NVIDIA Stereo3D state off in the registry
- Quarantines the `3D Vision` user-mode DLLs that were still loading into `dwm.exe`
- Disables transparency and taskbar/window animations for the current user to cut compositor load on the desktop

The script does **not** disable TDR completely, because that can turn recoverable hangs into full system freezes.

## Why this is the right first fix

- It addresses the concrete triggers found during inspection: PCIe/display power transitions, the NVIDIA desktop helper chain, and excessive idle thermal load.
- It reduces false-positive or borderline TDR trips without masking the GPU forever.
- It is safe to apply over RDP and easy to roll back.

## Remaining reality

If local-console testing still produces `4101`, `141`, or full reboots after this fix, the remaining root cause is very likely the GT 330M hardware path itself, not an untried registry tweak. In that case the durable options are:

- Keep using the machine with reduced local 3D load and this safer power profile
- Move back to a supported Windows 10 build if this install is actually Windows 11-era (`22000`) on an unsupported GPU stack
- Replace/retire the logic board or avoid local use of the discrete GPU entirely

## BIOS Preboot Fix

This machine is currently booting Windows in legacy BIOS mode, not UEFI. That means the `rEFInd` / EFI-shell `mm` method from the archived LaptopVideo2Go thread does not apply directly to this install.

For this specific machine state, the equivalent fix is a BIOS-side GRUB chainloader that runs the original four `setpci` writes before handing control to Windows Boot Manager:

- `setpci -s "00:01.0" 3e.b=8`
- `setpci -s "01:00.0" 04.b=7`
- `setpci -s "00:00.0" 50.W=2`
- `setpci -s "00:00.0" 54.B=3`

`Install-GT330M-BiosPrebootFix.ps1` downloads a BIOS-capable `grub4dos` build, places `grldr` and a generated `menu.lst` on `C:\`, creates a dedicated `bootmgr` entry called `Windows 11 (GT330M preboot fix)`, and sets that entry as the default while keeping the standard Windows entry as fallback in the boot menu.

`Remove-GT330M-BiosPrebootFix.ps1` removes that boot entry and restores the previous default boot settings and any overwritten root files.

## Scripts

- `scripts/Apply-GT330M-StabilityFix.ps1`
- `scripts/Restore-GT330M-StabilityFix.ps1`
- `scripts/Collect-GT330M-Evidence.ps1`
- `scripts/Install-GT330M-BiosPrebootFix.ps1`
- `scripts/Remove-GT330M-BiosPrebootFix.ps1`

## Usage

Apply:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\\scripts\\Apply-GT330M-StabilityFix.ps1
```

Or run `scripts\\Run-Apply-GT330M-StabilityFix.cmd` and accept the UAC prompt.

Restore:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\\scripts\\Restore-GT330M-StabilityFix.ps1
```

Or run `scripts\\Run-Restore-GT330M-StabilityFix.cmd` and accept the UAC prompt.

Collect evidence after a repro:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\\scripts\\Collect-GT330M-Evidence.ps1
```

Install the BIOS preboot fix:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\\scripts\\Install-GT330M-BiosPrebootFix.ps1
```

Remove the BIOS preboot fix:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\\scripts\\Remove-GT330M-BiosPrebootFix.ps1
```
