#!/usr/bin/env python3
"""Regression contract: tag-driven release versioning.

Release builds are triggered by pushing a tag vMAJOR.MINOR.PATCH, and
ci_scripts/ci_pre_xcodebuild.sh stamps MARKETING_VERSION in
Config/Signing.xcconfig from $CI_TAG before every Xcode Cloud build.
This is release-critical: a silent regression here ships the wrong
CFBundleShortVersionString to TestFlight, or worse, ships the stale
fallback while believing the tag was applied.

The contract exercises the real script (via CI_PRIMARY_REPOSITORY_PATH
pointed at a throwaway tree) across the full tag matrix, and pins the
structural invariant that makes the stamp effective: MARKETING_VERSION
must live ONLY in the xcconfig, never in project.pbxproj (an assignment
in the pbxproj would override the xcconfig and silently defeat the
whole mechanism).

Run with:
    python3 -B -m unittest Tests.static.test_tag_version_stamp
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci_scripts" / "ci_pre_xcodebuild.sh"
XCCONFIG = ROOT / "Config" / "Signing.xcconfig"
PBXPROJ = ROOT / "Columba.xcodeproj" / "project.pbxproj"

FALLBACK = "0.0.4"
XCCONFIG_TEMPLATE = f"""\
DEVELOPMENT_TEAM = M2977H5PM5
MARKETING_VERSION = {FALLBACK}
#include? "LocalSigning.xcconfig"
"""


def run_script(repo_root: Path, ci_tag=None):
    """Invoke the real hook with a controlled environment.

    Returns (returncode, stdout+stderr).
    """
    env = dict(os.environ)
    env["CI_PRIMARY_REPOSITORY_PATH"] = str(repo_root)
    env.pop("CI_TAG", None)
    if ci_tag is not None:
        env["CI_TAG"] = ci_tag
    proc = subprocess.run(
        ["bash", str(SCRIPT)],
        capture_output=True, text=True, env=env, timeout=60,
    )
    return proc.returncode, proc.stdout + proc.stderr


class TestTagVersionStamp(unittest.TestCase):
    def setUp(self):
        # Throwaway repo tree holding only what the hook touches.
        self.tmp = Path(tempfile.mkdtemp(prefix="tagstamp-"))
        (self.tmp / "Config").mkdir()
        self.xcconfig = self.tmp / "Config" / "Signing.xcconfig"
        self.xcconfig.write_text(XCCONFIG_TEMPLATE)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def marketing(self) -> str:
        lines = [
            l.strip() for l in self.xcconfig.read_text().splitlines()
            if l.strip().startswith("MARKETING_VERSION")
        ]
        self.assertEqual(len(lines), 1, f"expected exactly one assignment, got {lines}")
        return lines[0].split("=", 1)[1].strip()

    # -- valid tags ----------------------------------------------------

    def test_valid_v_prefixed_tag_stamps(self):
        rc, out = run_script(self.tmp, "v0.0.5")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.marketing(), "0.0.5")

    def test_bare_numeric_tag_stamps(self):
        rc, out = run_script(self.tmp, "1.2.3")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.marketing(), "1.2.3")

    def test_multi_digit_components_stamps(self):
        rc, out = run_script(self.tmp, "v10.20.30")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.marketing(), "10.20.30")

    # -- malformed tags: must FAIL, never silently fall back ------------

    def test_malformed_tags_rejected_without_touching_xcconfig(self):
        for bad in ("release-foo", "v0.1", "v0.1.2.3", "v", "v0.0.x",
                   "0", "0.1", "beta", "v0.0.5-rc1"):
            with self.subTest(tag=bad):
                rc, out = run_script(self.tmp, bad)
                self.assertNotEqual(rc, 0, f"tag {bad!r} must fail the build")
                self.assertEqual(
                    self.marketing(), FALLBACK,
                    f"tag {bad!r} must leave the fallback untouched")

    def test_missing_marketing_line_fails_loudly(self):
        # If the xcconfig ever loses its MARKETING_VERSION line, the stamp
        # must fail rather than "succeed" with no version anywhere.
        self.xcconfig.write_text("DEVELOPMENT_TEAM = M2977H5PM5\n")
        rc, out = run_script(self.tmp, "v1.0.0")
        self.assertNotEqual(rc, 0, out)

    # -- absent tag: fallback preserved ---------------------------------

    def test_unset_tag_keeps_fallback(self):
        rc, out = run_script(self.tmp, None)
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.marketing(), FALLBACK)
        self.assertIn("no CI_TAG", out)

    def test_empty_string_tag_keeps_fallback(self):
        rc, out = run_script(self.tmp, "")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.marketing(), FALLBACK)

    # -- structural invariants that make the stamp effective ------------

    def test_pbxproj_has_no_marketing_version_override(self):
        # A MARKETING_VERSION assignment in the pbxproj would OVERRIDE the
        # xcconfig and silently defeat tag stamping. It must not come back.
        text = PBXPROJ.read_text()
        self.assertNotIn("MARKETING_VERSION", text,
                        "MARKETING_VERSION must live only in Config/Signing.xcconfig")

    def test_xcconfig_is_a_base_configuration(self):
        # The stamp only reaches the build if some XCBuildConfiguration
        # bases on Signing.xcconfig.
        text = PBXPROJ.read_text()
        self.assertIn("baseConfigurationReference", text)
        self.assertIn("Signing.xcconfig", text)

    def test_committed_xcconfig_has_single_marketing_assignment(self):
        lines = [
            l.strip() for l in XCCONFIG.read_text().splitlines()
            if l.strip().startswith("MARKETING_VERSION")
        ]
        self.assertEqual(len(lines), 1, f"expected exactly one assignment, got {lines}")

    def test_hook_is_executable(self):
        self.assertTrue(os.access(SCRIPT, os.X_OK),
                        "ci_pre_xcodebuild.sh must be committed executable")


if __name__ == "__main__":
    unittest.main()
