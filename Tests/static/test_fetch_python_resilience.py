#!/usr/bin/env python3
"""Static contract for the Xcode Cloud Python runtime download."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "support" / "fetch-python.sh"


class FetchPythonResilienceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SCRIPT.read_text(encoding="utf-8")

    def test_transient_network_failures_are_retried(self) -> None:
        for option in (
            "--retry 5",
            "--retry-all-errors",
            "--retry-delay 2",
            "--connect-timeout 30",
            "--retry-max-time 600",
        ):
            with self.subTest(option=option):
                self.assertIn(option, self.source)

    def test_partial_download_is_cleaned_up(self) -> None:
        self.assertIn('DOWNLOAD_PATH="$FW_DIR/${TARBALL}.part"', self.source)
        self.assertIn("trap cleanup EXIT", self.source)
        self.assertIn('rm -f "$DOWNLOAD_PATH"', self.source)

    def test_archive_is_validated_before_stale_framework_is_removed(self) -> None:
        validation = self.source.index('tar -tzf "$DOWNLOAD_PATH"')
        destructive_cleanup = self.source.index('rm -rf "$FW_DIR/Python.xcframework"')
        self.assertLess(validation, destructive_cleanup)

    def test_corrupt_download_preserves_existing_framework(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            support = root / "support"
            framework = root / "Frameworks" / "Python.xcframework"
            fake_bin = root / "bin"
            support.mkdir()
            framework.mkdir(parents=True)
            fake_bin.mkdir()

            shutil.copy2(SCRIPT, support / "fetch-python.sh")
            sentinel = framework / "existing-runtime"
            sentinel.write_text("keep", encoding="utf-8")
            (root / "Frameworks" / "VERSIONS").write_text("Build: old\n", encoding="utf-8")

            fake_curl = fake_bin / "curl"
            fake_curl.write_text(
                """#!/bin/bash
set -eu
output=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--output" ]; then
        shift
        output="$1"
    fi
    shift
done
printf 'not a gzip archive' > "$output"
""",
                encoding="utf-8",
            )
            fake_curl.chmod(0o755)

            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
            result = subprocess.run(
                [str(support / "fetch-python.sh")],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")
            self.assertFalse(any((root / "Frameworks").glob("*.part")))
            self.assertFalse(any((root / "Frameworks").glob(".python-stage.*")))


if __name__ == "__main__":
    unittest.main()
