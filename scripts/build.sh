#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product ClearSpeak
BIN_DIR="$(swift build -c release --show-bin-path)"
if pgrep -x ClearSpeak >/dev/null; then
  echo 'Quit ClearSpeak before replacing the app bundle, then run this script again.'
  exit 1
fi
APP="$(pwd)/dist/ClearSpeak.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClearSpeak" "$APP/Contents/MacOS/ClearSpeak"
cp Resources/Info.plist "$APP/Contents/Info.plist"
RESOURCE_BUNDLE="$BIN_DIR/ClearSpeak_ClearSpeakCore.bundle"
test -d "$RESOURCE_BUNDLE"
rm -rf "$APP/Contents/Resources/ClearSpeak_ClearSpeakCore.bundle"
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/ClearSpeak_ClearSpeakCore.bundle"
python3 - "$APP" "$(pwd)" <<'PYCONFIG'
import json, pathlib, sys
app, root = map(pathlib.Path, sys.argv[1:])
(app / 'Contents/Resources/local-runtime.json').write_text(json.dumps({
    'python': str(root / '.venv/bin/python'),
    'worker': str(root / 'engine/worker.py'),
    'model': str(root / 'models/qwen3-tts-1.7b-bf16'),
}))
PYCONFIG
# Stable identifier for a locally built app; distribution requires Developer ID signing.
codesign --force --sign - --identifier com.zohartito.clearspeak "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP"
