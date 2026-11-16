"""Explicit real-worker auditions using fixed harmless text, never user selections."""
import argparse
import base64
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time
import wave

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
from voice_catalog import VOICES

TEXT = "Take a breath. The morning light fills the quiet courtyard. We have time to explore this idea together."
LONG_TEXT = [
    "The morning light enters through a tall window and falls across the table.",
    "Outside, the street is beginning to wake up, but the room still feels quiet.",
    "An illustrative drawing shows how the courtyard connects the rooms.",
    "The architect studies the facade, the clerestory, and the shaded colonnade.",
    "At three forty-five, we pause to compare the two plans and discuss what changed.",
    "There is no need to hurry. A careful question often reveals a better answer.",
]


class Worker:
    def __init__(self, directory, python):
        env = {"PATH": "/usr/bin:/bin", "HOME": str(Path.home()), "PYTHONUNBUFFERED": "1",
               "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1"}
        self.process = subprocess.Popen(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
            str(python), str(ROOT / "engine/worker.py"), str(ROOT / "models" / directory)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = bytearray()

    def receive(self):
        deadline = time.monotonic() + 120
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise RuntimeError("Worker timeout")
            data = self.process.stdout.read1(1024 * 1024)
            if not data:
                raise RuntimeError("Worker exited")
            self.buffer.extend(data)
            if len(self.buffer) > 8_000_000:
                raise RuntimeError("Oversized worker message")
        line, _, rest = self.buffer.partition(b"\n")
        self.buffer[:] = rest
        return json.loads(line)

    def send(self, voice, text, request):
        self.process.stdin.write((json.dumps({"id": request, "voice": voice, "text": text}) + "\n").encode())
        self.process.stdin.flush()

    def generate(self, voice, text, request):
        started = time.monotonic()
        self.send(voice, text, request)
        audio, first = [], None
        while True:
            message = self.receive()
            if message.get("event") == "error":
                raise RuntimeError("Worker generation failed")
            if message.get("id") != request:
                raise RuntimeError("Wrong worker request ID")
            if message["event"] == "done":
                break
            if message["event"] != "audio" or message["sample_rate"] != 24000:
                raise RuntimeError("Bad worker protocol")
            if first is None:
                first = time.monotonic() - started
            audio.append(np.frombuffer(base64.b64decode(message["pcm"], validate=True), dtype="<f4"))
        audio = np.concatenate(audio) if audio else np.array([])
        if not 2400 <= len(audio) <= 24000 * 90 or not np.isfinite(audio).all() or abs(audio).max() < .001:
            raise RuntimeError("Invalid generated signal")
        elapsed = time.monotonic() - started
        return audio, {"first_audio_s": round(first, 3), "audio_s": round(len(audio)/24000, 3),
            "generation_s": round(elapsed, 3), "audio_seconds_per_wall_second": round(len(audio)/24000/elapsed, 3),
            "mlx_peak_gb": message["peak_memory_gb"]}

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait()
        self.selector.close()
        self.process.stdin.close(); self.process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--voices", nargs="+", choices=list(VOICES),
                        default=[name for name, voice in VOICES.items()
                                 if voice["engine"] in {"kokoro", "voxcpm", "voxtral"}])
    parser.add_argument("--long-form", action="store_true", help="Repeat fixed paragraphs for a longer continuity audition")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/narrator-checks")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    records = []
    for voice in args.voices:
        spec = VOICES[voice]
        worker = Worker(spec["directory"] or "qwen3-tts-1.7b-bf16",
                        ROOT / spec.get("pythonRelativePath", ".venv/bin/python"))
        started = time.monotonic()
        try:
            if worker.receive()["event"] != "ready":
                raise RuntimeError(f"Worker failed to load: {voice}")
            load = round(time.monotonic() - started, 3)
            slug = voice.lower().replace(" (", "-").replace(")", "").replace(" ", "-")
            clips = []
            texts = LONG_TEXT * 6 if args.long_form else [TEXT, TEXT]
            for index, text in enumerate(texts):
                audio, metrics = worker.generate(voice, text, str(index))
                clips.append(audio)
                record = dict(voice=voice, run=index + 1, load_s=load, network="denied", **metrics)
                records.append(record)
                print(json.dumps(record), flush=True)
            with wave.open(str(args.output / (slug + ".wav")), "wb") as out:
                out.setnchannels(1); out.setsampwidth(2); out.setframerate(24000)
                # The two short runs are separate tests; save only the warm run.
                audio = np.concatenate(clips) if args.long_form else clips[-1]
                out.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
            worker.send(voice, TEXT * 3, "cancel")
            time.sleep(.15)
            started = time.monotonic()
            worker.process.terminate(); worker.process.wait(timeout=3)
            cancellation = dict(voice=voice, termination_s=round(time.monotonic()-started, 3), exit=worker.process.returncode)
            print(json.dumps(cancellation), flush=True)
            (args.output / (slug + "-cancellation.json")).write_text(json.dumps(cancellation, indent=2) + "\n")
        finally:
            worker.close()
            (args.output / "metrics.json").write_text(json.dumps(records, indent=2) + "\n")


if __name__ == "__main__":
    main()
