# DFlash 2 + mixed Windows RPC cluster

Revision 4 is tuned for the actual three machines, including the ASUS Flow
Z13 2025 Strix Halo. Start with `FASTEST-SETUP.md` for the production path
and `RUNTIME-LAB.md` for the new FreeToken, vLLM, and alternative-runtime
experiments.

## The short answer

| Goal | Recommended starting point |
|---|---|
| Fastest Qwen3.8-27B + DFlash 2 | Flow as controller; target and draft both local; Vulkan first, HIP as the measured challenger |
| Fastest setup that actually uses RPC | Flow controller with local target and Lenovo `RPC0` draft; compare against Lenovo controller + Flow target |
| Largest practical model | Flow controller with the largest model share local, then Lenovo 4080 and both Aurora GPUs over RPC |
| Absolute capacity experiment | Add Aurora CPU and partial local CPU layers only after GPU-only placement fails |
| Highest batched throughput experiment | Native vLLM ROCm on Flow; compare native CUDA and official WSL2 on Lenovo; Aurora PP=2 under WSL first |
| MoE host-offload experiment | FreeToken on one machine; native Windows ROCm on Flow is explicitly experimental |

The key correction is controller placement. The 17.67 GiB Q4 target plus the
1.06–3.59 GiB draft fit easily in the Flow's unified memory. Keeping both
local removes a network boundary from every speculative verification cycle.
For large models, making the 64 GB machine the controller also keeps the
largest weight share beside the scheduler.

The hardware-specific defaults are now four draft tokens, micro-batch 256,
one parallel slot, q8_0 target K/V, f16 draft K/V, flash attention on, and
direct-I/O load mode. The official quick start uses seven draft tokens, but
published Strix Halo measurements in the DFlash 2 pull request show four can
be faster, especially at deep context. Benchmark 4, 5, and 7.

## Important binary compatibility rule

`Build-Node.ps1` pins DFlash 2 commit
`7ea40ee98acb416787863aee935dbb99491acad5`, which includes the newest DFlash 2
cost optimization available on 2026-08-23. Every v4 controller and RPC worker
must be rebuilt from that exact commit.

The supplied `bin-cuda-sm89` directory is preserved unchanged for audit and
legacy comparison. It was built from the older commit
`1deefcca395743049c3820ab8f9b15043f3e9446`; do not attach it to a v4 worker.

## What revision 4 adds

- a guarded native-Windows ROCm `gfx1151` adapter for the current community
  FreeToken port, pinned by source commit;
- an exact three-file `gfx1151` retarget for the native-Windows ROCm vLLM
  fork, with source/diff verification and a fail-closed VRAM watchdog;
- a hash-pinned native-Windows CUDA vLLM wheel lane explicitly built for the
  Ampere/Ada GPUs in the Aurora and Lenovo;
- pinned WSL2 installers and loopback launchers for official FreeToken and
  vLLM CUDA/ROCm lanes;
- readiness probes that distinguish native GPU support from WSL GPU support;
- a concurrency-aware benchmark for any OpenAI-compatible endpoint;
- an audited runtime decision covering SGLang, SwarmLLM, prima.cpp, and
  `ik_llamafile` as well as FreeToken and vLLM;
- all prior DFlash build, RPC, placement, and backend-comparison tools.

## Package map

| File | Purpose |
|---|---|
| `FASTEST-SETUP.md` | Exact fastest/local/RPC/heavy build and benchmark sequence |
| `RUNTIME-LAB.md` | FreeToken/vLLM adaptations, hard gates, and measured promotion rules |
| `ANALYSIS.md` | Audit, engine comparison, model tiers, and upstream risks |
| `RESEARCH-SOURCES.md` | Primary-source ledger and exact experimental source pins |
| `MODEL-SOURCES.md` | Exact GGUF sources, variants, sizes, and download order |
| `Build-Node.ps1` | Pinned CUDA, Vulkan, HIP, or CPU build for controller/worker |
| `Compare-FlowBackends.ps1` | Same-model Vulkan-versus-HIP sweep on the Flow |
| `Collect-NodeProfile.ps1` | Hardware, free-memory, network, disk, and power inventory |
| `Configure-PrivateLink.ps1` | Static private IPv4 plus peer-only firewall rule |
| `Start-RpcWorker.ps1` | Guarded CUDA, Vulkan, HIP, or CPU RPC worker |
| `Test-RpcCluster.ps1` | TCP and authoritative RPC device-order probe |
| `Get-TensorSplit.ps1` | Speed-aware, capacity-aware layer placement planner |
| `Start-Controller.ps1` | Validated llama-server and DFlash 2 launcher |
| `Benchmark-Layout.ps1` | Target-only layout, uBatch, and context-depth sweep |
| `Measure-Server.ps1` | End-to-end OpenAI endpoint measurement with speculation |
| `Compare-OpenAIEngines.ps1` | Cross-runtime concurrency and throughput comparison |
| `Get-EngineReadiness.ps1` | Native and WSL GPU/toolchain capability report |
| `Install/Start-FreeToken-WindowsROCm.ps1` | Guarded native Flow `gfx1151` lab lane |
| `Install/Start-vLLM-WindowsROCm.ps1` | Pinned native Flow vLLM build and guarded server lane |
| `Install/Start-vLLM-WindowsCUDA.ps1` | Hash-pinned native RTX 30/40 vLLM wheel and loopback server |
| `patches/vllm-windows-rocm-gfx1151.patch` | Auditable gfx1201-to-gfx1151 build retarget |
| `Install/Start-FreeToken-WSL.ps1` | Official NVIDIA FreeToken source lane under WSL2 |
| `Install/Start-vLLM-WSL.ps1` | Pinned CUDA or ROCm vLLM lane under WSL2 |
| `engine-lab.example.json` | Safe loopback endpoint benchmark template |
| `Test-Package.ps1` | SHA-256 integrity and Authenticode report |

## First commands

Run on every node from the package directory:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Collect-NodeProfile.ps1 | Set-Content .\node-profile.json
.\Get-EngineReadiness.ps1 | Set-Content .\engine-readiness.json
```

Build the Flow twice and compare backends:

```powershell
.\Build-Node.ps1 -Backend Vulkan -Role Controller
.\Build-Node.ps1 -Backend HIP -Role Controller -HipArchitectures gfx1151

.\Compare-FlowBackends.ps1 `
  -VulkanBench C:\llama-dflash2\build-vulkan\bin\llama-bench.exe `
  -HipBench C:\llama-dflash2\build-hip\bin\llama-bench.exe `
  -Model D:\models\Qwen3.8-27B-Q4_K_M.gguf
```

Then follow `FASTEST-SETUP.md`. Run the alternative lanes only after the
DFlash baselines exist. Do not assume every extra GPU or runtime makes a model
faster: a candidate should stay out of the fast profile unless the same
end-to-end workload improves.
