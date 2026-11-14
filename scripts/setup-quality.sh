#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test -x .venv/bin/hf || { echo 'Run scripts/setup-local.sh first.'; exit 1; }
case "${1:-breeze}" in
  breeze)
    REPO=mlx-community/Breeze-TTS-2-mlx
    REVISION=3c8829fb7fd335818f085cd2ef49b4100c0e46c8
    DIRECTORY=models/breeze-tts-2-bf16
    ;;
  fish)
    REPO=mlx-community/fish-audio-s2-pro-bf16
    REVISION=eccd57bf5c1ebc13cb2f993df867f4e49931a36a
    DIRECTORY=models/fish-s2-pro-bf16
    ;;
  *) echo 'Usage: scripts/setup-quality.sh [breeze|fish]'; exit 2 ;;
esac
# Public, pinned weights. Inference remains in the network-denied worker.
export HF_HOME="$(pwd)/.local-runtime/huggingface"
export HF_HUB_DISABLE_TELEMETRY=1
export HF_XET_CACHE="$(pwd)/.local-runtime/xet"
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-0}"
export HF_XET_HIGH_PERFORMANCE=1
export HF_HUB_DOWNLOAD_TIMEOUT=120
.venv/bin/hf download "$REPO" --revision "$REVISION" --local-dir "$DIRECTORY" --max-workers 3
.venv/bin/hf cache verify "$REPO" --revision "$REVISION" --local-dir "$DIRECTORY" --fail-on-missing-files
if [[ "${1:-breeze}" == fish ]]; then
  /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' .venv/bin/python scripts/prepare-fish.py
  # Reference files are fixed synthetic samples, never a user's reading history.
  if [[ ! -f models/fish-reference/ordinary-qwen.wav || ! -f models/fish-reference/ordinary-qwen.json ]]; then
    .venv/bin/python scripts/audition-local.py qwen --items ordinary --output models/fish-reference
  fi
fi
echo "Verified local weights in $DIRECTORY. The repository includes the model's license and notices."
