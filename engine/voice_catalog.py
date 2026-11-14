"""Shared, bounded voice metadata. This module performs no inference or downloads."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = json.loads((ROOT / "Sources/ClearSpeakCore/Resources/voices.json").read_text())
VOICES = {item["name"]: item for item in CATALOG}


def voice_for_model(name, path):
    voice = VOICES[name]
    expected = voice["directory"] or "qwen3-tts-1.7b-bf16"
    if path.name != expected:
        raise ValueError("voice/model mismatch")
    if not all((path / file).is_file() for file in voice["files"]):
        raise ValueError("voice assets missing")
    return voice
