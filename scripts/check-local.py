"""Real offline synthesis benchmark. Only these fixed, harmless sample texts are used."""
import argparse
import base64
import json
import selectors
import subprocess
import time
import wave
from pathlib import Path

import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument("--voice", choices=["Fish"], help="Check a new local engine twice, including warm reuse")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
model = "fish-s2-pro-8bit" if args.voice else "qwen3-tts-1.7b-bf16"
process = subprocess.Popen(
    ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
     str(root / ".venv/bin/python"), str(root / "engine/worker.py"),
     str(root / "models" / model)],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
)
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
buffer = bytearray()


def message():
    while b"\n" not in buffer:
        if not selector.select(120):
            raise RuntimeError("Local engine timed out")
        data = process.stdout.read1(1024 * 1024)
        if not data:
            raise RuntimeError("Local engine exited")
        buffer.extend(data)
    line, _, rest = buffer.partition(b"\n")
    buffer[:] = rest
    return json.loads(line)


metrics = []
try:
    started = time.monotonic()
    if message()["event"] != "ready":
        raise RuntimeError("Model failed to load")
    print(f"Model load: {time.monotonic() - started:.2f}s", flush=True)
    voices = (args.voice, args.voice) if args.voice else ("Ryan", "Ryan", "Aiden")
    for index, voice in enumerate(voices):
        text = "Take a breath. ClearSpeak now reads aloud entirely on your Mac, with a natural voice and no subscription."
        started = time.monotonic()
        process.stdin.write((json.dumps({"id": str(index), "text": text, "voice": voice}) + "\n").encode())
        process.stdin.flush()
        chunks, first_audio = [], None
        while True:
            result = message()
            if result["event"] == "error":
                raise RuntimeError("Local synthesis failed")
            if result["event"] == "audio":
                first_audio = first_audio if first_audio is not None else time.monotonic() - started
                chunks.append(base64.b64decode(result["pcm"]))
            elif result["event"] == "done":
                break
        audio = np.frombuffer(b"".join(chunks), dtype="<f4")
        assert audio.size > 24000 and np.isfinite(audio).all() and abs(audio).max() > 0.01
        duration = audio.size / 24000
        record = {"voice": voice, "run": index + 1, "first_audio_s": round(first_audio, 3),
                  "audio_s": round(duration, 3), "generation_s": result["elapsed"],
                  "speed_vs_realtime": round(duration / result["elapsed"], 3),
                  "peak_memory_gb": result["peak_memory_gb"], "chunks": len(chunks)}
        print(json.dumps(record), flush=True)
        metrics.append(record)
        slug = voice.lower().replace(" (", "-").replace(")", "").replace(" ", "-")
        output = root / "dist" / f"local-{slug}.wav"
        output.parent.mkdir(exist_ok=True)
        with wave.open(str(output), "wb") as file:
            file.setnchannels(1); file.setsampwidth(2); file.setframerate(24000)
            file.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
    report = f"dist/{slug}-benchmark.json" if args.voice else "dist/local-benchmark.json"
    (root / report).write_text(json.dumps(metrics, indent=2) + "\n")
    # Cancel real, in-progress native generation, not only a mocked stream.
    process.stdin.write((json.dumps({"id": "cancel-check", "text": "The quiet courtyard fills with morning light. " * 10,
                                    "voice": voices[-1]}) + "\n").encode())
    process.stdin.flush()
    time.sleep(.15)
    started = time.monotonic()
    process.terminate()
    process.wait(timeout=3)
    cancellation = {"voice": voices[-1], "termination_s": round(time.monotonic() - started, 3), "exit": process.returncode}
    print(json.dumps(cancellation), flush=True)
    (root / "dist" / (slug + "-cancellation.json")).write_text(json.dumps(cancellation, indent=2) + "\n")
finally:
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill(); process.wait()
