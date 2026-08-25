#!/usr/bin/env bash
set -euo pipefail

venv_arg="${1:?venv path is required}"
model="${2:?model is required}"
port="${3:-8000}"
gpu_memory="${4:-0.90}"
max_model_len="${5:-32768}"
cpu_offload="${6:-0}"
tp="${7:-1}"
pp="${8:-1}"
dtype="${9:-auto}"
quantization="${10:-}"
shift 10

expand_home() {
  case "$1" in
    '~/'*) printf '%s/%s' "$HOME" "${1#~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
venv="$(expand_home "$venv_arg")"
[[ -x "$venv/bin/vllm" ]] || { echo "vLLM executable not found in $venv" >&2; exit 3; }
[[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )) || { echo 'invalid port' >&2; exit 2; }
[[ "$tp" =~ ^[0-9]+$ ]] && (( tp > 0 )) || { echo 'invalid tensor parallel size' >&2; exit 2; }
[[ "$pp" =~ ^[0-9]+$ ]] && (( pp > 0 )) || { echo 'invalid pipeline parallel size' >&2; exit 2; }

args=(serve "$model"
  --host 127.0.0.1
  --port "$port"
  --gpu-memory-utilization "$gpu_memory"
  --max-model-len "$max_model_len"
  --tensor-parallel-size "$tp"
  --pipeline-parallel-size "$pp"
  --dtype "$dtype")
if [[ "$cpu_offload" != 0 && "$cpu_offload" != 0.0 ]]; then
  args+=(--cpu-offload-gb "$cpu_offload")
fi
if [[ -n "$quantization" ]]; then
  args+=(--quantization "$quantization")
fi
exec "$venv/bin/vllm" "${args[@]}" "$@"
