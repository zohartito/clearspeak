"""Offline checks for repository requirements and documentation contracts."""
from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RepositoryChecks(unittest.TestCase):
    def test_clr01_minimum_macos_matches_pinned_runtime(self):
        readme = re.search(r"- macOS (\d+) or later\.", (ROOT / "README.md").read_text()).group(1)
        package = re.search(r"\.macOS\(\.v(\d+)\)", (ROOT / "Package.swift").read_text()).group(1)
        with (ROOT / "Resources/Info.plist").open("rb") as file:
            bundle = plistlib.load(file)["LSMinimumSystemVersion"]
        # mlx==0.32.2 has arm64 wheels starting at macOS 14, not macOS 13.
        self.assertEqual([readme, package, bundle], ["14", "14", "14.0"])

    def test_clr06_fish_license_link_uses_audited_target(self):
        # Offline regression for the audited model-card target, not an HTTP availability check.
        targets = re.findall(r"\[Fish Audio Research License\]\(([^)]+)\)", (ROOT / "README.md").read_text())
        self.assertEqual(targets, ["https://huggingface.co/fishaudio/s2-pro/blob/main/LICENSE.md"])

    def test_clr15_actions_use_commit_pins(self):
        refs = [ref for workflow in (ROOT / ".github/workflows").glob("*.y*ml")
                for ref in re.findall(r"^\s*-?\s*uses:\s*([^\s#]+)", workflow.read_text(), re.M)]
        self.assertTrue(refs)
        mutable = [ref for ref in refs if not ref.startswith("./") and not re.fullmatch(r"[^@]+@[0-9a-f]{40}", ref)]
        self.assertEqual(mutable, [])


if __name__ == "__main__":
    unittest.main()
