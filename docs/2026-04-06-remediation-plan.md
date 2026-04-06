# April 6, 2026 Remediation Plan

## Findings

- `2026-04-06 05:13:20`: Windows logged bugcheck `0x0000010d`.
- `2026-04-06 05:25:54`: the rollback changed `KeyAgent` from `auto start` to `disabled`.
- `2026-04-06 05:37:15`: Windows logged a second bugcheck `0x0000010d` after the rollback window.
- `2026-04-06 14:29:37`: the latest boot started cleanly after a normal `Kernel API` shutdown, not after a bugcheck.
- `2026-04-06 14:30:11`: Windows logged a single `Display` event `4101`, which matches the reported long blank-screen flash during boot.

## Working Theory

- The unexpected boot crashes are still tied to the Apple rollback path, with the strongest remaining signal on the Boot Camp 5 KMDF rollback work done on April 6.
- The broken function row and keyboard backlight are a separate regression caused by the rollback disabling `KeyAgent` and downgrading the Apple keyboard/runtime path.
- The long blank-screen flash on the latest clean boot lines up with a single `nvlddmkm` recovery after login rather than a full boot crash.

## Execution Steps

1. Add a selective Apple input repair script that restores only the Apple keyboard/runtime pieces needed for function-row and backlight handling.
2. Keep the crash-prone Boot Camp 5 Bluetooth and Apple null-driver packages out of that repair path.
3. Update the evidence collection script to capture:
   - recent boot success/failure transitions
   - recent `Display 4101`, `Kernel-Power 41`, `6008`, and `WER 1001` events
   - current `KeyAgent`, `KeyMagic`, `Bootcamp.exe`, and `AppleOSSMgr.exe` state
4. Document when to use the selective input repair versus the full rollback.
5. Validate the PowerShell changes, then push, create a PR, merge to `main`, and sync the local checkout.
