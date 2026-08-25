# Build and architecture analysis

Analysis date: 2026-08-23

## Bottom line

For these three Windows machines, the pinned DFlash 2 `llama.cpp` fork plus
RPC remains the practical engine that can combine NVIDIA CUDA, AMD Vulkan or
HIP unified memory, and ordinary Windows networking in one inference process.
vLLM, SGLang, FreeToken, SwarmLLM, prima.cpp, `ik_llama.cpp`, and Distributed
Llama each have a useful niche, but none is a faster supported heterogeneous
three-node replacement. Revision 4 adds runnable FreeToken/vLLM experiments
so this conclusion can be tested rather than assumed.

The Flow should be the first controller tested. Qwen3.8-27B Q4 plus its DFlash
2 draft fits locally in 64 GB unified memory, removing RPC from the
speculative verification loop. Build both Vulkan and Windows HIP `gfx1151`
and measure them. For the fastest RPC challenger, keep the target local on
the Flow and put the draft on Lenovo `RPC0`. For heavy models, retain the
largest share locally on the Flow and add the Lenovo and both Aurora GPUs only
as capacity requires. Add Aurora CPU only for a capacity experiment.

## Audit of the supplied archive

| Item | Result | Consequence |
|---|---|---|
| Original archive SHA-256 | `3affc5d43cfdb022b38a5bf5b2cf03ce48a924132209c3a25d72c63297cf6150` | Identifies the exact user-supplied archive analyzed |
| Original source | `z-lab/llama.cpp-fork` commit `1deefcca395743049c3820ab8f9b15043f3e9446` | Exact pin for the supplied legacy SM89 binaries only |
| Revision 4 source | commit `7ea40ee98acb416787863aee935dbb99491acad5` | DFlash production pin retained; rebuild every node and never mix commits |
| Included build | Windows x64, MSVC Release, CUDA + RPC, SM89 | Correct only for the Lenovo RTX 4080 Laptop controller |
| Integrity | Every original entry matched `SHA256SUMS.txt` | No archive corruption was found |
| Signatures | Included EXE/DLL files are unsigned | Verify hashes before copying; Windows may show SmartScreen warnings |
| Smoke-test metadata | Server version and local CUDA RPC discovery reported as passed by the original builder | Useful, but not an end-to-end three-node validation |
| Aurora instructions | Incorrectly requested CUDA architecture 89 | RTX 3060 and 3060 Ti are SM86; an SM89-only worker can fail with “no kernel image” |
| Aurora placement | Treated the pair as one generic 20 GB GPU | It is two devices, normally 12 GB + 8 GB, each needing its own reserve |
| Flow placement | Suggested a fixed 48 GB without measurement | Treat 48 GB as a starting UMA setting, then use the memory actually reported by `--list-devices` |
| Largest-model table | Mixed decimal GB/GiB and several stale sizes | Replaced with current file sizes and explicit risk levels |
| DFlash draft width | v2 changed it to the official value 7 | Strix Halo results show 4 can be faster, especially at 32K; v4 retains the 4 default and benchmarks 4/5/7 |
| Flow backend | Vulkan only | AMD HIP SDK 7.2 officially supports Ryzen AI Max+ 395/gfx1151 on Windows; v4 builds and compares both |
| RPC prompt cache | Left the 8 GiB RAM cache at its default | v2 disables the serializable RAM cache by default because of a current RPC failure; in-slot prompt reuse remains enabled |
| Benchmarking | No reproducible layout benchmark | v2 adds target and end-to-end server benchmarks |
| Alternative engines | General comparison only | v4 adds guarded native/WSL installers, readiness probes, and a standard OpenAI endpoint benchmark |

The prebuilt SM89 binaries remain unchanged and are now a legacy comparison
only. Because revision 4 uses the optimized source commit, rebuild the Lenovo
as well as Aurora and Flow before forming a v4 cluster.

## Correct hardware map

| Node | Backend | Memory role | Build | Recommended RPC exposure |
|---|---|---|---|---|
| Lenovo Legion 7i, RTX 4080 Laptop 12 GB, 32 GB DDR5 | CUDA | Fast remote draft or target-layer worker; alternate controller | Rebuild with `-CudaArchitectures auto` (SM89) | `CUDA0` when Flow is controller |
| Alienware Aurora R10, RTX 3060 12 GB + RTX 3060 Ti 8 GB, 32 GB DDR4 | CUDA | Two target devices; optional remote CPU capacity | Rebuild SM86 | `CUDA0,CUDA1`; add `CPU` only in capacity mode |
| ASUS Flow Z13 2025 Strix Halo, Radeon 8060S, 64 GB unified RAM | Vulkan or HIP | Preferred controller, local fast profile, largest target-memory pool | Build Vulkan and HIP `gfx1151`; benchmark both | Local `Vulkan0` or `ROCm0`; never double-count CPU |

The Flow’s CPU and Vulkan allocations share physical RAM. Exposing both and
adding their reported capacities would double-count memory. The Aurora’s
system RAM and discrete VRAM are physically separate, so its CPU can be an
additional, slow capacity device.

## Performance design

RPC layer splitting sends activations at layer boundaries and has the least
network traffic of llama.cpp’s multi-device modes. Keep `--split-mode layer`.
Do not select RPC row/tensor splitting on these links: it communicates during
every layer, and current tensor mode does not support many hybrid/MoE
architectures.

For one interactive request, fewer devices can beat a wider cluster. A model
that fits on the Flow may be faster there alone than when fragmented across
all five accelerators. The correct DFlash 2 comparison is:

1. Flow controller with target and draft both local (Vulkan and HIP);
2. Flow controller with local target and Lenovo `RPC0` draft;
3. Lenovo controller with local CUDA draft and Flow `RPC0` target;
4. a split target only after the first three, plus a non-speculative baseline
   for every layout.

Run `Compare-FlowBackends.ps1` first, then `Benchmark-Layout.ps1` for
target-only layouts and `Measure-Server.ps1` against otherwise identical
servers. DFlash 2 can lose when draft or RPC overhead exceeds accepted-token
savings. The official model card uses seven draft tokens; Strix Halo data in
the implementation discussion favored four at long context, so v4 uses four
as its hardware-specific default and requires a 4/5/7 sweep.

Network requirements matter as much as aggregate memory:

- use direct, static, peer-firewalled links;
- verify that Windows exposes a real IP-capable adapter—USB4/Thunderbolt alone
  does not guarantee PC-to-PC IP networking;
- 10 GbE or faster is preferred; 2.5 GbE can work for layer mode but may erase
  gains from adding a device;
- avoid Wi-Fi, VPN, or overlay routes;
- benchmark sustained bandwidth and latency with `iperf3` before tuning model
  splits.

## Realistic model tiers

Sizes below are GGUF file sizes in GiB (2^30 bytes). Runtime buffers, KV
cache, graph allocations, the draft, Windows, and worker caches are extra.

| Tier | Model and quant | File size | Assessment on this cluster |
|---|---|---:|---|
| Fastest DFlash 2 | Qwen3.8-27B Q4_K_M target + DFlash 2 Q4_K_M draft | 17.67 + 1.06 GiB | Begin with both local on Flow; compare Q8_0 and BF16 drafts plus remote Lenovo draft |
| All-local 100B-class speed test | Qwen3.5-122B-A10B UD-IQ2_XXS | 34.12 GiB | Fits Flow locally and avoids RPC, but low-bit quality and current Vulkan behavior require qualification |
| Stable large candidate | gpt-oss-120b MXFP4 | 59.03 GiB | A strong first large-model RPC qualification target; official GGUF also has an Eagle3 draft |
| Heavy practical | MiniMax-M2.5 UD-IQ2_XXS | 69.03 GiB | Fits accelerator capacity with reserves, but low-bit quality and architecture/backend behavior must be tested |
| Higher-quality heavy | Qwen3.5-122B-A10B Q4_K_S / Q4_K_M | 66.78 / 71.28 GiB | Attractive quality/capacity point, but current Windows Vulkan Qwen3.5-MoE issues make it experimental |
| Capacity experiment | Qwen3.5-397B-A17B UD-IQ1_M / UD-IQ2_XXS | 99.48 / 106.98 GiB | Can only be attempted with CPU placement, small context, and tight reserves; very slow and currently backend-risky |
| Do not deploy yet | DeepSeek-V4-Flash low-bit GGUF | 76.87–84.62 GiB for IQ1_S–IQ2_XXS | Open RPC/Vulkan correctness reports can produce wrong output or graph failures |

The 397B IQ2 model is the heaviest plausible load experiment, not the fastest
or most reliable model. Never use pagefile size as “available model RAM” for a
performance plan. A system-managed NVMe pagefile can prevent an abrupt commit
failure, but active paging makes token generation unusably slow.

Start heavy models at 8K context, one slot, q8_0 K/V cache, and flash attention
on. Move to 16K and then 32K only after a repeatable correctness and memory
test. The model’s advertised maximum context is not a sensible allocation
target for this hardware.

## Engine decision

| Engine | Best use here | Why it is not the three-node Windows engine |
|---|---|---|
| DFlash 2 + llama.cpp RPC | Qwen3.8-27B speculation and mixed-backend Windows aggregation | Selected solution; Flow-local is the speed baseline and RPC is the capacity path |
| llama.cpp without speculation | Baseline and larger GGUF models | Often faster than a mismatched draft; supports the same RPC topology |
| SGLang | Native Linux homogeneous accelerator serving and batching | No supported mixed CUDA + AMD Windows distributed memory pool; its Windows request remains inactive |
| vLLM Windows ROCm fork | Flow-local HF/Safetensors serving and batched throughput | v4's most promising new speed lane, but the fork is single-GPU, based on vLLM 0.26.0, and only end-to-end tested by its author on gfx1201 |
| vLLM Windows CUDA fork | Native Lenovo/Aurora serving; optional local PP/TP | Released wheel explicitly targets Ampere/Ada, but needs CUDA 13 and community Windows NCCL for multi-GPU; no mixed-vendor or cross-PC pool |
| vLLM official | WSL2 single-node CUDA/ROCm serving and batched throughput | No official native Windows; raw TCP is explicitly inefficient for cross-node tensor parallelism |
| FreeToken official | WSL2 NVIDIA MoE experiment, especially CPU/PCIe expert offload | Source install requires Linux x86_64, NVIDIA, r580+, CUDA 13; its TP launcher starts local ranks only |
| FreeToken Windows ROCm fork | Flow-local `gfx1151` research | v4 retargets the fork's architecture parameter, but its evidence is gfx1201 and Windows offload/GGUF are incomplete |
| SwarmLLM | Native-Windows alpha pipeline comparison | Distributed GPU on Windows is NVIDIA-only; the Flow contributes CPU rather than its Vulkan GPU |
| prima.cpp | Heterogeneous piped-ring research | Windows and AMD/Vulkan are still on its roadmap |
| `ik_llama.cpp` | CUDA/CPU low-bit and MoE experiments | Its README calls only CPU and CUDA fully functional/performant, so it strands the Flow's main capacity |
| Distributed Llama | Cross-platform CPU/Vulkan distributed research | Requires a power-of-two node count and currently limits model quants to Q4_0 or F32 |

The FreeToken desktop project advertises Windows separately, but that does not
make its open-source CLI a heterogeneous multi-node backend. The official
launcher creates all `tp-size` worker processes locally and uses a loopback
distributed address. Keep it as an independent endpoint benchmark; do not
mix its model memory accounting with the llama.cpp cluster.

The native vLLM fork is a materially stronger Flow experiment than a generic
Windows compatibility shim. At the pinned commit it builds HIP extensions on
Windows and already contains explicit `gfx1151` architecture branches and
Strix Halo W4A16 tuning. The v4 patch changes the installer/build target and
wheel index, not those kernels. This lowers the porting risk, but it does not
turn the author's gfx1201 benchmark into a Flow result. Qualify it against the
same model, context, prompt set, and concurrency as DFlash before promotion.

## Current upstream risks

- llama.cpp calls RPC proof-of-concept, fragile, and insecure.
- DFlash 2’s llama.cpp integration is still an open development PR.
- Current DFlash reports include greedy divergence, multimodal cache holes,
  Vulkan speculative/multi-slot slowdown, and a server hang after a client
  abort. Qualify text-only with one slot.
- Qwen3.5 MoE and DeepSeek-family Vulkan graphs on Windows have active crash or
  correctness reports. Validate deterministic prompts against a local CUDA or
  CPU baseline before trusting output.
- RPC workers and controller must be built from exactly the same commit.
- Loading a worker close to total RAM can terminate it; keep per-device and OS
  reserves even when the arithmetic says a model barely fits.

## Primary references

- [llama.cpp RPC documentation](https://github.com/ggml-org/llama.cpp/tree/master/tools/rpc)
- [llama.cpp multi-GPU documentation](https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md)
- [Pinned optimized DFlash 2 commit](https://github.com/z-lab/llama.cpp-fork/commit/7ea40ee98acb416787863aee935dbb99491acad5)
- [DFlash 2 llama.cpp pull request](https://github.com/ggml-org/llama.cpp/pull/27342)
- [Official DFlash 2 GGUF model card and seven-token recipe](https://huggingface.co/z-lab/Qwen3.8-27B-DFlash2-GGUF)
- [Qwen3.8-27B target GGUF](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF)
- [gpt-oss-120b GGUF](https://huggingface.co/ggml-org/gpt-oss-120b-GGUF)
- [MiniMax-M2.5 GGUF](https://huggingface.co/unsloth/MiniMax-M2.5-GGUF)
- [Qwen3.5-122B-A10B GGUF](https://huggingface.co/unsloth/Qwen3.5-122B-A10B-GGUF)
- [Qwen3.5-397B-A17B GGUF](https://huggingface.co/unsloth/Qwen3.5-397B-A17B-GGUF)
- [FreeToken source and requirements](https://github.com/FlashML-org/FreeToken)
- [FreeToken Windows ROCm community fork](https://github.com/Maxritz/FreeToken-rocm-test)
- [Native-Windows ROCm vLLM community fork](https://github.com/charlie12345/vLLM_for_AMD)
- [Native-Windows CUDA vLLM v0.26.0 release](https://github.com/SystemPanic/vllm-windows/releases/tag/v0.26.0)
- [AMD `gfx1151` Windows ROCm wheel index](https://repo.amd.com/rocm/whl/gfx1151/)
- [vLLM distributed serving](https://docs.vllm.ai/en/latest/serving/distributed_serving/)
- [vLLM Windows/WSL and gfx1151 requirements](https://docs.vllm.ai/en/latest/getting_started/installation/gpu/)
- [SGLang installation](https://docs.sglang.ai/get_started/install.html)
- [AMD HIP SDK 7.2 Windows requirements](https://rocm.docs.amd.com/projects/install-on-windows/en/docs-7.2/reference/system-requirements.html)
- [AMD TheRock supported GPU table](https://github.com/ROCm/TheRock/blob/main/SUPPORTED_GPUS.md)
- [SwarmLLM Windows platform support](https://github.com/enapt/SwarmLLM#platform-support)
- [prima.cpp platform limitations](https://github.com/OpenCPIL/prima.cpp)
- [`ik_llama.cpp` backend support statement](https://github.com/ikawrakow/ik_llama.cpp#tldr)
- [Distributed Llama limitations](https://github.com/b4rtaz/distributed-llama#known-limitations)
- [RPC RAM-cache failure report and workaround](https://github.com/ggml-org/llama.cpp/issues/26529)
- [Windows Vulkan Qwen3.5-MoE crash report](https://github.com/ggml-org/llama.cpp/issues/26945)
- [DeepSeek-V4 RPC/Vulkan wrong-output report](https://github.com/ggml-org/llama.cpp/issues/26685)
- [RPC graph pointer failure report](https://github.com/ggml-org/llama.cpp/issues/26820)
