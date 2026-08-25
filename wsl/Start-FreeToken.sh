#!/usr/bin/env bash
set -euo pipefail

venv_arg="${1:?venv path is required}"
model="${2:?model is required}"
port="${3:-1919}"
moe_backend="${4:-auto}"
memory_ratio="${5:-0.90}"
max_seq_len="${6:-32768}"
calibrate="${7:-0}"
shift 7

expand_home() {
  case "$1" in
    '~/'*) printf '%s/%s' "$HOME" "${1#~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
case "$model" in '~/'*) model="$HOME/${model#~/}" ;; esac
venv="$(expand_home "$venv_arg")"
[[ -x "$venv/bin/ft" ]] || { echo "FreeToken executable not found in $venv" >&2; exit 3; }
[[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )) || { echo 'invalid port' >&2; exit 2; }
case "$moe_backend" in auto|fused|offload|cpu|hybrid) ;; *) echo 'invalid MoE backend' >&2; exit 2 ;; esac

if [[ "$calibrate" == 1 ]]; then
  "$venv/bin/ft" bench bw
fi
args=(serve --model "$model"
  --server-host 127.0.0.1
  --server-port "$port"
  --moe-backend "$moe_backend"
  --memory-ratio "$memory_ratio"
  --max-seq-len-override "$max_seq_len")
exec "$venv/bin/ft" "${args[@]}" "$@"
