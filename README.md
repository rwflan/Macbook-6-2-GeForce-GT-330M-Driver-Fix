# MacBookPro6,2 GT 330M Stability Fix

This workspace documents and applies a conservative Windows-side mitigation for the recurring `nvlddmkm` resets seen on the Mid-2010 15-inch MacBook Pro (`MacBookPro6,2`) under Boot Camp.

## What the evidence says

The live machine shows all of the following:

- Hardware model: `Apple Inc. MacBookPro6,2`
- GPU: `NVIDIA GeForce GT 330M`
- Driver: `21.21.13.4201` (`342.01`, dated 2016-11-14)
- OS build: `22000` (`21H2`)
- System log: repeated `Display` event `4101` (`Display driver nvlddmkm stopped responding and has successfully recovered`)
- Windows Error Reporting: `LiveKernelEvent 141`
- Active power plan before fix: `Balanced`
- PCIe Link State Power Management before fix: `Maximum power savings` on AC and DC

That combination strongly suggests this is not a simple "wrong driver version" issue. The machine is already using the legacy NVIDIA branch expected for the GT 330M. The practical Windows trigger is the GPU/PCIe/display path timing out and being reset by WDDM TDR. On this model, that is commonly aggravated by power-state transitions and by the age-related fragility of the discrete GPU/logic board.

## What this fix changes

`Apply-GT330M-StabilityFix.ps1` makes only reversible, low-risk changes:

- Backs up the current graphics-driver registry branch and active power scheme
- Switches the system to `High performance`
- Disables PCIe Link State Power Management on AC and battery
- Sets conservative TDR values:
  - `TdrDelay = 10`
  - `TdrDdiDelay = 20`
  - `TdrLimitTime = 180`
  - `TdrLimitCount = 10`

The script does **not** disable TDR completely, because that can turn recoverable hangs into full system freezes.

## Why this is the right first fix

- It addresses the clear machine-specific misconfiguration found during inspection: aggressive PCIe power savings on a legacy mobile NVIDIA device.
- It reduces false-positive or borderline TDR trips without masking the GPU forever.
- It is safe to apply over RDP and easy to roll back.

## Remaining reality

If local-console testing still produces `4101`, `141`, or full reboots after this fix, the remaining root cause is very likely the GT 330M hardware path itself, not an untried registry tweak. In that case the durable options are:

- Keep using the machine with reduced local 3D load and this safer power profile
- Move back to a supported Windows 10 build if this install is actually Windows 11-era (`22000`) on an unsupported GPU stack
- Replace/retire the logic board or avoid local use of the discrete GPU entirely

## Scripts

- `scripts/Apply-GT330M-StabilityFix.ps1`
- `scripts/Restore-GT330M-StabilityFix.ps1`

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
