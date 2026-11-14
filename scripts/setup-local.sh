#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v uv >/dev/null || { echo 'Install uv from https://docs.astral.sh/uv/ first.'; exit 1; }
uv venv --python 3.12 --allow-existing .venv
uv pip install --python .venv/bin/python -r engine/requirements.lock
export HF_HOME="$(pwd)/.local-runtime/huggingface"
export HF_HUB_DISABLE_TELEMETRY=1
.venv/bin/hf download mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16 \
  --revision 52f4770fd9726457eae3d3b6aa92047a25a10776 \
  --local-dir models/qwen3-tts-1.7b-bf16
.venv/bin/hf cache verify mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16 \
  --revision 52f4770fd9726457eae3d3b6aa92047a25a10776 \
  --local-dir models/qwen3-tts-1.7b-bf16 --fail-on-missing-files
printf 'Local speech is installed. Run ./scripts/build.sh, then open dist/ClearSpeak.app\n'
