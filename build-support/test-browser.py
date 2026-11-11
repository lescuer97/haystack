#!/usr/bin/env python3
"""Own the test fixture process for one Zig browser-test step, including cleanup."""
import argparse
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import sys
import threading

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mint", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--runner", type=Path, required=True)
    args = parser.parse_args()
    if not shutil.which("node"):
        parser.error("Node 22+ is required for browser tests")
    if not shutil.which(os.environ.get("CHROMIUM", "chromium")):
        parser.error("Chromium is required for browser tests (or set CHROMIUM=/path/to/browser)")
    env = dict(os.environ, BROWSER_TEST_PORT="0")
    mint = subprocess.Popen([str(args.mint.resolve()), str(args.directory.resolve())], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = queue.Queue()
    def read_lines():
        for line in mint.stdout:
            lines.put(line)
        lines.put(None)
    threading.Thread(target=read_lines, daemon=True).start()
    try:
        while True:
            line = lines.get(timeout=60)
            if line is None:
                raise RuntimeError(f"fake mint exited before readiness (status {mint.wait()})")
            print(line, end="", flush=True)
            match = re.search(r"Local fake mint ready: (http://127\.0\.0\.1:\d+/\?smoke)", line)
            if match:
                url = match.group(1)
                break
        subprocess.run(["node", str(args.runner.resolve()), url], check=True, timeout=300)
    finally:
        mint.terminate()
        try:
            mint.wait(timeout=10)
        except subprocess.TimeoutExpired:
            mint.kill()
            mint.wait()

if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired, queue.Empty) as error:
        sys.exit(f"browser test failed: {error}")
