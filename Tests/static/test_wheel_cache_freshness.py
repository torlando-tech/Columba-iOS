"""Exercise wheel reuse and repair through the shipping build hooks."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
REFS = {"rns": "1" * 40, "lxmf": "2" * 40, "ble-reticulum": "3" * 40}
VERSIONS = {"rns": "1.6.0", "lxmf": "1.3.0", "ble-reticulum": "0.2.3", "pyserial": "3.5"}
PAYLOADS = {
    "rns": "RNS/__init__.py",
    "lxmf": "LXMF/__init__.py",
    "ble-reticulum": "ble_reticulum/BLEInterface.py",
    "pyserial": "serial/__init__.py",
    "cryptography": "cryptography/hazmat/bindings/_rust.abi3.so",
    "cffi": "_cffi_backend.so",
}


def metadata(root, name, version=None):
    return root / f"{name.replace('-', '_')}-{version or VERSIONS[name]}.dist-info"


def package(root, name, revision=None, platform=None, version=None, python_tag=None):
    version = version or VERSIONS[name]
    payload = root / PAYLOADS[name]
    payload.parent.mkdir(parents=True, exist_ok=True)
    payload.write_text(f"PIN = {revision!r}\n")
    info = metadata(root, name, version)
    info.mkdir(exist_ok=True)
    (info / "METADATA").write_text(f"Name: {name}\nVersion: {version}\n")
    if revision is not None:
        (info / "direct_url.json").write_text(json.dumps({"vcs_info": {"commit_id": revision}}))
    if platform is not None:
        (info / "WHEEL").write_text(f"Wheel-Version: 1.0\nTag: {python_tag}-abi3-{platform}\n")


def install_packages(args):
    """Replace only pip's network boundary with deterministic wheel fixtures."""
    if os.environ.get("BLOCK_INSTALL"):
        raise SystemExit("unexpected dependency download")
    destination = Path(args[args.index("--target") + 1])
    destination.mkdir(parents=True, exist_ok=True)
    if "--platform" in args:
        platform = args[args.index("--platform") + 1]
        python_tag = "cp" + args[args.index("--python-version") + 1].replace(".", "")
        for spec in args[args.index("--upgrade") + 1:]:
            name, version = spec.split("==")
            package(destination, name, platform=platform, version=version, python_tag=python_tag)
    else:
        names = {"Reticulum": "rns", "LXMF": "lxmf", "ble-reticulum": "ble-reticulum"}
        for spec in args[args.index("--upgrade") + 1:]:
            if spec.startswith("git+"):
                repository, revision = spec.rsplit("@", 1)
                name = names[repository.rsplit("/", 1)[1].removesuffix(".git")]
                package(destination, name, revision)
            elif spec.startswith("pyserial"):
                package(destination, "pyserial")
            else:
                package(destination, "rns", (Path(spec) / "PIN").read_text())


class WheelCacheFreshnessTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="wheel-cache-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        support = self.root / "support"
        support.mkdir()
        shutil.copy2(ROOT / "support/fetch-wheels.sh", support)
        (support / "fetch-python.sh").write_text("#!/bin/sh\nexit 0\n")
        (support / "fetch-python.sh").chmod(0o755)
        installer = support / "installer.py"
        installer.write_text(
            f"#!{sys.executable}\nimport os, sys\nsys.path.insert(0, {str(ROOT)!r})\n"
            "if sys.argv[1:3] == ['-m', 'pip']:\n"
            "    from Tests.static.test_wheel_cache_freshness import install_packages\n"
            "    install_packages(sys.argv[3:])\n"
            "else:\n"
            "    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])\n"
        )
        installer.chmod(0o755)
        (support / "bootstrap-pip.sh").write_text(
            'PIP_VENV="$POC_ROOT/pip-work"\n'
            'PIP_PYTHON="$POC_ROOT/support/installer.py"\n'
        )
        project = self.root / "Columba.xcodeproj"
        project.mkdir()
        (project / "project.pbxproj").write_text("CURRENT_PROJECT_VERSION = 1;\n")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-q", "--allow-empty", "-m", "Fixture"], check=True)
        self.env = {key: value for key, value in os.environ.items() if key not in ("RETICULUM_LOCAL", "LXMF_LOCAL", "BLE_RETICULUM_LOCAL", "BLOCK_INSTALL")}
        self.env.update(CI_PRIMARY_REPOSITORY_PATH=str(self.root), RETICULUM_REF=REFS["rns"], LXMF_REF=REFS["lxmf"], BLE_RETICULUM_REF=REFS["ble-reticulum"])
        self.platforms = ("iphoneos", "iphonesimulator")
        result = subprocess.run(["bash", str(support / "fetch-wheels.sh")], env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def run_hook(self):
        result = subprocess.run(["bash", str(ROOT / "ci_scripts/ci_post_clone.sh")], env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def assert_pinned(self):
        for suffix in self.platforms:
            directory = self.root / f"wheels-{suffix}"
            for name, revision in REFS.items():
                self.assertEqual((directory / PAYLOADS[name]).read_text(), f"PIN = {revision!r}\n")
                self.assertEqual(json.loads((metadata(directory, name) / "direct_url.json").read_text())["vcs_info"]["commit_id"], revision)

    def test_post_clone_rebuilds_stale_revisions_in_either_platform(self):
        for suffix in self.platforms:
            for name in REFS:
                with self.subTest(platform=suffix, dependency=name):
                    package(self.root / f"wheels-{suffix}", name, "0" * 40)
                    try:
                        self.run_hook()
                        self.assert_pinned()
                    finally:
                        package(self.root / f"wheels-{suffix}", name, REFS[name])

    def test_matching_payloads_are_reused_without_downloads(self):
        self.env["BLOCK_INSTALL"] = "1"
        self.run_hook()
        result = subprocess.run(["bash", str(self.root / "support/fetch-wheels.sh")], env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_pinned()

    def test_missing_or_invalid_revision_metadata_is_rebuilt(self):
        info = metadata(self.root / "wheels-iphoneos", "rns") / "direct_url.json"
        for value in (None, "not json"):
            with self.subTest(metadata=value):
                if value is None:
                    info.unlink()
                else:
                    info.write_text(value)
                self.run_hook()
                self.assert_pinned()

    def test_missing_or_wrong_platform_binary_payload_is_rebuilt(self):
        directory = self.root / "wheels-iphoneos"
        module = directory / PAYLOADS["cryptography"]
        module.unlink()
        self.run_hook()
        self.assertTrue(module.is_file())
        wheel = next(directory.glob("cryptography-*.dist-info/WHEEL"))
        expected = wheel.read_text()
        wheel.write_text(expected.replace("iphoneos", "iphonesimulator"))
        self.run_hook()
        self.assertEqual(wheel.read_text(), expected)

    def test_local_checkout_changes_are_not_hidden_by_cache_reuse(self):
        checkout = self.root / "local-rns"
        checkout.mkdir()
        self.env["RETICULUM_LOCAL"] = str(checkout)
        for revision in ("local-first", "local-second"):
            (checkout / "PIN").write_text(revision)
            self.run_hook()
            for suffix in self.platforms:
                self.assertEqual((self.root / f"wheels-{suffix}" / PAYLOADS["rns"]).read_text(), f"PIN = {revision!r}\n")

    @unittest.skipUnless(shutil.which("rsync"), "Requires rsync, as does the Xcode staging phase")
    def test_xcode_staging_rebuilds_stale_cache_before_copying(self):
        package(self.root / "wheels-iphoneos", "lxmf", "0" * 40)
        project = (ROOT / "Columba.xcodeproj/project.pbxproj").read_text()
        phase = re.search(r'/\* Install Python stdlib & process dylibs \*/ = \{.*?shellScript = ("(?:[^"\\]|\\.)*");', project, re.S)
        script = json.loads(phase.group(1))
        utilities = self.root / "Frameworks/Python.xcframework/build/utils.sh"
        utilities.parent.mkdir(parents=True)
        utilities.write_text("install_python() { :; }\n")
        app = self.root / "App.app"
        self.env.update(PROJECT_DIR=str(self.root), EFFECTIVE_PLATFORM_NAME="-iphoneos", CODESIGNING_FOLDER_PATH=str(app))
        result = subprocess.run(["bash", "-c", script], env=self.env, cwd=self.root, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((app / "app_packages/LXMF/__init__.py").read_text(), f"PIN = {REFS['lxmf']!r}\n")


if __name__ == "__main__":
    unittest.main()
