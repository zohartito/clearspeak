"""Fast offline checks for pinned asset verification and worker voice routing."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
from voice_catalog import CATALOG, VOICES, voice_for_model

spec = importlib.util.spec_from_file_location("setup_narrators", ROOT / "scripts/setup-narrators.py")
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class AssetChecks(unittest.TestCase):
    def test_download_checksums_reject_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "asset"
            path.write_bytes(b"safe model fixture")
            data = path.read_bytes()
            for algorithm, digest in [("sha256", hashlib.sha256(data).hexdigest()),
                    ("git-sha1", hashlib.sha1(f"blob {len(data)}\0".encode()+data).hexdigest())]:
                record = {"size": len(data), "algorithm": algorithm, "digest": digest}
                self.assertTrue(setup.verify(path, record))
                path.write_bytes(b"x" * len(data))
                self.assertFalse(setup.verify(path, record))
                path.write_bytes(data)
            self.assertFalse(setup.verify(path.parent / "missing", record))

    def test_worker_rejects_wrong_model_and_missing_voice_asset(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "kokoro-82m-bf16"
            path.mkdir()
            for file in VOICES["Heart (Kokoro)"]["files"]:
                target = path / file
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b"fixture")
            self.assertEqual(voice_for_model("Heart (Kokoro)", path)["engine"], "kokoro")
            with self.assertRaises(ValueError):
                voice_for_model("Casual Male (Voxtral)", path)
            with self.assertRaises(ValueError):
                voice_for_model("Bella (Kokoro)", path)
            (path / "voices/af_heart.safetensors").unlink()
            with self.assertRaises(ValueError):
                voice_for_model("Heart (Kokoro)", path)

    def test_new_assets_are_covered_by_pinned_downloads(self):
        sources = setup.SOURCES
        for voice in CATALOG:
            if voice["engine"] not in sources:
                continue
            source = sources[voice["engine"]]
            self.assertEqual(voice["directory"], source["directory"])
            self.assertRegex(source["revision"], r"^[0-9a-f]{40}$")
            for file in voice["files"]:
                if file.startswith("../narrator-reference/") or file == ".clearspeak-ready.json":
                    continue
                self.assertIn(file, source["files"])
            for file, record in source["files"].items():
                self.assertNotIn("..", Path(file).parts)
                self.assertNotIn(Path(file).suffix, [".pt", ".pth", ".py", ".pkl"])
                self.assertGreater(record["size"], 0)


if __name__ == "__main__":
    unittest.main()
