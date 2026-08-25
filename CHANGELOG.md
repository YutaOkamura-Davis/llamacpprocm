# Changelog

## 4.0.0 — 2026-08-23

- Retained the measured DFlash 2/llama.cpp RPC production topology and source
  pin; alternative engines remain isolated endpoints.
- Added a guarded native-Windows ROCm FreeToken adapter for Flow `gfx1151`,
  pinned to community fork commit `45675e47` and gated as experimental.
- Replaced the fork's non-parsing `$PIP install` wrapper statements with
  argument-safe v4 installation stages and a complete runtime dependency set.
- Added a pinned native-Windows ROCm vLLM lane. The audited patch changes only
  the wheel/build target and launcher tuning controls from `gfx1201` to
  `gfx1151`; the fork already contains Strix Halo-specific kernels.
- Added exact source, origin, diff, loopback, shell-argument, and VRAM gates
  around the native vLLM build and server, plus an opt-in finite-run stall gate.
- Added the released SystemPanic native-Windows CUDA vLLM wheel as a second
  hash-pinned lane. Its release explicitly targets Ampere and Ada, matching
  the Aurora RTX 3060/3060 Ti and Lenovo RTX 4080 Laptop.
- Added pinned WSL2 install/start paths for official FreeToken on NVIDIA and
  vLLM on CUDA or ROCm.
- Added native/WSL engine readiness reporting and an OpenAI-compatible
  concurrency benchmark with JSON/CSV results.
- Audited FreeToken's launcher and confirmed its tensor-parallel workers are
  local processes, not a cross-PC RPC mechanism.
- Added current assessments of SwarmLLM, prima.cpp, SGLang, and ik_llamafile.
- Documented WSL's default memory ceiling, Flow/Aurora/Lenovo experiment
  order, vLLM PP=2 on the unequal Aurora GPUs, and promotion/stability gates.

## 3.0.0 — 2026-08-23

- Moved the primary controller to the Flow so Qwen3.8 target and DFlash 2
  draft can run locally without a verification RPC boundary.
- Advanced new builds to optimized DFlash 2 commit `7ea40ee9`; marked the
  unchanged `1deefcca` SM89 binary as legacy and incompatible with v3 workers.
- Added Windows HIP SDK support and explicit Strix Halo `gfx1151` builds.
- Added automated Vulkan-versus-HIP sweeps across uBatch and context depth.
- Changed the hardware-specific DFlash defaults to four draft tokens and
  uBatch 256; documented required 4/5/7 and Q4/Q8/BF16 comparisons.
- Added Flow-local, remote-Lenovo-draft, reverse-RPC, heavy, and capacity
  profiles with an exact measurement order.
- Re-evaluated vLLM, SGLang, FreeToken, `ik_llama.cpp`, and Distributed Llama
  against their current primary documentation.
- Documented current text-only, single-slot DFlash/Vulkan correctness risks.

## 2.0.0 — 2026-08-23

- Corrected Aurora CUDA target from SM89 to auto-detected SM86 and documented
  its RTX 3060 12 GB plus RTX 3060 Ti 8 GB as two devices.
- Kept the original, hash-verified SM89 controller binaries unchanged.
- Added exact source-pin verification and per-node build manifests.
- Added richer node profiling and stricter private-link/firewall validation.
- Added RPC TCP/device-order preflight and worker dry-run/debug controls.
- Replaced raw capacity ratios with fastest-first, balanced, and capacity
  placement modes; added GGUF shard discovery and partial-offload estimates.
- Changed DFlash 2’s default draft width from 4 to the official value of 7.
- Added explicit batch/thread/KV/flash-attention/load/cache/API controls and
  disabled the currently problematic serializable RPC RAM cache by default.
- Added target-only and end-to-end server benchmark scripts.
- Recalculated current model sizes, separated fast/practical/capacity tiers,
  and documented current Qwen3.5/DeepSeek RPC/Vulkan risks.
