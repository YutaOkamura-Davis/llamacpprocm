#!/usr/bin/env bash
set -euo pipefail

source_arg="${1:?source path is required}"
venv_arg="${2:?venv path is required}"
commit="${3:?commit is required}"

expand_home() {
  case "$1" in
    '~/'*) printf '%s/%s' "$HOME" "${1#~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
source_dir="$(expand_home "$source_arg")"
venv="$(expand_home "$venv_arg")"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo 'commit must be a full SHA-1' >&2; exit 2; }
for path in "$source_dir" "$venv"; do
  case "$path" in ''|'/'|"$HOME") echo "unsafe install path: $path" >&2; exit 2 ;; esac
done
command -v git >/dev/null 2>&1 || { echo 'git is required' >&2; exit 3; }
command -v uv >/dev/null 2>&1 || { echo 'uv is required: https://docs.astral.sh/uv/' >&2; exit 3; }
command -v nvidia-smi >/dev/null 2>&1 || { echo 'nvidia-smi is not visible inside WSL' >&2; exit 4; }
command -v nvcc >/dev/null 2>&1 || { echo 'CUDA 13 nvcc is required by official FreeToken source installs' >&2; exit 4; }

driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
driver_major="${driver%%.*}"
[[ "$driver_major" =~ ^[0-9]+$ ]] && (( driver_major >= 580 )) || {
  echo "FreeToken requires NVIDIA driver r580+; WSL reports $driver" >&2; exit 4;
}
nvcc_release="$(nvcc --version | sed -n 's/.*release \([0-9.]*\).*/\1/p' | head -1)"
[[ "${nvcc_release%%.*}" == 13 ]] || { echo "FreeToken requires CUDA 13 nvcc; found $nvcc_release" >&2; exit 4; }

if [[ -d "$source_dir/.git" ]]; then
  [[ -z "$(git -C "$source_dir" status --porcelain)" ]] || { echo 'FreeToken source tree is dirty; refusing checkout' >&2; exit 5; }
  remote="$(git -C "$source_dir" remote get-url origin)"
  [[ "$remote" == *FlashML-org/FreeToken* ]] || { echo "unexpected origin: $remote" >&2; exit 5; }
else
  [[ ! -e "$source_dir" ]] || { echo "source path exists but is not a git repo: $source_dir" >&2; exit 5; }
  mkdir -p "$(dirname "$source_dir")"
  git clone --filter=blob:none https://github.com/FlashML-org/FreeToken.git "$source_dir"
fi
git -C "$source_dir" fetch --depth 1 origin "$commit"
git -C "$source_dir" checkout --detach "$commit"
actual="$(git -C "$source_dir" rev-parse HEAD)"
[[ "$actual" == "$commit" ]] || { echo "source pin mismatch: $actual" >&2; exit 5; }

mkdir -p "$(dirname "$venv")"
if [[ ! -x "$venv/bin/python" ]]; then
  uv venv "$venv" --python 3.12 --seed --managed-python
fi
uv pip install --python "$venv" --upgrade --editable "$source_dir[accel]"
"$venv/bin/ft" --help >/dev/null
{
  printf 'commit=%s\n' "$commit"
  printf 'driver=%s\n' "$driver"
  printf 'nvcc=%s\n' "$nvcc_release"
  uv pip freeze --python "$venv"
} > "$venv/v4-install-lock.txt"
printf 'FreeToken %s installed in %s\n' "$commit" "$venv"
