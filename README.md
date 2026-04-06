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

- `Install-GT330M-StabilityFix.ps1`
- `scripts/Apply-GT330M-StabilityFix.ps1`
- `scripts/Restore-GT330M-StabilityFix.ps1`
- `scripts/Collect-GT330M-Evidence.ps1`
- `scripts/Install-BootCamp5033-AppleComponents.ps1`
- `scripts/Remove-BootCamp5033-AppleComponents.ps1`
- `scripts/Restore-BootCampInputSupport.ps1`
- `scripts/Run-Apply-GT330M-StabilityFix.cmd`
- `scripts/Run-Restore-GT330M-StabilityFix.cmd`
- `docs/model-compatibility-analysis.md`

## Similar Model Feasibility

Static analysis suggests the current fix is most likely to transfer to:

- `MacBookPro6,1` (17-inch, Mid 2010): strongest candidate; same `Intel HD + GeForce GT 330M` automatic-switching design as `MacBookPro6,2`

Lower-confidence but still plausible if the symptom is the same `nvlddmkm` / TDR failure on the discrete NVIDIA path:

- `MacBookPro5,3` (15-inch, Mid 2009 higher trims): `9400M + 9600M GT`
- `MacBookPro5,2` (17-inch, Early/Mid 2009): `9400M + 9600M GT`
- `MacBookPro5,1` (15-inch, Late 2008 / Early 2009 refresh): `9400M + 9600M GT`

Out of scope:

- integrated-only 13-inch models such as `MacBookPro5,5` and `MacBookPro7,1`
- 2011 switching models such as `MacBookPro8,2` and `MacBookPro8,3`, which use AMD discrete GPUs rather than NVIDIA

See `docs/model-compatibility-analysis.md` for the full rationale and source-backed notes.

## Requirements

- Windows with PowerShell
- Administrative privileges for the apply and restore scripts
- Boot Camp drivers already installed on the target machine

## Usage

Recommended install: copy this one-liner into PowerShell and approve the UAC prompt:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $tmp = Join-Path $env:TEMP 'Install-GT330M-StabilityFix.ps1'; try { Invoke-WebRequest 'https://raw.githubusercontent.com/rwflan/Macbook-6-2-GeForce-GT-330M-Driver-Fix/main/Install-GT330M-StabilityFix.ps1' -OutFile $tmp; & $tmp } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }"
```

What it does:

- Downloads the latest installer script from `main`
- Prompts for elevation if needed
- Downloads a temporary ZIP of this repository
- Runs `scripts\Apply-GT330M-StabilityFix.ps1`
- Cleans up the temporary files when finished

Manual apply:

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

Install the Apple Boot Camp 5.0.5033 runtime update:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-BootCamp5033-AppleComponents.ps1
```

On `MacBookPro6,2`, that script is now blocked by default unless you pass `-ForceLegacyAppleDriverUpgrade`, because the package upgrades Apple HID/Bluetooth/support drivers and has been linked to `0x10d` boot crashes on this machine.

Roll back the Boot Camp 5.0.5033 Apple component update:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Remove-BootCamp5033-AppleComponents.ps1
```

That rollback now temporarily disables the Apple Bluetooth device while downgrading the Boot Camp driver packages so `AppleBtBc.sys` can be replaced cleanly before the next reboot.
It also restores the safe Boot Camp 5 keyboard/runtime files afterward and reinstalls the signed Apple keyboard package so the function row and keyboard backlight do not get stranded on the older Boot Camp 4 stack.

If the machine is already rolled back and only the Apple input support needs repair:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Restore-BootCampInputSupport.ps1
```

By default, that script uses `C:\Temp\BootCamp5.0.5033\BootCamp\Drivers\Apple\AppleKeyboardInstaller64.exe` and will rebuild that extract folder from `C:\Temp\BootCamp5.0.5033.zip` if needed. If your Boot Camp 5 package lives somewhere else, pass `-KeyboardInstallerPath`.

If that script reports a queued replacement for another locked file, reboot once before judging whether the function row, keyboard backlight, and Boot Camp hotkeys are fully restored.

After applying the fix:

- Reboot before evaluating local-display stability.
- If the issue still reproduces, the likely remaining cause is the GT 330M hardware path itself.
- Use the restore script to roll the machine back to its prior configuration.

## Attribution

This repository's scripts and documentation are maintained by [rwflan](https://github.com/rwflan).

Hardware and model-compatibility notes in this repo are based on public technical references from Apple Support and EveryMac. The detailed source list is in `docs/model-compatibility-analysis.md`.

Apple, Boot Camp, MacBook Pro, Microsoft Windows, NVIDIA, and GeForce are the property of their respective owners. This repository is an independent community project and is not affiliated with or endorsed by Apple, Microsoft, or NVIDIA. Any third-party software downloaded or referenced by these scripts remains subject to its original license and distribution terms.

## License

This repository is available under the MIT License. See `LICENSE`.
