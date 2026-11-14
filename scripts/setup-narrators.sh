#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -x ClearSpeak >/dev/null || pgrep -f "$(pwd)/engine/worker.py" >/dev/null; then
  echo 'Quit ClearSpeak and finish any speech checks before updating voice assets.'
  exit 1
fi
test -x .venv/bin/python || { echo 'Run scripts/setup-local.sh first.'; exit 1; }
command -v uv >/dev/null || { echo 'uv is required; see README.'; exit 1; }
case "${1:-all}" in all|kokoro|voxcpm|voxtral) ;; *) echo 'Usage: scripts/setup-narrators.sh [all|kokoro|voxcpm|voxtral]'; exit 2 ;; esac
uv pip install --python .venv/bin/python -r engine/narrator-requirements.lock
uv pip install --python .venv/bin/python --no-deps \
  'https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl#sha256=1932429db727d4bff3deed6b34cfc05df17794f4a52eeb26cf8928f7c1a0fb85'
if [[ "${1:-all}" == all || "${1:-all}" == voxtral ]]; then
  uv venv --python 3.12 --allow-existing .local-runtime/voxtral
  uv pip install --python .local-runtime/voxtral/bin/python -r engine/voxtral-requirements.lock
fi
export HF_HOME="$(pwd)/.local-runtime/huggingface"
export HF_HUB_DISABLE_TELEMETRY=1
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
export HF_XET_CACHE="$(pwd)/.local-runtime/xet"
.venv/bin/python scripts/setup-narrators.py "${1:-all}"
if [[ "${1:-all}" == all || "${1:-all}" == voxcpm ]]; then
  /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
    .venv/bin/python scripts/prepare-narrators.py
fi
echo 'Narrator assets are ready. Reopen ClearSpeak Settings to see installed voices.'
