# Revision 4 runtime lab

Research date: 2026-08-23

This lab separates three different goals that are often confused:

1. lowest latency for one interactive request;
2. highest aggregate throughput for several requests;
3. loading the largest model at any usable speed.

No one runtime wins all three on this hardware. The production recommendation
is still DFlash 2/llama.cpp. Revision 4 adds guarded experiments for FreeToken
and vLLM and one benchmark that compares every OpenAI-compatible endpoint on
equal prompts.

## Decision

| Runtime | Native Windows | Uses Flow GPU | Pools the three PCs | Best role here | v4 status |
|---|---:|---:|---:|---|---|
| DFlash 2 + llama.cpp RPC | Yes | Vulkan or HIP | Yes, CUDA + AMD | Interactive DFlash and largest mixed-vendor GGUF | **Primary** |
| FreeToken official | No; WSL2 is Linux | No official AMD path | No; `tp-size` is local processes | MoE host-RAM offload on one NVIDIA PC | Candidate after r580/CUDA 13 gate |
| FreeToken Windows ROCm fork | Yes | Experimental `gfx1151` | No | Flow-local MoE/dense research | Experimental only |
| vLLM Windows ROCm fork | Yes | Experimental `gfx1151` | No; single GPU only | Flow-local continuous batching and HF quantized checkpoints | **Best new speed candidate; experimental** |
| vLLM Windows CUDA fork | Yes | No; NVIDIA only | Local multi-GPU with external NCCL DLL; no v4 cross-PC lane | Lenovo/Aurora native continuous batching | Candidate after CUDA 13 gate |
| vLLM official | WSL2; no native support | Yes if ROCm works inside WSL | NVIDIA-only collective experiment; not mixed vendor | Supported-upstream batched serving path | Candidate, single node first |
| SGLang | WSL2/Linux-oriented | Possible only through Linux ROCm | No supported mixed-vendor Windows pool | Homogeneous accelerator serving | Defer behind vLLM |
| SwarmLLM | Yes | Local Vulkan; distributed AMD falls back to CPU | Yes | Alpha layer-pipeline comparison | Optional measurement |
| prima.cpp | No Windows yet | No AMD/Vulkan | Not on this OS mix | Heterogeneous Linux research | Not viable now |

The key conclusion is that FreeToken and all vLLM lanes are additions, not replacements
for RPC. FreeToken's launcher starts every tensor-parallel rank on the same
machine and uses a loopback distributed address. vLLM supports real
multi-node execution, but its own guide calls raw TCP socket collectives
inefficient and recommends fast RDMA networking. The Flow's AMD GPU also
cannot join an NVIDIA NCCL group.

## What was adapted for Windows

### Native FreeToken on the Flow

The community `Maxritz/FreeToken-rocm-test` fork already parameterizes its
Windows installer and server launcher with `-Arch`. Revision 4 pins commit
`45675e47348a167a9b36ca224ad310c1ee1e34b4` and supplies `gfx1151` instead of
the fork's tested `gfx1201`. This is plausible because AMD's current TheRock
tables list Ryzen AI Max+ PRO 395 as `gfx1151`, with Windows builds,
sanity-testing, and release readiness. It is not the same as an end-to-end
FreeToken qualification.

The adapter performs these gates before changing anything:

- Python 3.12;
- a Windows ROCm/TheRock runtime containing `hipcc.exe`;
- `rocminfo` reporting `gfx1151`;
- the exact fork commit and expected git origin;
- explicit `-Apply -AcceptExperimentalRisk`.

It also fixes a concrete packaging defect without rewriting the engine: the
pinned fork's `dist/install.ps1` has three `$PIP install ...` statements that
do not parse as PowerShell. The v4 wrapper performs those stages with direct,
argument-safe Python invocations, installs the complete non-CUDA runtime
dependency set, then runs the fork's idempotent compatibility patcher.

Install plan only:

```powershell
.\Install-FreeToken-WindowsROCm.ps1 `
  -RocmPath C:\ROCm\TheRock -Architecture gfx1151
```

Install after reading the plan:

```powershell
.\Install-FreeToken-WindowsROCm.ps1 `
  -RocmPath C:\ROCm\TheRock -Architecture gfx1151 `
  -Apply -AcceptExperimentalRisk
```

Start with a small dense HF checkpoint, not GGUF:

```powershell
.\Start-FreeToken-WindowsROCm.ps1 `
  -Model D:\models\Qwen2.5-3B-Instruct `
  -RocmPath C:\ROCm\TheRock -Mode Dense
```

Then test `gpt-oss-20b` as an MoE experiment:

```powershell
.\Start-FreeToken-WindowsROCm.ps1 `
  -Model D:\models\gpt-oss-20b `
  -RocmPath C:\ROCm\TheRock -Mode MoE -KVPages 4096
```

The MoE wrapper deliberately forces fused eager execution
(`--moe-backend fused --cuda-graph-max-bs 0`). The fork reports graph replay
failures and an offload-backend failure on its tested RDNA4 card. Do not
enable Windows expert offload until a repeatable gfx1151 test proves it. The
fork's packed GGUF path is also incomplete, so a GGUF launch needs the
explicit `-AllowExperimentalGGUF` gate.

### Native vLLM on the Flow

The most promising new throughput path is the community
`charlie12345/vLLM_for_AMD` `windows-rocm` branch. It runs vLLM's real ROCm/HIP
engine on native Windows and retains continuous batching, PagedAttention, and
an OpenAI-compatible endpoint. The branch is vLLM 0.26.0-based and is
published as experimental, single-process/single-GPU, HF/Safetensors only;
its author's end-to-end measurements are on a Radeon PRO R9700 `gfx1201`, not
the Flow.

Revision 4 pins commit
`89f703a1fb1dd583ff976b977d60cf5082532943`. The useful discovery is that this
commit already contains `gfx1151` architecture support, Strix Halo-specific
W4A16 kernel selection, and tuned `gfx1151` Triton shapes. The checked-in
Windows setup still selects `gfx1201`, so the v4 patch changes only three
files:

- the AMD wheel index to AMD's `gfx1151` index and the device gate to
  `gfx1151`;
- `PYTORCH_ROCM_ARCH` and `CMAKE_HIP_ARCHITECTURES` to `gfx1151`;
- the launcher so hipBLASLt can be benchmarked on or off instead of inheriting
  an unqualified `gfx1201` assumption.

The installer verifies the exact commit, Git origin, complete three-file diff,
and patch hash before calling the fork's own setup. It defaults to a read-only
plan and requires the explicit risk gate:

```powershell
.\Install-vLLM-WindowsROCm.ps1

.\Install-vLLM-WindowsROCm.ps1 `
  -Apply -AcceptExperimentalRisk `
  -MaxJobs 12 -GuardWarnGiB 46 -GuardLimitGiB 50
```

Install `uv` and Visual Studio 2022 Build Tools with Desktop C++ first. The
pinned stack uses Python 3.12, Torch 2.11.0 + ROCm 7.13.0, the AMD `gfx1151`
wheel index, and Triton Windows 3.6.0.post26. AMD's TheRock table currently
marks Windows `gfx1151` build, sanity-test, and release-ready, and the required
CPython 3.12 Windows wheels exist in AMD's index. That validates the component
target—not this combined vLLM build.

Qualify a small model, then the fork's known larger model:

```powershell
.\Start-vLLM-WindowsROCm.ps1 `
  -Model Qwen/Qwen3-4B-AWQ -MaxModelLength 4096 -DryRun

.\Start-vLLM-WindowsROCm.ps1 `
  -Model openai/gpt-oss-20b `
  -MaxModelLength 8192 -GpuMemoryUtilization 0.70 `
  -KvCacheDtype fp8
```

The wrapper binds only to loopback, forces graph mode `NONE` initially, checks
the exact source diff again, and launches through the fork's fail-closed VRAM
watchdog. The stall monitor is optional because an idle API server legitimately
stops writing logs; enable it for finite benchmarks, not a quiet service. On
the Flow, the practical heavy challenger after those
gates is `Qwen/Qwen3-30B-A3B-Instruct-2507-FP8`; it is an experimental model
compatibility test, not a prequalified v4 claim. `Qwen3-Next-80B-A3B-FP8` and
gpt-oss-120b are too close to or above the safe 64 GB Windows budget once KV,
compiler, and OS reserves are included.

Run the same prompt sweep twice, with default hipBLASLt and with
`-DisableHipBlasLt`. The fork's large GEMM speedup was measured on `gfx1201`;
the winner on `gfx1151` must be measured. Native vLLM cannot pool the Lenovo or
Aurora because its Windows PyTorch path uses a single-rank c10d stand-in.

### Native vLLM on the NVIDIA machines

The community `SystemPanic/vllm-windows` project is now explicitly referenced
by the official vLLM Windows note. Its latest release during this research is
v0.26.0 for Python 3.12, PyTorch 2.11, and CUDA 13; the release says the wheel
contains kernels for Ampere, Ada, and Blackwell. That directly covers the
Aurora's RTX 3060/3060 Ti and the Lenovo's RTX 4080 Laptop.

Revision 4 pins the 255 MB release asset by its GitHub-published SHA-256
`3e15c3b8f847b47a87582c9a4451a88b6ab4ecad2d7e44298e3f4d43c7bf0f98`.
The installer never changes the NVIDIA driver and will not apply unless
`nvidia-smi` reports CUDA 13 capability:

```powershell
.\Install-vLLM-WindowsCUDA.ps1
.\Install-vLLM-WindowsCUDA.ps1 -Apply -AcceptExperimentalRisk
```

Start with a single GPU. On the Lenovo:

```powershell
.\Start-vLLM-WindowsCUDA.ps1 `
  -Model owner/quantized-model -CudaVisibleDevices 0 `
  -MaxModelLength 8192 -GpuMemoryUtilization 0.82
```

The fork advertises local tensor and pipeline parallelism, but it requires a
separately compiled Windows `nccl.dll`. v4 does not download or trust an
unversioned NCCL binary. A two-GPU Aurora launch is permitted only when
`-NcclDllPath` names a DLL you built and audited:

```powershell
.\Start-vLLM-WindowsCUDA.ps1 `
  -Model owner/quantized-model -CudaVisibleDevices 0,1 `
  -PipelineParallelSize 2 -TensorParallelSize 1 `
  -NcclDllPath C:\AI\nccl-windows\bin\nccl.dll
```

Use pipeline rather than tensor parallel on the Aurora because its 12 GB and
8 GB cards are unequal and have no NVLink. Even then, the smaller stage limits
the checkpoint and local PCIe transfers may erase the gain. Compare this lane
against official vLLM in WSL; the community Windows release is one vLLM minor
behind the official 0.27.1 lane. It does not make the Lenovo and Aurora into a
cross-PC memory pool.

### Official FreeToken under WSL2

This is the less invasive FreeToken route for Lenovo or Aurora. The official
source requirements are Linux x86-64, NVIDIA driver r580+, CUDA 13, and
`nvcc`. The v4 installer validates those requirements inside WSL and pins
official source commit `184a4f114d00b7805274841488f2906233b5a961`.

```powershell
.\Get-EngineReadiness.ps1 -Distro Ubuntu-24.04 `
  -OutputPath .\engine-readiness.json

.\Install-FreeToken-WSL.ps1 -Distro Ubuntu-24.04
.\Install-FreeToken-WSL.ps1 -Distro Ubuntu-24.04 -Apply
```

Calibrate the machine before choosing a MoE path:

```powershell
.\Start-FreeToken-WSL.ps1 `
  -Distro Ubuntu-24.04 -Model owner/model `
  -MoeBackend auto -CalibrateBandwidth
```

Repeat with `offload` and `hybrid`. On the Aurora's DDR4 and Lenovo's DDR5,
the winner depends on measured host bandwidth and PCIe transfer rate. A model
that fits fully in VRAM should normally stay on the faster ordinary engine;
FreeToken becomes interesting when sparse experts spill into the 32 GB host
RAM.

### Official vLLM under WSL2

Official vLLM does not support native Windows and explicitly recommends WSL
or a community fork. The v4 WSL lane therefore leaves the official package
unchanged and keeps its API on loopback.

For Lenovo or Aurora CUDA, v4 pins the current official release used in this
research, `0.27.1`:

```powershell
.\Install-vLLM-WSL.ps1 `
  -Distro Ubuntu-24.04 -Backend CUDA
.\Install-vLLM-WSL.ps1 `
  -Distro Ubuntu-24.04 -Backend CUDA -Apply
```

For the Flow ROCm experiment, v4 pins the official wheel index's current
`0.27.1+rocm723` build. vLLM says Ryzen AI MAX/AI 300
(`gfx1151`/`gfx1150`) needs ROCm 7.0.2 or newer. Proceed only when
`Get-EngineReadiness.ps1` sees `gfx1151` from `rocminfo` inside WSL:

```powershell
.\Install-vLLM-WSL.ps1 `
  -Distro Ubuntu-24.04 -Backend ROCm `
  -RocmVariant rocm723 -RocmArchitecture gfx1151
```

The live wheel index is newer than the version table on the installation
page, so v4 records both the exact release and wheel variant. The Flow path
is still a lab lane because the Windows-to-WSL AMD GPU stack must be validated
on the exact driver. If it fails the readiness probe, use native llama.cpp
HIP/Vulkan instead of forcing an unsupported wheel combination.

Start a single GPU:

```powershell
.\Start-vLLM-WSL.ps1 `
  -Distro Ubuntu-24.04 -Model owner/model `
  -MaxModelLength 8192 -GpuMemoryUtilization 0.88
```

On the Aurora, first compare one GPU with pipeline parallel across its two
unequal GPUs:

```powershell
.\Start-vLLM-WSL.ps1 `
  -Distro Ubuntu-24.04 -Model owner/quantized-model `
  -PipelineParallelSize 2 -TensorParallelSize 1 `
  -MaxModelLength 8192 -GpuMemoryUtilization 0.86
```

vLLM's guide recommends pipeline parallelism for uneven GPU splits and for
GPUs without NVLink. Do not start with tensor parallelism on the Aurora's
12 GB + 8 GB pair.

For a heavy single-machine test, sweep CPU offload rather than guessing:

```powershell
foreach ($offload in 0, 8, 16) {
  .\Start-vLLM-WSL.ps1 `
    -Distro Ubuntu-24.04 -Model owner/quantized-model `
    -CpuOffloadGiB $offload -MaxModelLength 8192
}
```

Weight offload is not free capacity. vLLM moves offloaded parameters through
the CPU/GPU link during forward passes, so the largest value may be the
slowest. On Strix Halo, unified physical memory does not guarantee that every
WSL ROCm/UVA path is optimized.

## WSL memory matters

WSL assigns 50% of Windows memory by default. That silently reduces a 64 GB
Flow to about 32 GB and a 32 GB NVIDIA machine to about 16 GB before model
overhead. If WSL is used for a heavy model, create or merge a Windows
`%UserProfile%\.wslconfig`, then run `wsl --shutdown`:

Flow example:

```ini
[wsl2]
memory=52GB
swap=12GB
localhostForwarding=true
```

Lenovo/Aurora example:

```ini
[wsl2]
memory=24GB
swap=8GB
localhostForwarding=true
```

Leave enough memory for Windows, drivers, file cache, and the desktop. A swap
file is emergency headroom, not fast model memory.

## Multi-node vLLM and SGLang: what not to assume

The three NVIDIA devices total about 32 GB VRAM, but they are split across
two PCs, have unequal speed and capacity, and lack NVLink/InfiniBand. vLLM
can form a multi-node pipeline through Ray or its multiprocessing launcher,
but every token crosses the ordinary network between stages. The official
documentation says `NET/Socket` is inefficient for cross-node tensor
parallelism.

If this experiment is attempted later:

1. use only Lenovo + Aurora NVIDIA GPUs;
2. use pipeline parallelism, not cross-node tensor parallelism;
3. keep the model on local NVMe on both nodes;
4. require a private 10 GbE link and identical WSL/container environments;
5. compare against the Flow-local and DFlash RPC baselines;
6. stop if concurrency-one latency loses badly or the cluster is unstable.

SGLang has the same OS and collective-network problem, while adding no clear
advantage for this one-user mixed-vendor setup. Its multi-node and
disaggregated examples target homogeneous Linux accelerator clusters. v4
therefore benchmarks vLLM first and does not add a second near-duplicate WSL
installer.

## Other Windows candidates

SwarmLLM is the only newly researched native-Windows layer-pipeline candidate
worth watching. Its Windows release uses Vulkan for local AMD/NVIDIA/Intel,
but distributed GPU execution is CUDA-only; an AMD/Intel Windows node
contributes CPU to distributed inference. That strands the Flow's strongest
resource in the exact scenario where it matters. The project is also alpha,
and its published single-node table is 3B-class rather than proof that this
specific 70B three-node topology is fast. If tested, point
`Compare-OpenAIEngines.ps1` at its OpenAI endpoint and treat it as an
experimental capacity result.

prima.cpp has attractive piped-ring and heterogeneity-aware scheduling, but
its official README still says Windows and AMD/Vulkan are future work.
`ik_llamafile` is convenient on native Windows and can use AMD or NVIDIA
locally, but “distribute” refers to shipping a self-contained model program,
not pooling these PCs. Neither replaces RPC in v4.

## Measurement protocol

First establish readiness:

```powershell
.\Get-EngineReadiness.ps1 -Distro Ubuntu-24.04 |
  Set-Content .\engine-readiness.json
```

Copy `engine-lab.example.json`, remove endpoints that are not running, and
set the exact served model names. Then run:

```powershell
.\Compare-OpenAIEngines.ps1 `
  -ConfigFile .\engine-lab.json `
  -Concurrency 1,2,4 -Warmup 1 -Repetitions 5 `
  -MaxTokens 256 -OutputDirectory .\benchmark-results
```

Interpret the report as follows:

- concurrency 1: interactive latency and output rate;
- concurrency 2/4: aggregate serving throughput;
- successful model size plus context: capacity;
- identical output hashes: a basic deterministic consistency signal, not a
  complete correctness proof.

Promote an alternative only if it is stable for a 30-minute mixed prompt
run and wins the relevant metric by at least 10%. Small differences disappear
with driver clocks, thermal state, cache warmth, and model-format changes.
Never compare a low-bit model in one runtime with BF16 in another and call
the result an engine speedup.

## Recommended order on the actual machines

1. Flow-local DFlash target + draft, Vulkan versus HIP.
2. Flow-controller DFlash with Lenovo remote draft.
3. DFlash heavy GGUF placement across Flow, Lenovo, then Aurora devices only
   as capacity requires.
4. Native vLLM `gfx1151`, first Qwen3-4B-AWQ, then gpt-oss-20b, then the 30B
   FP8 MoE challenger; sweep hipBLASLt and KV-cache dtype.
5. Native FreeToken `gfx1151`, first 3B dense, then gpt-oss-20b fused/eager.
6. Native Windows CUDA vLLM on Lenovo; Aurora PP=2 only with an audited NCCL
   DLL. Compare the same checkpoint against the official WSL lane.
7. vLLM WSL single-node on Lenovo and Aurora; Aurora PP=2 challenger.
8. Official FreeToken WSL on whichever NVIDIA PC passes r580/CUDA 13 and the
   `ft bench bw` calibration.
9. vLLM ROCm WSL on Flow only if the WSL `rocminfo` gate passes.
10. SwarmLLM or multi-node vLLM only after all single-node baselines exist.

For fastest interactive use, expect step 1 to win. For batched requests,
vLLM may win on a compatible quantized checkpoint. For the heaviest possible
model, DFlash RPC remains the first choice because it is the only path here
that uses the Flow GPU and both NVIDIA PCs in one Windows model placement.

## Primary sources

- [FreeToken official installation requirements](https://github.com/FlashML-org/FreeToken/blob/main/docs/install.md)
- [FreeToken CLI and MoE backends](https://github.com/FlashML-org/FreeToken/blob/main/docs/cli.md)
- [FreeToken Windows ROCm tracking issue](https://github.com/FlashML-org/FreeToken/issues/82)
- [Community FreeToken Windows ROCm fork](https://github.com/Maxritz/FreeToken-rocm-test)
- [Community native-Windows ROCm vLLM fork](https://github.com/charlie12345/vLLM_for_AMD)
- [Community native-Windows CUDA vLLM v0.26.0 release](https://github.com/SystemPanic/vllm-windows/releases/tag/v0.26.0)
- [AMD gfx1151 Python wheel index](https://repo.amd.com/rocm/whl/gfx1151/)
- [AMD TheRock supported GPUs](https://github.com/ROCm/TheRock/blob/main/SUPPORTED_GPUS.md)
- [AMD TheRock release/device-extra mapping](https://github.com/ROCm/TheRock/blob/main/RELEASES.md)
- [vLLM GPU installation and Windows/WSL note](https://docs.vllm.ai/en/latest/getting_started/installation/gpu/)
- [vLLM parallelism and network guidance](https://docs.vllm.ai/en/latest/serving/parallelism_scaling/)
- [vLLM engine arguments and CPU offload](https://docs.vllm.ai/en/latest/configuration/engine_args/)
- [SwarmLLM Windows platform matrix](https://github.com/enapt/SwarmLLM#platform-support)
- [prima.cpp platform limitations](https://github.com/OpenCPIL/prima.cpp)
- [SGLang Windows feature request](https://github.com/sgl-project/sglang/issues/2249)
