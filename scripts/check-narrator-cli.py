"""Offline CLI routing checks; workers, audio and NumPy are test doubles."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, Mock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("check_narrators", ROOT / "scripts/check-narrators.py")
checker = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {"numpy": MagicMock()}):
    spec.loader.exec_module(checker)


class NarratorCLIChecks(unittest.TestCase):
    def run_checker(self, arguments=(), missing=()):
        def worker(directory, python):
            result = Mock()
            result.receive.return_value = {"event": "error" if directory in missing else "ready"}
            result.generate.return_value = (Mock(), {})
            result.process.returncode = 0
            return result

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(sys, "argv", ["check-narrators.py", "--output", directory, *arguments]), \
                patch.object(checker, "Worker", side_effect=worker), \
                patch.object(checker.wave, "open"), patch.object(checker.time, "sleep"), \
                redirect_stdout(io.StringIO()):
            checker.main()
            return json.loads((Path(directory) / "metrics.json").read_text())

    def test_clr02_defaults_require_only_narrator_pack(self):
        records = self.run_checker(missing=("fish-s2-pro-8bit", "qwen3-tts-1.7b-bf16"))
        expected = ["Heart (Kokoro)", "Bella (Kokoro)", "Michael (Kokoro)", "Emma (Kokoro)",
                    "Warm Male (VoxCPM)", "Warm Female (VoxCPM)",
                    "Casual Male (Voxtral)", "Casual Female (Voxtral)"]
        self.assertEqual([record["voice"] for record in records], [voice for voice in expected for _ in range(2)])

    def test_clr02_load_failure_identifies_voice(self):
        with self.assertRaisesRegex(RuntimeError, r"Worker failed to load.*Warm Male \(Fish\)"):
            self.run_checker(["--voices", "Warm Male (Fish)"], missing=("fish-s2-pro-8bit",))

    def test_clr02_explicit_optional_voices_remain_supported(self):
        records = self.run_checker(["--voices", "Fish", "Ryan"])
        self.assertEqual([record["voice"] for record in records], ["Fish", "Fish", "Ryan", "Ryan"])


if __name__ == "__main__":
    unittest.main()
