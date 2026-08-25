# Revision 4 research ledger

Checked 2026-08-23. Technical decisions use project-owned documentation,
repositories, code, or issue trackers. Performance numbers from community
projects are treated as self-reported until reproduced on the user's systems.

| Project | Source inspected | Pin or observation used by v4 |
|---|---|---|
| DFlash 2 fork | https://github.com/z-lab/llama.cpp-fork | `7ea40ee98acb416787863aee935dbb99491acad5`; retained production pin |
| llama.cpp RPC | https://github.com/ggml-org/llama.cpp/tree/master/tools/rpc | Mixed-backend layer RPC remains the viable three-PC Windows path |
| FreeToken official | https://github.com/FlashML-org/FreeToken | `184a4f114d00b7805274841488f2906233b5a961`; Linux/NVIDIA/r580/CUDA 13 source requirements |
| FreeToken Windows ROCm fork | https://github.com/Maxritz/FreeToken-rocm-test | `45675e47348a167a9b36ca224ad310c1ee1e34b4`; verified by its author on gfx1201, adapted but not verified on gfx1151 |
| FreeToken Windows issue | https://github.com/FlashML-org/FreeToken/issues/82 | Tracks the community port; not evidence of an upstream-supported release |
| vLLM official | https://docs.vllm.ai/en/latest/getting_started/installation/gpu/ | No official native Windows; WSL or community-fork option; gfx1151 needs ROCm 7.0.2+ |
| vLLM scaling | https://docs.vllm.ai/en/latest/serving/parallelism_scaling/ | PP for uneven/no-NVLink GPUs; TCP socket is inefficient for cross-node TP |
| vLLM release | https://github.com/vllm-project/vllm/releases/tag/v0.27.1 | Current CUDA WSL installer pin |
| vLLM ROCm wheels | https://wheels.vllm.ai/rocm/vllm | Current index reports `0.27.1+rocm723`; exact Flow lab pin |
| vLLM Windows ROCm fork | https://github.com/charlie12345/vLLM_for_AMD | `windows-rocm` commit `89f703a1fb1dd583ff976b977d60cf5082532943`; native Windows vLLM 0.26.0 base, single GPU, tested upstream on gfx1201; source already contains gfx1151 kernels |
| AMD gfx1151 wheel index | https://repo.amd.com/rocm/whl/gfx1151/ | Contains the pinned CPython 3.12 Windows Torch 2.11.0, torchvision 0.26.0, and ROCm 7.13 components used by the vLLM adapter |
| vLLM Windows CUDA fork | https://github.com/SystemPanic/vllm-windows/releases/tag/v0.26.0 | Released Python 3.12/CUDA 13/PyTorch 2.11 wheel explicitly built for Ampere, Ada, and Blackwell; asset SHA-256 `3e15c3b8f847b47a87582c9a4451a88b6ab4ecad2d7e44298e3f4d43c7bf0f98` |
| AMD TheRock | https://github.com/ROCm/TheRock/blob/main/SUPPORTED_GPUS.md | gfx1151 Windows build, sanity-tested, and release-ready in current table |
| AMD device extras | https://github.com/ROCm/TheRock/blob/main/RELEASES.md | Ryzen AI Max+ PRO 395 maps to `device-gfx1151` |
| SGLang | https://github.com/sgl-project/sglang/issues/2249 | Native Windows remains an unfulfilled/inactive feature request |
| SwarmLLM | https://github.com/enapt/SwarmLLM | `ee215cc4cc30bb8296dcf99ac9a3e7464ab29101`; Windows local Vulkan, distributed NVIDIA CUDA, AMD/Intel distributed CPU |
| prima.cpp | https://github.com/OpenCPIL/prima.cpp | Windows and AMD/Vulkan still listed as future support |
| ik_llamafile | https://github.com/ikawrakow/ik_llamafile | Native Windows AMD/NVIDIA local option; not a cross-machine memory pool |

## Reproducibility boundary

The package builds and validates launchers but does not install ROCm nightly
wheels, change WSL settings, download models, or run GPU benchmarks on the
user's three systems. Those actions require the target hardware and current
drivers. Every experimental installer defaults to a plan and needs `-Apply`;
the native FreeToken and native vLLM ports additionally require
`-AcceptExperimentalRisk`.
