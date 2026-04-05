# MacBookPro6,2 GT 330M Stability Fix

PowerShell scripts for diagnosing, applying, and rolling back a conservative Windows-side mitigation for recurring `nvlddmkm` resets on the Mid-2010 15-inch MacBook Pro (`MacBookPro6,2`) running Boot Camp.

## Scope

This repository focuses on the Windows graphics stack and related power-management settings. It does not change firmware, BIOS, or bootloader configuration.

## Observed Failure Pattern

The machine used to validate this fix showed the following:

- Hardware model: `Apple Inc. MacBookPro6,2`
- GPU: `NVIDIA GeForce GT 330M`
- Driver: `9.18.13.4181` (`341.81`, dated 2015-08-17)
- OS build: `22000` (`21H2`)
- System log: repeated `Display` event `4101` with `nvlddmkm` recoveries
- Windows Error Reporting: `LiveKernelEvent 141`
- Power plan before remediation: `Balanced`
- PCIe Link State Power Management before remediation: `Maximum power savings` on AC and DC
- `nvidia-smi` showed the GPU sitting at roughly `81 C` and `P0` on the desktop

The working assumption is that the failure is driven by display and power-state transitions on an aging discrete GPU path, not just by the driver version alone.

## What The Fix Changes

`Apply-GT330M-StabilityFix.ps1` makes reversible changes that reduce the chance of a TDR-triggered reset:

- Backs up the current graphics-driver registry state and active power scheme
- Switches to the `High performance` plan
- Disables PCIe Link State Power Management on AC and battery
- Disables display idle, hibernation, hybrid sleep, and wake-timer triggers that can expose the failing path
- Preserves lid-close and hardware button behavior
- Sets more forgiving TDR thresholds:
  - `TdrDelay = 20`
  - `TdrDdiDelay = 30`
  - `TdrLimitTime = 600`
  - `TdrLimitCount = 20`
- Sets `OverlayTestMode = 5`
- Configures local dumps for `dwm.exe` and `explorer.exe`
- Disables unnecessary NVIDIA services and helper processes
- Forces NVIDIA Stereo3D state off
- Quarantines legacy 3D Vision user-mode DLLs
- Disables transparency and window animation effects for the current user

The script does not disable TDR entirely, because that can turn recoverable hangs into hard freezes.

## Repository Contents

- `scripts/Apply-GT330M-StabilityFix.ps1`
- `scripts/Restore-GT330M-StabilityFix.ps1`
- `scripts/Collect-GT330M-Evidence.ps1`
- `scripts/Install-BootCamp5033-AppleComponents.ps1`
- `scripts/Run-Apply-GT330M-StabilityFix.cmd`
- `scripts/Run-Restore-GT330M-StabilityFix.cmd`

## Requirements

- Windows with PowerShell
- Administrative privileges for the apply and restore scripts
- Boot Camp drivers already installed on the target machine

## Usage

Apply the fix:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Apply-GT330M-StabilityFix.ps1
```

You can also use `scripts\Run-Apply-GT330M-StabilityFix.cmd` to launch it with a UAC prompt.

Restore the previous state:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Restore-GT330M-StabilityFix.ps1
```

You can also use `scripts\Run-Restore-GT330M-StabilityFix.cmd`.

Collect evidence after a repro:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Collect-GT330M-Evidence.ps1
```

Install the Apple-only Boot Camp 5.0.5033 runtime update:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-BootCamp5033-AppleComponents.ps1
```

## Operational Notes

- Run the apply script, reboot, and then evaluate local-display stability.
- If the issue still reproduces after the fix, the likely remaining cause is the GT 330M hardware path itself.
- Use the restore script if you want to roll the machine back to the prior configuration.
