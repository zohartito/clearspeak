#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# No XCTest dependency: runs with Xcode Command Line Tools alone.
swift run ClearSpeakChecks
python3 scripts/check-narrator-assets.py
python3 scripts/check-narrator-cli.py
python3 scripts/check-repository.py
