# Static Compatibility Analysis For Similar MacBook Pro Models

This note evaluates whether the existing Windows-side mitigation in this repository is likely to help other MacBook Pro models from the same 2008-2010 era that shipped with discrete NVIDIA GPUs.

This is static analysis only. No claims below are validated on hardware.

## What The Scripts Actually Depend On

The current scripts do not modify Apple firmware, EFI variables, ACPI tables, or gmux state. They only change Windows-side behavior:

- `powercfg` settings, especially PCIe ASPM and sleep/display timers
- `GraphicsDrivers` TDR registry values
- `DWM` overlay behavior
- NVIDIA services, helper processes, autoruns, and legacy 3D Vision DLLs
- Evidence collection for `nvlddmkm`, `WATCHDOG`, and WER artifacts

Because of that, transferability depends mostly on whether the target machine has:

- A legacy NVIDIA discrete GPU using the same general Windows driver stack
- Similar switchable-graphics behavior under Boot Camp
- The same class of TDR / `nvlddmkm` instability rather than a different failure mode

## Candidate Matrix

| Model | GPU topology | Similarity to `MacBookPro6,2` | Feasibility | Why |
| --- | --- | --- | --- | --- |
| `MacBookPro6,1` (17-inch, Mid 2010) | Intel HD + GeForce GT 330M, automatic switching | Very high | Strong candidate | Same dGPU family, same Intel Arrandale generation, same automatic switching design, same Boot Camp-era NVIDIA stack. |
| `MacBookPro5,3` (15-inch, Mid 2009, higher trims) | GeForce 9600M GT + 9400M | Medium | Plausible with caution | Same general dual-GPU Apple notebook design and same legacy NVIDIA Windows stack, but earlier Penryn/MCP79 platform and different dGPU. |
| `MacBookPro5,2` (17-inch, Early/Mid 2009) | GeForce 9600M GT + 9400M | Medium | Plausible with caution | Similar to `5,3`; dual NVIDIA path may benefit from the same ASPM/TDR/service reductions, but it is not the same 2010 Intel+NVIDIA arrangement. |
| `MacBookPro5,1` (15-inch, Late 2008 / Early 2009 refresh) | GeForce 9600M GT + 9400M | Medium-low | Possible but lower confidence | Still dual NVIDIA, but older board generation and older switching implementation increase uncertainty. |
| `MacBookPro5,4` (15-inch, Mid 2009 base) | 9400M only | Low | Not a target | No discrete NVIDIA GPU, so the repo's discrete-path assumptions do not line up well. |
| `MacBookPro5,5` / `MacBookPro7,1` (13-inch 2009-2010) | 9400M or 320M only | Low | Not a target | Integrated-only NVIDIA graphics; some generic Windows tweaks may be harmless, but this repo is aimed at discrete-path instability. |
| `MacBookPro8,2` / `MacBookPro8,3` (2011) | Intel HD 3000 + AMD Radeon | None | Exclude | Same switching concept, but wrong vendor and wrong driver stack. The scripts are specifically NVIDIA-oriented. |

## Most Likely Reusable Target

### `MacBookPro6,1`

`MacBookPro6,1` is the only model that looks close enough to treat as a near-peer of `MacBookPro6,2`.

Reasons:

- Apple lists both `MacBookPro6,1` and `MacBookPro6,2` as Mid-2010 systems with `Intel HD Graphics`, `NVIDIA GeForce GT 330M`, and automatic graphics switching.
- The scripts do not key off panel size, storage, battery, or ports.
- The scripts also do not hardcode PCI IDs, subsystem IDs, or model strings, so nothing in the current implementation obviously excludes `6,1`.

If the same symptom appears on `6,1`:

- repeated `Display` event `4101`
- `nvlddmkm` recovery loops
- `LiveKernelEvent 141`
- instability around desktop idle, wake, or display state changes

then the existing scripts are structurally likely to be relevant.

## Plausible But Less Certain Targets

### `MacBookPro5,1`, `5,2`, and `5,3`

These are weaker candidates, but still the only other family worth considering.

Reasons they may still benefit:

- They also use Apple switchable graphics in Boot Camp-era Windows installs.
- Their discrete GPU is still legacy mobile NVIDIA (`GeForce 9600M GT`), so the same broad classes of mitigation still map:
  - relax TDR timing
  - disable PCIe link power savings
  - suppress NVIDIA desktop helper processes and services
  - disable Stereo3D / 3D Vision remnants
  - reduce DWM overlay and desktop-effects churn

Reasons confidence is lower:

- Their topology is `9400M + 9600M GT`, not `Intel HD + GT 330M`.
- The switching implementation is older and all-NVIDIA rather than Intel iGPU plus NVIDIA dGPU.
- Some instability on those machines can come from different interactions than the `MacBookPro6,x` generation.

Practical conclusion:

- The scripts may help if the observed problem is still classic Windows TDR behavior on the discrete NVIDIA path.
- They should not be advertised as equivalent coverage without adding explicit model notes and likely renaming the repo/scripts to something broader than `GT330M`.

## Models To Exclude

### Integrated-only 13-inch models

The repo's operating assumption is that failures are tied to an aging discrete NVIDIA path. Integrated-only `9400M` or `320M` machines do not match that assumption well enough to recommend this fix family.

### 2011 AMD-switching models

`MacBookPro8,2` and `MacBookPro8,3` have automatic switching, but Apple lists AMD Radeon discrete GPUs on those systems, not NVIDIA. The service names, helper processes, 3D Vision components, and driver failure signatures targeted here are the wrong stack.

## Recommendation

If this repo is expanded beyond `MacBookPro6,2`, the sensible order is:

1. `MacBookPro6,1`
2. `MacBookPro5,3`
3. `MacBookPro5,2`
4. `MacBookPro5,1`

Anything outside that list should be treated as out of scope for this fix as currently written.

## Suggested Guardrails Before Broader Claims

Before calling the fix "supported" for another SKU, add a lightweight preflight check to capture:

- `Win32_ComputerSystem.Model`
- `Win32_VideoController.Name`
- whether `nvlddmkm` is the loaded display miniport
- presence or absence of targeted NVIDIA services and 3D Vision files

That would let the scripts stay permissive while producing an explicit "high confidence / lower confidence / unsupported topology" message.

## Sources

- Apple: [MacBook Pro (15-inch, Mid 2010) - Technical Specifications](https://support.apple.com/en-us/112605)
- Apple: [MacBook Pro (17-inch, Mid 2010) - Technical Specifications](https://support.apple.com/en-mn/112606)
- Apple: [MacBook Pro (15-inch, Mid 2009) and (15-inch, 2.53 GHz, Mid 2009) - Technical Specifications](https://support.apple.com/en-la/112624)
- Apple: [MacBook Pro (15-inch, Early 2011) - Technical Specifications](https://support.apple.com/en-am/112599)
- Apple: [MacBook Pro (17-inch, Early 2011) - Technical Specifications](https://support.apple.com/en-bh/112598)
- EveryMac: [MacBook Pro "Core 2 Duo" 2.4 15" (Unibody) Specs](https://everymac.com/systems/apple/macbook_pro/specs/macbook-pro-core-2-duo-2.4-aluminum-15-late-2008-unibody-specs.html)
- EveryMac: [MacBook Pro "Core 2 Duo" 2.66 15" (SD) Specs](https://everymac.com/systems/apple/macbook_pro/specs/macbook-pro-core-2-duo-2.66-aluminum-15-mid-2009-sd-unibody-specs.html)
- EveryMac: [MacBook Pro "Core 2 Duo" 2.66 17" (Unibody) Specs](https://everymac.com/systems/apple/macbook_pro/specs/macbook-pro-core-2-duo-2.66-aluminum-17-early-2009-unibody-specs.html)
- EveryMac: [Differences Between 17-Inch MacBook Pro, Early 2009/Mid-2009](https://everymac.com/systems/apple/macbook_pro/macbook-pro-unibody-faq/differences-between-macbook-pro-17-inch-mid-2009-late-2008-unibody-core-2-duo.html)
