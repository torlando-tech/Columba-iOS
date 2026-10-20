#!/usr/bin/env python3
"""Behavioral contract for support/bootstrap-pip.sh's host-version branch.

Xcode Cloud fresh clones run the post-clone hook on macOS system python3
(3.9.6). The rolling bootstrap.pypa.io/pip/pip.pyz tracks the LATEST pip,
which requires >= 3.10, so a 3.9 host MUST bootstrap from pypa's
per-version get-pip channel instead - getting this wrong fails every
Release build before xcodebuild starts. These tests drive the script with
stubbed python3/curl and assert the selected URL, the bootstrap command,
and the pip version floor.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BOOTSTRAP = ROOT / "support" / "bootstrap-pip.sh"

# Stub python3: honors SIM_PY for the >= (3, 10) probe and the %d.%d series
# print, builds pip-less venvs by copying ITSELF to <dir>/bin/python, echoes
# PIP_VERSION_LINE for `-m pip --version`, and records every other invocation
# (pip.pyz / get-pip.py runs) to STUB_LOG.
PYTHON_STUB = """#!/bin/bash
SIM_MAJOR="${SIM_PY%%.*}"; SIM_MINOR="${SIM_PY##*.}"
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
    dir="${@: -1}"
    mkdir -p "$dir/bin"
    cp "$0" "$dir/bin/python"
    exit 0
fi
if [ "$1" = "-m" ] && [ "$2" = "pip" ] && [ "$3" = "--version" ]; then
    echo "$PIP_VERSION_LINE"
    exit 0
fi
if [ "$1" = "-c" ]; then
    case "$2" in
        *"version_info >= (3, 10)"*)
            if [ "$SIM_MAJOR" -gt 3 ] || { [ "$SIM_MAJOR" -eq 3 ] && [ "$SIM_MINOR" -ge 10 ]; }; then
                exit 0
            fi
            exit 1
            ;;
        *print*)
            echo "$SIM_PY"
            exit 0
            ;;
    esac
    exit 0
fi
echo "RUN $*" >> "$STUB_LOG"
exit 0
"""

CURL_STUB = """#!/bin/bash
url="${@: -1}"
echo "CURL $url" >> "$STUB_LOG"
prev=""
for a in "$@"; do
    if [ "$prev" = "--output" ]; then : > "$a"; fi
    prev="$a"
done
exit 0
"""


class PipBootstrapTests(unittest.TestCase):
    def run_bootstrap(self, sim_py: str, pip_version_line: str):
        tmp = Path(tempfile.mkdtemp())
        bindir = tmp / "bin"
        bindir.mkdir()
        log = tmp / "calls.log"
        log.touch()
        for name, body in (("python3", PYTHON_STUB), ("curl", CURL_STUB)):
            stub = bindir / name
            stub.write_text(body)
            stub.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = f"{bindir}{os.pathsep}{env['PATH']}"
        env["SIM_PY"] = sim_py
        env["PIP_VERSION_LINE"] = pip_version_line
        env["STUB_LOG"] = str(log)
        proc = subprocess.run(
            ["bash", str(BOOTSTRAP)],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        return proc, log.read_text()

    def test_old_host_uses_per_version_get_pip_channel(self) -> None:
        # The Xcode Cloud runner case: python 3.9 must NEVER touch the
        # rolling zipapp (it aborts with "requires >= 3.10").
        proc, log = self.run_bootstrap("3.9", "pip 25.0.1 from /x (python 3.9)")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(
            "CURL https://bootstrap.pypa.io/pip/3.9/get-pip.py", log
        )
        self.assertNotIn("pip/pip.pyz", log)
        runs = [line for line in log.splitlines() if line.startswith("RUN ") and "get-pip.py" in line]
        self.assertTrue(runs, "get-pip.py was never executed")
        self.assertIn("setuptools==80.9.0", runs[0])
        self.assertIn("wheel==0.45.1", runs[0])

    def test_modern_host_keeps_rolling_zipapp_and_pip_pin(self) -> None:
        proc, log = self.run_bootstrap("3.13", "pip 26.2.1 from /x (python 3.13)")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("CURL https://bootstrap.pypa.io/pip/pip.pyz", log)
        self.assertNotIn("get-pip", log)
        runs = [line for line in log.splitlines() if line.startswith("RUN ") and "pip.pyz" in line]
        self.assertTrue(runs, "pip.pyz was never executed")
        self.assertIn("pip==26.2.1", runs[0])
        self.assertIn("setuptools==80.9.0", runs[0])

    def test_pip_version_floor_rejects_old_pip_on_both_branches(self) -> None:
        # pip < 25 lacks the PEP 621 / cross-platform behavior the wheel
        # fetch relies on; the bootstrap must fail loudly instead.
        for sim_py in ("3.9", "3.13"):
            with self.subTest(sim_py=sim_py):
                proc, _ = self.run_bootstrap(sim_py, "pip 24.0 from /x (python 3.9)")
                self.assertNotEqual(proc.returncode, 0)


if __name__ == "__main__":
    unittest.main()
