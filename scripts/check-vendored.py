#!/usr/bin/env python3
"""Verifies the vendored Hunspell engine and the bundled dictionaries against their pinned checksums.

No network access and nothing is generated: the script only reads files and compares SHA-256 digests.
"""
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def verify(path: Path, expected: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"Missing or linked file: {path.relative_to(ROOT)}")
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit(f"Checksum mismatch: {path.relative_to(ROOT)}")


engine = ROOT / "ThirdParty/Hunspell"
manifest = json.loads((engine / "manifest.json").read_text())
if manifest["version"] != "1.7.6":
    raise SystemExit("Unexpected Hunspell version")
pinned = manifest["sourceSHA256"] | manifest["generatedSHA256"]
for name, digest in pinned.items():
    verify(engine / name, digest)
expected_sources = {name for name in pinned if name.startswith("src/")}
actual_sources = {str(path.relative_to(engine)) for path in (engine / "src").rglob("*") if path.is_file()}
if actual_sources != expected_sources:
    raise SystemExit(f"Hunspell source inventory differs: {sorted(actual_sources ^ expected_sources)}")

dictionaries = ROOT / "Sources/LangSwitchLexicon/Resources/Hunspell"
for language in json.loads((dictionaries / "manifest.json").read_text())["languages"]:
    for name, record in language["files"].items():
        verify(dictionaries / language["language"] / name, record["sha256"])

print("OK: vendored Hunspell sources and RU/EN dictionaries match their pinned checksums")
sys.exit(0)
