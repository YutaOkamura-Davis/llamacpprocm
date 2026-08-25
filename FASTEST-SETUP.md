# Fastest setup for the Flow Z13, Lenovo 7i, and Aurora R10

Research and package date: 2026-08-23

Revision 4 keeps the proven DFlash layout and adds separate FreeToken/vLLM
lanes. They are not silently substituted into the cluster: run the DFlash
baseline first, then follow `RUNTIME-LAB.md` and promote an alternative only
when the cross-engine benchmark wins on the metric you need.

## Recommended result

Use two profiles instead of forcing one topology to do everything.

| Profile | Controller and placement | Purpose |
|---|---|---|
| **Fast** | Flow controller; Qwen3.8-27B target and DFlash 2 draft both on local `Vulkan0` or `ROCm0` | Lowest-latency interactive setup |
| **Fast RPC** | Flow controller; target local; Lenovo RTX 4080 draft on `RPC0` | Tests whether faster NVIDIA draft compute beats one RPC boundary |
| **Heavy** | Flow controller; Flow local first, then Lenovo 4080, Aurora 3060 12 GB, Aurora 3060 Ti 8 GB | Maximum useful accelerator capacity |
| **Capacity** | Heavy profile plus Aurora CPU and, if necessary, controller CPU layers | Load experiments only; not a fast profile |

This recommendation is intentionally benchmark-driven. Vulkan has usually
won interactive Strix Halo decode in published llama.cpp results, while HIP
has won on some Windows driver combinations. Build both. The local Flow
profile is the baseline that an RPC layout must beat.

## 1. Physical setup

For three-node RPC, use one private 10 GbE or faster switch so the Flow can
reach both NVIDIA machines without routing through the Lenovo. Give every
node a static address on the private subnet and allow the RPC port only from
the controller. Keep Wi-Fi, VPN, and Internet-facing adapters out of the RPC
route.

The later commands assume Flow `10.20.0.1`, Lenovo `10.20.0.2`, and Aurora
`10.20.0.3` on a `/29`. For example, run the helper elevated on each worker
with the Flow address as `PeerAddress`; use `-PrefixLength 29` instead of its
point-to-point `/30` default. Preview each change with `-WhatIf` first.

Before inference:

- connect AC power and select each vendor's maximum-performance mode;
- keep the laptop cooling paths unobstructed;
- install current NVIDIA, AMD, chipset, and network drivers;
- put models and `LLAMA_CACHE` on local NVMe storage;
- leave an OS reserve instead of assigning all reported memory to weights;
- use a system-managed NVMe pagefile only as crash headroom, never as fast
  model memory.

Run `Collect-NodeProfile.ps1` on all three machines and run `iperf3` between
the future controller and each worker. For a nominal 10 GbE link, roughly
8.5 Gbit/s or better sustained throughput with sub-millisecond LAN latency is
a sensible qualification target. This is a practical gate, not a llama.cpp
requirement.

## 2. Rebuild one exact revision everywhere

Revision 4 pins `z-lab/llama.cpp-fork` commit
`7ea40ee98acb416787863aee935dbb99491acad5`. Never mix it with the included
legacy SM89 binary, which came from the older `1deefcca...` commit.

On the Flow, install Visual Studio C++ Build Tools, CMake, Ninja, Git, and the
LunarG Vulkan SDK. Build the controller:

```powershell
.\Build-Node.ps1 -Backend Vulkan -Role Controller `
  -SourceDirectory C:\llama-dflash2 -Parallel 12
```

AMD's Windows HIP SDK 7.2 supports the Ryzen AI Max+ 395 (`gfx1151`). Install
it and build the challenger backend from the same source pin:

```powershell
.\Build-Node.ps1 -Backend HIP -Role Controller `
  -SourceDirectory C:\llama-dflash2 -HipArchitectures gfx1151 `
  -EnableAllCudaKvQuants -Parallel 12
```

On the Lenovo, install CUDA and build SM89. Building the controller also
produces the RPC server needed by the Flow-controller profile:

```powershell
.\Build-Node.ps1 -Backend CUDA -Role Controller `
  -SourceDirectory C:\llama-dflash2 -CudaArchitectures auto `
  -EnableAllCudaKvQuants -Parallel 12
```

On the Aurora, build both Ampere GPUs into an SM86 worker:

```powershell
.\Build-Node.ps1 -Backend CUDA -Role Worker `
  -SourceDirectory C:\llama-dflash2 -CudaArchitectures auto `
  -EnableAllCudaKvQuants -Parallel 12
```

Inspect each generated `BUILD-LOCAL.json`. The commit must match on all
nodes; Flow must say `gfx1151`, Lenovo must say `89`, and Aurora must say
`86`.

## 3. Choose Vulkan or HIP on the Flow

Use the same Qwen3.8 target to sweep prompt processing, generation, context
depth, and micro-batch size:

```powershell
.\Compare-FlowBackends.ps1 `
  -VulkanBench C:\llama-dflash2\build-vulkan\bin\llama-bench.exe `
  -HipBench C:\llama-dflash2\build-hip\bin\llama-bench.exe `
  -Model D:\models\Qwen3.8-27B-Q4_K_M.gguf `
  -UBatchSize 128,256,512 -DepthTokens 0,8192,32768 `
  -Repetitions 3
```

The script writes raw JSONL plus `flow-backend-best.csv`. Select the backend
that wins **generation at the context depth you actually use**. Prompt speed
matters for long one-off documents; generation speed usually matters more for
interactive agents. Re-run after every AMD driver update.

Use `Vulkan0` with `build-vulkan`, and `ROCm0` with `build-hip`. A device-name
mismatch is a configuration error, not a slow fallback.

## 4. Start the absolute-fast local profile

Download the Q4_K_M target and draft from `MODEL-SOURCES.md`. For Vulkan:

```powershell
.\Start-Controller.ps1 `
  -Server C:\llama-dflash2\build-vulkan\bin\llama-server.exe `
  -Model D:\models\Qwen3.8-27B-Q4_K_M.gguf `
  -DeviceList Vulkan0 -TensorSplit 1 `
  -DraftModel D:\models\Qwen3.8-27B-DFlash2-Q4_K_M.gguf `
  -DraftDevice Vulkan0 -DraftTokens 4 `
  -ContextSize 32768 -ParallelSlots 1 `
  -BatchSize 2048 -UBatchSize 256
```

For HIP, change the executable directory to `build-hip` and both device
values to `ROCm0`.

The package defaults already select q8_0 target K/V, f16 draft K/V, flash
attention, direct-I/O loading, and no serializable RAM prompt cache. These are
safe performance starting points, not universal winners.

Measure the non-speculative server first by omitting `-DraftModel`, then run
the same prompt suite with:

- draft widths 4, 5, and 7;
- Q4_K_M, Q8_0, and BF16 draft files if storage permits;
- uBatch 128, 256, and 512.

The published Strix Halo width result used a UD-Q4_K_XL target and only two
runs; it is strong evidence for the starting default, not a substitute for
your Q4_K_M measurement.

After each launch:

```powershell
.\Measure-Server.ps1 `
  -Endpoint http://127.0.0.1:8080/v1/chat/completions `
  -MaxTokens 256 -Warmup 1 -Repetitions 5
```

Keep temperature, sampler, prompt, context, cache state, and reasoning effort
identical. Reject a result that crashes, hangs, or changes deterministic
greedy output even if it reports higher throughput.

## 5. Find the fastest RPC profile

The most promising RPC test keeps the target local on the Flow and exposes
only the Lenovo 4080 as the draft device. On Lenovo:

```powershell
.\Start-RpcWorker.ps1 `
  -RpcServer C:\llama-dflash2\build-cuda\bin\ggml-rpc-server.exe `
  -BindAddress 10.20.0.2 -Device CUDA0 `
  -CacheDirectory D:\llama-rpc-cache
```

Probe from the Flow and record the reported device order:

```powershell
.\Test-RpcCluster.ps1 `
  -ControllerServer C:\llama-dflash2\build-vulkan\bin\llama-server.exe `
  -Rpc 10.20.0.2:50052 -ProbeModel D:\models\Qwen3.8-27B-Q4_K_M.gguf
```

If the Lenovo appears as `RPC0`, launch on the Flow:

```powershell
.\Start-Controller.ps1 `
  -Server C:\llama-dflash2\build-vulkan\bin\llama-server.exe `
  -Model D:\models\Qwen3.8-27B-Q4_K_M.gguf `
  -Rpc 10.20.0.2:50052 `
  -DeviceList Vulkan0 -TensorSplit 1 `
  -DraftModel D:\models\Qwen3.8-27B-DFlash2-Q4_K_M.gguf `
  -DraftDevice RPC0 -DraftTokens 4 `
  -ContextSize 32768 -UBatchSize 256
```

Compare it to the reverse layout: Lenovo controller, local `CUDA0` draft,
and the entire target on Flow `RPC0`. Also compare a split target only if a
qualified 10 GbE link is present. The winning **RPC** setup is whichever beats
the other RPC layouts end to end; if none beats Flow-local, use RPC only for
models that need its capacity.

## 6. Heavy accelerator profile

Run one worker endpoint on Lenovo (`CUDA0`) and one on Aurora exposing both
GPUs (`CUDA0,CUDA1`). From the Flow controller, device discovery should
normally produce:

```text
Vulkan0 or ROCm0   Flow unified GPU, local
RPC0               Lenovo RTX 4080 Laptop 12 GB
RPC1               first Aurora NVIDIA GPU
RPC2               second Aurora NVIDIA GPU
```

Do not trust that example order blindly; `Test-RpcCluster.ps1` is
authoritative. Use live free memory from worker startup logs and preserve
separate reserves:

```powershell
$plan = .\Get-TensorSplit.ps1 `
  -Device @('Vulkan0','RPC0','RPC1','RPC2') `
  -FreeMiB @(50000,11200,11200,7200) `
  -ReserveMiB @(6000,1800,1500,1200) `
  -RelativeSpeed @(2.0,4.0,1.8,2.2) `
  -ModelPath D:\models\gpt-oss-120b-MXFP4.gguf `
  -PlacementMode Fastest | ConvertFrom-Json
```

Replace every illustrative number. `Fastest` uses only the memory required
and fills faster devices first; that often beats spreading a model across all
available devices. Start at 8K context:

```powershell
.\Start-Controller.ps1 `
  -Server C:\llama-dflash2\build-vulkan\bin\llama-server.exe `
  -Model D:\models\gpt-oss-120b-MXFP4.gguf `
  -Rpc @('10.20.0.2:50052','10.20.0.3:50052') `
  -DeviceList $plan.DeviceList -TensorSplit $plan.TensorSplit `
  -ContextSize 8192 -ParallelSlots 1 -FitPrint
```

Qualification order:

1. Qwen3.5-122B-A10B IQ2_XXS, 34.12 GiB, as the all-local Flow
   100B-class speed challenger; accept the low-bit quality tradeoff only after
   evaluation;
2. gpt-oss-120b MXFP4, 59.03 GiB, as the first full-RPC qualification;
3. Qwen3.5-122B-A10B Q4_K_S, 66.78 GiB, only after Vulkan correctness tests;
4. Qwen3.5-122B-A10B Q4_K_M, 71.28 GiB;
5. MiniMax-M2.5 IQ2_XXS, 69.03 GiB;
6. Qwen3.5-397B-A17B IQ1_M, 99.48 GiB, capacity experiment only.

Only after accelerator-only placement fails should the Aurora worker expose
`CPU`. The Flow CPU and GPU share the same physical 64 GB, so never expose
both and add their reported sizes. For a 397B experiment, use small context,
remote Aurora CPU, partial controller CPU layers, and expect very low speed.

## 7. Where the other engines fit in revision 4

| Engine | Use it for | Decision on this hardware |
|---|---|---|
| DFlash 2 fork + llama.cpp RPC | Qwen3.8 speculation and mixed CUDA/AMD Windows aggregation | Primary engine |
| Current mainline llama.cpp | Heavy GGUF baseline when DFlash is unused | Re-test after relevant RPC/Vulkan fixes land |
| FreeToken official under WSL2 | Single NVIDIA-machine MoE experiment with CPU–GPU expert offload | Useful after the r580/CUDA 13 gate, but `tp-size` is local and cannot pool these PCs |
| FreeToken Windows ROCm fork | Flow-local dense/MoE research | v4 adapts its architecture parameter to `gfx1151`; the fork was verified on `gfx1201`, and Windows offload/GGUF remain experimental |
| `ik_llama.cpp` | CUDA/CPU MoE and very low-bit quant experiments | Strong on NVIDIA/CPU; its own README says Vulkan/ROCm are not fully performant, so it strands the Flow |
| vLLM Windows ROCm fork | Flow-local HF/Safetensors continuous batching | Best new speed experiment: v4 retargets an existing native HIP build with gfx1151-tuned kernels; single-GPU and not yet Flow-qualified |
| vLLM Windows CUDA fork | Native Lenovo/Aurora continuous batching | Released wheel covers Ampere/Ada; CUDA 13 required, and local multi-GPU needs a separately built NCCL DLL |
| vLLM official under WSL2 | Single-node batched CUDA/ROCm serving; Aurora PP=2 experiment | No official native Windows; cross-node tensor parallelism over raw TCP is explicitly inefficient, and AMD cannot join NVIDIA NCCL |
| SGLang | Homogeneous Linux accelerator serving and batching | Same OS/collective blockers as vLLM with no clear gain for this topology; defer |
| SwarmLLM | Native-Windows alpha layer-pipeline experiment | Local AMD uses Vulkan, but distributed AMD/Intel uses CPU while only NVIDIA gets distributed GPU execution |
| prima.cpp | Heterogeneous piped-ring research | Official project still lists Windows and AMD/Vulkan as future work |
| Distributed Llama | CPU/Vulkan research across commodity nodes | Only power-of-two node counts and Q4_0/F32 quantization make it a poor match for this three-node quality target |

For a separate Linux-on-Flow experiment, the Nathanw1014 Strix Halo fork is
the most relevant optimized challenger. Its published gains focus on Vulkan
prefill, deep-context quantized K/V, and MoE kernels, and it recommends Vulkan
on this APU. It is based on a different llama.cpp lineage and does not provide
this pinned DFlash 2 cluster, so benchmark it as a standalone target-only or
heavy-model profile; never mix its RPC binary with revision 4 workers.

FreeToken is most interesting when a sparse MoE model exceeds local VRAM but
fits local host RAM. Its official source path still requires Linux x86_64,
NVIDIA r580+, and CUDA 13. Revision 4 also includes a guarded native-Windows
ROCm fork adapter for the Flow, but it forces the currently safer fused/eager
MoE path and is not a production recommendation.

For vLLM, start with one machine. On the Aurora, compare pipeline-parallel
size 2 with a single-GPU run because its GPUs have unequal VRAM and no NVLink.
Test CPU offload at 0, 8, and 16 GiB; extra capacity can reduce speed. Only
after these baselines should multi-node NVIDIA pipeline parallelism be
considered. Exact commands and WSL memory limits are in `RUNTIME-LAB.md`.

On the Flow, test the native Windows ROCm vLLM adapter before the WSL ROCm
lane. Its pinned fork already contains `gfx1151`/Strix Halo kernel tuning, so
v4 only retargets the wheel index and build architecture. Start with
Qwen3-4B-AWQ, then gpt-oss-20b, then the 30B FP8 MoE challenger. Compare
hipBLASLt enabled and disabled; do not extrapolate the fork author's gfx1201
result to gfx1151. This engine is for throughput on one Flow GPU, not RPC.

On the Lenovo, compare the hash-pinned native Windows CUDA vLLM wheel with the
official WSL wheel using the same quantized checkpoint. The community release
explicitly includes Ada and Ampere kernels. On Aurora, WSL PP=2 remains the
easier first test; native PP=2 is gated on a separately built Windows NCCL DLL
and the 8 GB card still limits the pipeline stage.

## 8. Stability limits

- DFlash 2 pull request `#27342` is still open.
- Use text-only requests and one parallel slot while qualifying DFlash 2.
- Current reports cover deterministic greedy divergence, multimodal cache
  holes, Vulkan multi-slot/speculative regressions, and a Vulkan server hang
  after a client abort. Treat correctness as part of the benchmark.
- llama.cpp labels RPC proof-of-concept, fragile, unauthenticated, and
  unencrypted. Keep it on a peer-firewalled private network.
- `--load-mode dio` avoids a reported large UMA/RPC mmap hang; it does not
  make the RPC protocol secure.

## Primary sources

- [DFlash 2 llama.cpp pull request and performance discussion](https://github.com/ggml-org/llama.cpp/pull/27342)
- [DFlash 2 GGUF model card, sizes, and seven-token quick start](https://huggingface.co/z-lab/Qwen3.8-27B-DFlash2-GGUF)
- [Pinned optimized DFlash 2 commit](https://github.com/z-lab/llama.cpp-fork/commit/7ea40ee98acb416787863aee935dbb99491acad5)
- [llama.cpp RPC documentation](https://github.com/ggml-org/llama.cpp/tree/master/tools/rpc)
- [AMD HIP SDK 7.2 Windows system requirements](https://rocm.docs.amd.com/projects/install-on-windows/en/docs-7.2/reference/system-requirements.html)
- [Strix Halo llama.cpp Vulkan/HIP tuning project](https://github.com/Nathanw1014/strix-halo-llamacpp)
- [vLLM supported GPU platforms and Windows limitation](https://docs.vllm.ai/en/latest/getting_started/installation/gpu/)
- [vLLM parallelism and network guidance](https://docs.vllm.ai/en/stable/serving/parallelism_scaling/)
- [Native-Windows ROCm vLLM community fork](https://github.com/charlie12345/vLLM_for_AMD)
- [Native-Windows CUDA vLLM v0.26.0 release](https://github.com/SystemPanic/vllm-windows/releases/tag/v0.26.0)
- [AMD gfx1151 Windows wheel index](https://repo.amd.com/rocm/whl/gfx1151/)
- [SGLang quick start and platform requirements](https://github.com/sgl-project/sglang/blob/main/docs/docs/get-started/quickstart.mdx)
- [FreeToken requirements and MoE backends](https://github.com/FlashML-org/FreeToken/blob/main/docs/install.md)
- [FreeToken Windows ROCm community port](https://github.com/Maxritz/FreeToken-rocm-test)
- [AMD TheRock `gfx1151` Windows status](https://github.com/ROCm/TheRock/blob/main/SUPPORTED_GPUS.md)
- [SwarmLLM Windows platform matrix](https://github.com/enapt/SwarmLLM#platform-support)
- [prima.cpp platform limitations](https://github.com/OpenCPIL/prima.cpp)
- [`ik_llama.cpp` backend support statement](https://github.com/ikawrakow/ik_llama.cpp#tldr)
- [Distributed Llama limits](https://github.com/b4rtaz/distributed-llama#known-limitations)
- [Large UMA mmap hang and `-dio` workaround](https://github.com/ggml-org/llama.cpp/issues/19745)
- [DFlash greedy divergence](https://github.com/ggml-org/llama.cpp/issues/27407)
- [DFlash multimodal cache holes](https://github.com/ggml-org/llama.cpp/issues/27408)
- [Vulkan speculative/multi-slot regression](https://github.com/ggml-org/llama.cpp/issues/27544)
- [Vulkan server abort hang](https://github.com/ggml-org/llama.cpp/issues/27604)
