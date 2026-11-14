"""Download only pinned data assets and verify every byte before enabling voices."""
import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = json.loads((ROOT / "engine/narrator-models.json").read_text())


def verify(path, record):
    if not path.is_file() or path.stat().st_size != record["size"]:
        return False
    digest = hashlib.sha256() if record["algorithm"] == "sha256" else hashlib.sha1()
    if record["algorithm"] == "git-sha1":
        digest.update(f"blob {record['size']}\0".encode())
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest() == record["digest"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", choices=["all", *SOURCES], default="all", nargs="?")
    args = parser.parse_args()
    from huggingface_hub import snapshot_download
    for key in SOURCES if args.model == "all" else [args.model]:
        source = SOURCES[key]
        target = ROOT / "models" / source["directory"]
        target.mkdir(parents=True, exist_ok=True)
        ready = target / ".clearspeak-ready.json"
        ready.unlink(missing_ok=True)
        print(f"Preparing {key} at pinned revision {source['revision']}", flush=True)
        snapshot_download(source["repo"], revision=source["revision"],
                          local_dir=target, allow_patterns=list(source["files"]),
                          max_workers=3, token=False)
        for name, record in source["files"].items():
            if not verify(target / name, record):
                raise RuntimeError(f"Checksum failed for {key}/{name}")
        # Dependency checks do not initialize models or permit inference downloads.
        if key == "kokoro":
            import en_core_web_sm
            from misaki import en, espeak
            en.G2P(trf=False, fallback=espeak.EspeakFallback(british=False))
        if key == "voxtral":
            subprocess.run(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
                str(ROOT / ".local-runtime/voxtral/bin/python"), "-c",
                "from mistral_common.tokens.tokenizers.mistral import MistralTokenizer; "
                "import sys; MistralTokenizer.from_file(sys.argv[1])", str(target / "tekken.json")], check=True)
        ready.write_text(json.dumps({"revision": source["revision"], "files": source["files"]}, indent=2) + "\n")
        print(f"Verified {key}: {len(source['files'])} pinned files", flush=True)


if __name__ == "__main__":
    os.environ.update(HF_HUB_DISABLE_TELEMETRY="1", HF_HUB_DOWNLOAD_TIMEOUT="120")
    main()
