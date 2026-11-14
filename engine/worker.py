"""Private stdio worker. Offline inference; stdout contains framed audio only."""
import os
import sys

os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1",
                  HF_HUB_DISABLE_TELEMETRY="1", DO_NOT_TRACK="1",
                  TOKENIZERS_PARALLELISM="false")
wire = sys.stdout
sys.stdout = sys.stderr  # Third-party diagnostics must never corrupt the protocol.

import base64
import json
import time
import wave
from pathlib import Path

from voice_catalog import VOICES, voice_for_model
STYLE = "Speak in a warm, natural, conversational way with relaxed pacing and clear pronunciation."


def emit(message):
    wire.write(json.dumps(message, separators=(",", ":")) + "\n")
    wire.flush()


def voxcpm_reference(path, spec):
    root = path.parent / "narrator-reference"
    stem = spec["reference"]
    prompt_audio = (root / (stem + ".wav")).resolve(strict=True)
    metadata = json.loads((root / (stem + ".json")).read_text())
    prompt_text = metadata.get("text")
    if not isinstance(prompt_text, str) or not prompt_text.strip() or len(prompt_text.encode()) > 1400:
        raise ValueError("invalid reference text")
    with wave.open(str(prompt_audio), "rb") as file:
        if file.getnchannels() != 1 or file.getsampwidth() != 2 or file.getframerate() != 24000 or not 12000 <= file.getnframes() <= 720000:
            raise ValueError("invalid reference audio")
    return str(prompt_audio), prompt_text + " "


def main():
    import mlx.core as mx
    import numpy as np
    from mlx_audio.tts.utils import load_model

    path = Path(sys.argv[1]).resolve(strict=True)
    model = load_model(path, lazy=False)
    references = {}
    emit({"event": "ready"})
    for line in sys.stdin:
        request_id = None
        try:
            if len(line.encode()) > 10000:
                raise ValueError("oversized request")
            request = json.loads(line)
            request_id = request["id"]
            text = request["text"]
            voice = request["voice"]
            if not isinstance(request_id, str) or len(request_id) > 64:
                raise ValueError("invalid id")
            if not isinstance(text, str) or not text.strip() or len(text.encode()) > 1400:
                raise ValueError("invalid text")
            if voice not in VOICES:
                raise ValueError("invalid voice")
            spec = voice_for_model(voice, path)
            engine = spec["engine"]
            started = time.monotonic()
            if engine == "fish":
                from scipy.signal import resample_poly
                if voice not in references:
                    root = path.parent / spec["referenceDirectory"]
                    stem = spec["reference"]
                    ref_text = json.loads((root / (stem + ".json")).read_text())["text"]
                    if not isinstance(ref_text, str) or not ref_text.strip() or len(ref_text.encode()) > 1400:
                        raise ValueError("invalid reference text")
                    with wave.open(str(root / (stem + ".wav")), "rb") as file:
                        if file.getnchannels() != 1 or file.getsampwidth() != 2 or file.getframerate() != 24000 or not 12000 <= file.getnframes() <= 720000:
                            raise ValueError("invalid reference audio")
                        reference = np.frombuffer(file.readframes(file.getnframes()), dtype="<i2").astype(np.float32) / 32768
                    references[voice] = (mx.array(resample_poly(reference, 147, 80)), ref_text)
                ref_audio, ref_text = references[voice]
                # This port can speak free-form system instructions verbatim.
                # A fixed synthetic reference supplies the voice without adding words.
                results = model.generate(text=text, ref_audio=ref_audio, ref_text=ref_text,
                    temperature=0.7, top_p=0.7, top_k=30, max_tokens=2048,
                    stream=False, chunk_length=1400, verbose=False)
            elif engine == "kokoro":
                # Absolute local tensor paths avoid the port's voice downloader.
                results = model.generate(text=text, voice=str(path / "voices" / (spec["preset"] + ".safetensors")),
                                         lang_code=spec["language"], speed=1.0)
            elif engine == "voxcpm":
                # The fixed setup-time synthetic prompt anchors speaker identity and
                # delivery across chunks without retaining any prior user speech.
                if voice not in references:
                    references[voice] = voxcpm_reference(path, spec)
                prompt_audio, prompt_text = references[voice]
                mx.random.seed(42)
                results = model.generate(text=text, prompt_audio=prompt_audio, prompt_text=prompt_text,
                                         inference_timesteps=6, cfg_value=2.0, max_tokens=1200)
            elif engine == "voxtral":
                results = model.generate(text=text, voice=spec["preset"], max_tokens=1200,
                                         stream=True, streaming_interval=0.8, verbose=False)
            else:
                results = model.generate_custom_voice(
                    text=text, speaker=voice, language="Auto", instruct=STYLE,
                    temperature=0.7, max_tokens=2048, verbose=False,
                    stream=True, streaming_interval=0.8)
            sample_count = 0
            for result in results:
                samples = np.asarray(result.audio, dtype="<f4").reshape(-1)
                if samples.size == 0:
                    continue
                expected_rate = {"fish": 44100, "voxcpm": 48000}.get(engine, 24000)
                if result.sample_rate != expected_rate:
                    raise ValueError("invalid sample rate")
                if not np.isfinite(samples).all():
                    raise ValueError("invalid audio")
                if expected_rate != 24000:
                    from scipy.signal import resample_poly
                    from math import gcd
                    divisor = gcd(expected_rate, 24000)
                    samples = np.asarray(resample_poly(samples, 24000 // divisor, expected_rate // divisor), dtype="<f4")
                sample_count += samples.size
                if sample_count > 24_000 * 90 or not np.isfinite(samples).all():
                    raise ValueError("invalid audio")
                for offset in range(0, samples.size, 19_200):
                    emit({"event": "audio", "id": request_id, "sample_rate": 24000,
                          "pcm": base64.b64encode(samples[offset:offset + 19_200].tobytes()).decode("ascii")})
            if sample_count == 0:
                raise ValueError("no audio")
            emit({"event": "done", "id": request_id,
                  "elapsed": round(time.monotonic() - started, 3),
                  "peak_memory_gb": round(mx.get_peak_memory() / 1e9, 3)})
        except (BrokenPipeError, KeyboardInterrupt):
            return
        except Exception:
            # Never echo the exception: library exceptions can include input text.
            emit({"event": "error", "id": request_id, "code": "generation_failed"})


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    except Exception:
        emit({"event": "error", "code": "load_failed"})
        sys.exit(1)
