"""Explicit, fixed-text local auditions. Ordinary app readings never save audio.

Run with .venv/bin/python scripts/audition-local.py breeze (or fish/qwen).
The parent launches the evaluation in the same network-denied sandbox as the app.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import wave

ROOT = Path(__file__).resolve().parents[1]
MODELS = {
    "breeze": ("breeze-tts-2-bf16", "3c8829fb7fd335818f085cd2ef49b4100c0e46c8"),
    "fish": ("fish-s2-pro-bf16", "eccd57bf5c1ebc13cb2f993df867f4e49931a36a"),
    "fish8": ("fish-s2-pro-8bit", "local 8-bit conversion of eccd57bf5c1ebc13cb2f993df867f4e49931a36a"),
    "qwen": ("qwen3-tts-1.7b-bf16", "52f4770fd9726457eae3d3b6aa92047a25a10776"),
}
CORPUS = {
    "illustrative": "This illustrative diagram shows how daylight enters the courtyard. It is an illustrative example of a simple idea: give every room a view of the sky.",
    "architecture": "The illustrative axonometric drawing reveals a cantilever above the colonnade. Along the facade, the clerestory brings diffuse light into the atrium. The poche marks the solid walls; the circulation stays open.",
    "ordinary": 'I thought we had more time. Then the door opened, and everyone looked up. "Are you ready?" she asked. I took a breath, smiled, and said, "Yes. Let us begin."',
    "context": "Please record the record carefully. The minute detail took a minute to explain. At 3:45 p.m., Dr. Chen measured 2.5 meters and noted a 12 percent increase. The material was anisotropic, porous, and translucent.",
}
STYLE = "An adult male English speaker with a warm, natural conversational voice, relaxed pacing and clear pronunciation."


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", choices=MODELS)
    parser.add_argument("--child", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--reference", choices=["ryan"], help="Fish reference from the fixed local synthetic Qwen sample")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/auditions-20260908")
    parser.add_argument("--items", nargs="+", choices=CORPUS, default=list(CORPUS))
    args = parser.parse_args()
    if not args.child:
        command = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
                   sys.executable, str(Path(__file__).resolve()), *sys.argv[1:], "--child"]
        env = {"PATH": "/usr/bin:/bin", "HOME": str(Path.home()), "PYTHONUNBUFFERED": "1",
               "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1"}
        return subprocess.run(command, env=env, timeout=1800).returncode

    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
    import mlx.core as mx
    import numpy as np
    from scipy.signal import resample_poly
    from math import gcd
    from mlx_audio.tts.utils import load_model

    args.output.mkdir(parents=True, exist_ok=True)
    directory, revision = MODELS[args.model]
    started = time.monotonic()
    model = load_model(ROOT / "models" / directory, lazy=False)
    load_seconds = time.monotonic() - started
    print(json.dumps({"model": args.model, "load_s": round(load_seconds, 3)}), flush=True)
    records = []

    def save(name, audio, record):
        audio = np.asarray(audio, dtype=np.float32).reshape(-1)
        if not 2400 <= audio.size <= 24000 * 90 or not np.isfinite(audio).all() or abs(audio).max() < .001:
            raise ValueError("Invalid generated audition audio")
        record.update(file=name + ".wav", audio_s=round(audio.size / 24000, 3),
                      peak=float(abs(audio).max()), mlx_peak_gb=round(mx.get_peak_memory() / 1e9, 3))
        with wave.open(str(args.output / (name + ".wav")), "wb") as output:
            output.setnchannels(1); output.setsampwidth(2); output.setframerate(24000)
            output.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
        (args.output / (name + ".json")).write_text(json.dumps(record, indent=2) + "\n")
        records.append(record)
        print(json.dumps(record), flush=True)

    for item in args.items:
        text = CORPUS[item]
        mx.random.seed(42)
        started = time.monotonic(); first = None; chunks = []
        if args.model == "qwen":
            results = model.generate_custom_voice(text=text, speaker="Ryan", language="English",
                instruct="Speak in a warm, natural, conversational way with relaxed pacing and clear pronunciation.",
                temperature=.7, max_tokens=2048, stream=True, streaming_interval=.8)
        else:
            options = dict(text=text, max_tokens=2048)
            if args.model == "breeze":
                options.update(instruct=STYLE, cfg_scale=4., temperature=.9, stream=True, streaming_interval=1.)
            else:
                options.update(temperature=.7, stream=False, chunk_length=600, verbose=False)
                if args.reference:
                    with wave.open(str(ROOT / "models/fish-reference/ordinary-qwen.wav"), "rb") as file:
                        reference = np.frombuffer(file.readframes(file.getnframes()), dtype="<i2").astype(np.float32) / 32768
                        divisor = gcd(file.getframerate(), model.sample_rate)
                        reference = resample_poly(reference, model.sample_rate // divisor, file.getframerate() // divisor)
                    options.update(ref_audio=mx.array(reference), ref_text=CORPUS["ordinary"])
            results = model.generate(**options)
        for result in results:
            audio = np.asarray(result.audio, dtype=np.float32).reshape(-1)
            if first is None and audio.size: first = time.monotonic() - started
            if result.sample_rate != 24000:
                divisor = gcd(result.sample_rate, 24000)
                audio = resample_poly(audio, 24000 // divisor, result.sample_rate // divisor)
            chunks.append(audio)
            if sum(len(chunk) for chunk in chunks) > 24000 * 90: raise ValueError("Audition too long")
        elapsed = time.monotonic() - started
        audio = np.concatenate(chunks)
        variant = args.model + ("-" + args.reference if args.reference else "")
        name = f"{item}-{variant}"
        save(name, audio, dict(model=args.model, revision=revision, text=text, seed=42,
             style=STYLE if args.model == "breeze" else "Qwen conversational style; explicit English" if args.model == "qwen" else "No style instructions; reference=" + str(args.reference),
             load_s=round(load_seconds, 3), first_audio_s=round(first, 3), generation_s=round(elapsed, 3),
             speed_vs_realtime=round(len(audio) / 24000 / elapsed, 3), network="denied", chunks=len(chunks),
             evidence="Fixed paragraph, no Swift chunking; signal validation only; human listening pending"))
    (args.output / (variant + "-index.json")).write_text(json.dumps(records, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
