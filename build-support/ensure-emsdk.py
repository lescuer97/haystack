#!/usr/bin/env python3
"""Install the pinned SDK once, rather than updating emsdk on every build."""
from pathlib import Path
import argparse
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("root", type=Path)
parser.add_argument("--offline", action="store_true")
args = parser.parse_args()
root = args.root.resolve()
emcc = root / "upstream/emscripten/emcc.py"
if emcc.is_file() and (root / ".emscripten").is_file():
    version = subprocess.run([sys.executable, str(emcc), "--version"], capture_output=True, text=True, timeout=30)
    if version.returncode == 0 and "4.0.19" in version.stdout.partition("\n")[0]:
        sys.exit(0)

if args.offline:
    sys.exit("Emscripten 4.0.19 is missing or incompatible; run once without -Doffline to provision it")
sdk = root / "emsdk.py"
for command in (["update"], ["install", "4.0.19"], ["activate", "4.0.19"]):
    # Bound transient network failures during first installation, never silently
    # reuse an incompatible or partially installed toolchain.
    subprocess.run([sys.executable, str(sdk), *command], cwd=root, check=True, timeout=600)
for script in (emcc, root / "upstream/emscripten/emrun"):
    script.chmod(script.stat().st_mode | 0o111)
