#!/bin/zsh
# Everything that has to pass before a change is merged. CI runs exactly this script.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

python3 scripts/check-vendored.py
scripts/check-secrets.sh
xcrun swift-format lint --strict --recursive Package.swift Sources Tests
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
