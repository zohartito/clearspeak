"""Create fixed original synthetic references; never accepts user text or audio."""
import hashlib
import json
import os
from pathlib import Path
import wave

os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
ROOT = Path(__file__).resolve().parents[1]
TEXT = "The morning light fills the quiet room. Take your time, settle in, and let us explore the next idea together."
STYLES = {
    "warm-male": "An adult man speaking English with a warm, relaxed, conversational voice. Clear articulation, gentle expression, natural pauses, comfortable steady pacing.",
    "warm-female": "An adult woman speaking English with a warm, relaxed, conversational voice. Clear articulation, gentle expression, natural pauses, comfortable steady pacing.",
}


def main():
    import mlx.core as mx
    import numpy as np
    from scipy.signal import resample_poly
    from mlx_audio.tts.utils import load_model
    target = ROOT / "models/narrator-reference"
    target.mkdir(parents=True, exist_ok=True)
    model = None
    for index, (stem, style) in enumerate(STYLES.items()):
        audio_path, metadata = target / (stem + ".wav"), target / (stem + ".json")
        if audio_path.is_file() and metadata.is_file():
            old = json.loads(metadata.read_text())
            if old.get("sha256") == hashlib.sha256(audio_path.read_bytes()).hexdigest() and old.get("style") == style and old.get("text") == TEXT and old.get("seed") == 42 + index:
                print(f"Kept verified synthetic reference: {stem}", flush=True)
                continue
        metadata.unlink(missing_ok=True)
        if model is None:
            model = load_model(ROOT / "models/voxcpm2-bf16", lazy=False)
        mx.random.seed(42 + index)
        chunks = []
        for result in model.generate(text=TEXT, instruct=style, inference_timesteps=10,
                                     cfg_value=2.0, max_tokens=1200):
            if result.sample_rate != 48000:
                raise ValueError("Unexpected reference rate")
            chunks.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
        audio = np.concatenate(chunks)
        if not 48000 <= len(audio) <= 48000 * 30 or not np.isfinite(audio).all() or abs(audio).max() < .01:
            raise ValueError("Invalid synthetic reference")
        # One canonical 24 kHz reference is shared by the two local engines.
        audio = resample_poly(audio, 1, 2)
        temporary = audio_path.with_suffix(".tmp")
        with wave.open(str(temporary), "wb") as f:
            f.setnchannels(1); f.setsampwidth(2); f.setframerate(24000)
            f.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
        temporary.replace(audio_path)
        metadata.write_text(json.dumps({"text": TEXT, "style": style, "seed": 42 + index,
            "source": "Original synthetic VoxCPM2 voice; no real speaker reference",
            "revision": "a7fb80d9056983135a54ca3f71fcc5a637ccddf5",
            "sha256": hashlib.sha256(audio_path.read_bytes()).hexdigest()}, indent=2) + "\n")
        print(f"Prepared synthetic reference: {stem} ({len(audio)/24000:.1f}s)", flush=True)


if __name__ == "__main__":
    main()
