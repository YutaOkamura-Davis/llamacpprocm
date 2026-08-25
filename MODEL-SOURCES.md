# Model sources and download order

Checked against the Hugging Face repositories on 2026-08-23. Sizes are total
GGUF bytes converted to GiB. Download models to whichever machine is the
controller (the Flow in the recommended v4 profiles); RPC workers receive and
cache the tensors they own during model load.

These GGUF downloads are for llama.cpp/DFlash. FreeToken and most optimized
vLLM paths expect Hugging Face/FTW, AWQ, GPTQ, FP8, or other engine-specific
checkpoints. Do not use a different precision or format when claiming a
cross-engine speed win; `RUNTIME-LAB.md` defines the comparison rules.

For the native vLLM/FreeToken lab, use this qualification ladder instead of
feeding the engines GGUF files:

| Model | Format | v4 use |
|---|---|---|
| [Qwen/Qwen3-4B-AWQ](https://huggingface.co/Qwen/Qwen3-4B-AWQ) | AWQ Safetensors | Small native-vLLM gfx1151 smoke and kernel test |
| [openai/gpt-oss-20b](https://huggingface.co/openai/gpt-oss-20b) | Official MXFP4 Safetensors | First larger Flow native-vLLM and FreeToken MoE test; validated by the ROCm vLLM fork on gfx1201 |
| [Qwen/Qwen3-30B-A3B-Instruct-2507-FP8](https://huggingface.co/Qwen/Qwen3-30B-A3B-Instruct-2507-FP8) | FP8 Safetensors | Heavy Flow throughput challenger only after both smaller gates; not prequalified on the Windows fork |

Do not start native vLLM with the 80B FP8 or gpt-oss-120b checkpoints. Their
weights plus KV cache, compile workspaces, driver allocations, and Windows
reserve exceed or press too closely against the Flow's safe 64 GB budget.
Use DFlash low-bit GGUF/RPC when capacity is the objective.

For the native CUDA wheel, begin with a 7B/8B AWQ, GPTQ, or FP8 checkpoint on
the Lenovo. gpt-oss-20b does not fit safely in 12 GB as an ordinary single-GPU
load; it needs measured CPU offload or the experimental Aurora PP=2 lane, where
the 8 GB 3060 Ti stage remains the constraint.

Install the current Hugging Face CLI in an isolated environment, then use `hf
download`. Examples below write directly to `D:\models`.

## 1. DFlash 2 qualification pair

Target: [ggml-org/Qwen3.8-27B-GGUF](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF),
Q4_K_M, 17.67 GiB.

Draft: [z-lab/Qwen3.8-27B-DFlash2-GGUF](https://huggingface.co/z-lab/Qwen3.8-27B-DFlash2-GGUF).

| Draft quant | Repository size | Use |
|---|---:|---|
| Q4_K_M | 1.14 GB / about 1.06 GiB | Download first; highest acceptance in the model-card table |
| Q8_0 | 2.06 GB / about 1.92 GiB | Benchmark challenger |
| BF16 | 3.86 GB / about 3.59 GiB | Benchmark challenger; fastest in the PR's Apple M5 test |

```powershell
hf download ggml-org/Qwen3.8-27B-GGUF Qwen3.8-27B-Q4_K_M.gguf `
  --local-dir D:\models
hf download z-lab/Qwen3.8-27B-DFlash2-GGUF Qwen3.8-27B-DFlash2-Q4_K_M.gguf `
  --local-dir D:\models
```

After the Q4 profile is stable, optionally download both draft challengers:

```powershell
hf download z-lab/Qwen3.8-27B-DFlash2-GGUF Qwen3.8-27B-DFlash2-Q8_0.gguf `
  --local-dir D:\models
hf download z-lab/Qwen3.8-27B-DFlash2-GGUF Qwen3.8-27B-DFlash2-BF16.gguf `
  --local-dir D:\models
```

Start here. It is the only official DFlash 2 target/draft pairing in this
package. Test draft widths 4, 5, and 7; seven is the official quick-start
value, while four has been faster in published Strix Halo results.

## 2. Large RPC qualification model

[ggml-org/gpt-oss-120b-GGUF](https://huggingface.co/ggml-org/gpt-oss-120b-GGUF),
MXFP4, 59.03 GiB.

```powershell
hf download ggml-org/gpt-oss-120b-GGUF gpt-oss-120b-MXFP4.gguf `
  --local-dir D:\models
```

This is the recommended first full-cluster large-model test. The same
repository currently provides a small Eagle3 draft, but qualify ordinary
decode before adding another speculative method.

## 3. Heavy practical candidates

[MiniMax-M2.5 GGUF](https://huggingface.co/unsloth/MiniMax-M2.5-GGUF),
UD-IQ2_XXS, 69.03 GiB across three shards.

```powershell
hf download unsloth/MiniMax-M2.5-GGUF `
  --include 'UD-IQ2_XXS/*.gguf' --local-dir D:\models\MiniMax-M2.5
```

[Qwen3.5-122B-A10B GGUF](https://huggingface.co/unsloth/Qwen3.5-122B-A10B-GGUF):

| Quant | Total size | Comment |
|---|---:|---|
| UD-IQ2_XXS | 34.12 GiB | Fast capacity fit, but much lower precision |
| Q4_K_S | 66.78 GiB | Smaller 4-bit choice |
| Q4_K_M | 71.28 GiB | Preferred quality if the live budget and backend are stable |

```powershell
hf download unsloth/Qwen3.5-122B-A10B-GGUF `
  --include 'Q4_K_M/*.gguf' --local-dir D:\models\Qwen3.5-122B-A10B
```

Qwen3.5 MoE currently has open Windows Vulkan failures. A successful download
or load does not establish correctness; compare deterministic outputs to a
CPU/CUDA baseline.

## 4. Maximum-capacity experiment

[Qwen3.5-397B-A17B GGUF](https://huggingface.co/unsloth/Qwen3.5-397B-A17B-GGUF):

| Quant | Total size | Assessment |
|---|---:|---|
| UD-IQ1_M | 99.48 GiB | More plausible load attempt, severe quantization |
| UD-IQ2_XXS | 106.98 GiB | Heaviest plausible attempt, tighter than the safe normal budget |

```powershell
hf download unsloth/Qwen3.5-397B-A17B-GGUF `
  --include 'UD-IQ1_M/*.gguf' --local-dir D:\models\Qwen3.5-397B-A17B
```

This tier needs accelerator placement, Aurora remote CPU, Lenovo local CPU
layers, an 8K starting context, and an NVMe pagefile as emergency commit
headroom. It will not be fast. Do not download it before the 59–71 GiB tier is
stable; model storage plus RPC caches can consume several times the GGUF size.

## Avoid for now

DeepSeek-V4-Flash low-bit GGUFs are physically plausible, but current open
RPC/Vulkan wrong-output and graph failures make them unsuitable for trusted
serving on this exact topology. Revisit after the issues linked in
`ANALYSIS.md` are closed and the fix is present in a single pinned commit on
every node.
