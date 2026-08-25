#!/usr/bin/env bash
set -euo pipefail

backend="${1:?backend is required}"
venv_arg="${2:?venv path is required}"
version="${3:?vLLM version is required}"
rocm_variant="${4:-rocm723}"
rocm_arch="${5:-gfx1151}"

expand_home() {
  case "$1" in
    '~/'*) printf '%s/%s' "$HOME" "${1#~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

venv="$(expand_home "$venv_arg")"
case "$venv" in
  ''|'/'|"$HOME") printf 'unsafe venv path: %s\n' "$venv" >&2; exit 2 ;;
esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.][A-Za-z0-9]+)?$ ]] || { echo "invalid vLLM version" >&2; exit 2; }
[[ "$rocm_variant" =~ ^rocm[0-9]+$ ]] || { echo "invalid ROCm wheel variant" >&2; exit 2; }
[[ "$rocm_arch" =~ ^gfx[0-9a-z]+$ ]] || { echo "invalid ROCm architecture" >&2; exit 2; }
command -v uv >/dev/null 2>&1 || { echo 'uv is required: https://docs.astral.sh/uv/' >&2; exit 3; }

case "$backend" in
  CUDA)
    command -v nvidia-smi >/dev/null 2>&1 || { echo 'nvidia-smi is not visible inside WSL.' >&2; exit 4; }
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
    install_args=("vllm==$version" --torch-backend=auto)
    ;;
  ROCm)
    command -v rocminfo >/dev/null 2>&1 || { echo 'rocminfo is not visible inside WSL.' >&2; exit 4; }
    rocminfo 2>/dev/null | grep -q "$rocm_arch" || { echo "rocminfo did not report $rocm_arch" >&2; exit 4; }
    install_args=("vllm==$version" --extra-index-url "https://wheels.vllm.ai/rocm/$version/$rocm_variant")
    ;;
  *) echo 'backend must be CUDA or ROCm' >&2; exit 2 ;;
esac

mkdir -p "$(dirname "$venv")"
if [[ ! -x "$venv/bin/python" ]]; then
  uv venv "$venv" --python 3.12 --seed --managed-python
fi
uv pip install --python "$venv" --upgrade "${install_args[@]}"

"$venv/bin/python" - <<'PY'
import json, torch, vllm
print(json.dumps({
    "torch": torch.__version__,
    "cuda_runtime": torch.version.cuda,
    "hip_runtime": torch.version.hip,
    "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
    "vllm": vllm.__version__,
}, indent=2))
assert torch.cuda.is_available(), "GPU backend is not available to PyTorch"
PY

{
  printf 'backend=%s\n' "$backend"
  printf 'vllm=%s\n' "$version"
  printf 'rocm_variant=%s\n' "$rocm_variant"
  printf 'rocm_arch=%s\n' "$rocm_arch"
  uv pip freeze --python "$venv"
} > "$venv/v4-install-lock.txt"
printf 'vLLM %s installed in %s\n' "$version" "$venv"
