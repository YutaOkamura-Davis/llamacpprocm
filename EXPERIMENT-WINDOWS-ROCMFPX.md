# Windows DFlash2 + ROCmFPX experiment

Branch: `experiment/dflash2-rocmfpx-win`

## Goal

Build a Windows-only experimental llama.cpp tree that preserves the older DFlash2 draft-loader contract used by the public 58-tensor Q8 draft while importing the ROCmFP4/ROCmFPX tensor types and Vulkan kernels needed for Radeon 8060S (`gfx1151`) testing.

This branch is intentionally isolated from `main`. The current stable package remains pinned to `z-lab/llama.cpp-fork@7ea40ee98acb416787863aee935dbb99491acad5` until this experiment passes correctness and performance gates.

## Source pins

| Role | Repository | Pin |
|---|---|---|
| DFlash2 loader / speculative baseline | `z-lab/llama.cpp-fork` | `7ea40ee98acb416787863aee935dbb99491acad5` |
| ROCmFP4/ROCmFPX implementation donor | `charlie12345/ROCmFPX` | `c49ebdbd5c9f01ec242369f9e7f7967855f80cba` |

ROCmFPX documents CPU reference paths plus accelerated HIP/ROCm and Vulkan kernels, and its current tree includes Strix Halo (`gfx1151`) validation. We are not importing its whole runtime blindly; the purpose of this branch is to keep the older DFlash2 model contract while selectively porting quant/tensor/backend support.

## Invariants

1. The public Q8 DFlash2 draft must load with the older 58-tensor contract. An 81-tensor expectation is a hard failure for this experiment.
2. Target-model output must remain correct versus the stable build before any speed result is accepted.
3. Vulkan is the first Windows backend. HIP is a secondary comparison lane.
4. No Linux RADV-specific performance assumption is treated as portable to Windows AMD Vulkan drivers.
5. Every imported ROCmFPX file or hunk must be traceable to the donor commit above.
6. No change is promoted to `main` until the same prompts pass deterministic and low-temperature comparisons.

## Port order

### Phase A — source construction

- clone the DFlash2 baseline at the qualified commit;
- clone the ROCmFPX donor at the pinned commit;
- keep both trees side by side;
- record file hashes before porting;
- build the untouched DFlash baseline on Windows first.

### Phase B — tensor-format core

Port only the ROCmFP4/ROCmFPX format definitions, CPU reference dequant/vec-dot support, GGUF type plumbing, and quant metadata needed for model loading. Do not touch DFlash model loading yet.

Gate: normal non-DFlash ROCmFP4/FPX GGUF metadata can be inspected and CPU reference tests parse.

### Phase C — Vulkan backend

Port the Vulkan shader-generation and dispatch pieces for ROCmFP4/FPX. Keep Vulkan build files explicit and avoid unrelated donor-runtime changes.

Gate: `test-backend-ops` relevant quantized MUL_MAT / copy paths pass on Vulkan0, then a small compatible model generates coherent deterministic text.

### Phase D — DFlash2 integration

Preserve the DFlash code from the 58-tensor baseline. Resolve only compile/API conflicts created by the tensor/backend port. Do not replace `src/models/dflash.cpp` wholesale with the donor version.

Gate: the public Q8 DFlash2 draft loads without the 81-vs-58 tensor failure and the target+draft pair reaches generation.

### Phase E — performance qualification

Compare the stable 17.2 tok/s configuration against the experimental build with the same model, prompt, context, sampling, batch/ubatch, and draft settings.

Record:

- prompt-processing tok/s;
- decode tok/s;
- TTFT;
- speculative acceptance length/rate;
- output equality at temperature 0;
- low-temperature code-output validity;
- working-set / committed memory;
- GPU memory reported by Windows;
- driver version and Vulkan device string.

A 20–30 tok/s result would be a strong outcome but is not a pass criterion. Correctness comes first.

## Known donor evidence

The ROCmFPX project states that ROCmFP4/FPX has Vulkan kernels and CPU reference paths and reports Strix Halo Vulkan validation. Its published results are not directly transferable to this DFlash2 Windows hybrid because driver, model, quant, and speculative-decoding paths differ.

## Local start

```powershell
.\Prepare-ExperimentalSource.ps1
```

That creates side-by-side pinned trees without modifying either source. Use `-ForceRefresh` to discard and recreate only the generated experiment workspace.

Then follow the generated `experiment-source\PORTING-NEXT.txt` checklist. The first implementation commit should contain only tensor-format core changes; keep Vulkan and DFlash conflict resolution in separate commits so regressions are bisectable.
