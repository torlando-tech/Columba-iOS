#!/usr/bin/env python3
"""Synthetic artifact and workflow contracts for Task 13 CI isolation."""

import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "support/verify-flavor-artifact.py"
WORKFLOW = ROOT / ".github/workflows/tests.yml"


def load_checker():
    spec = importlib.util.spec_from_file_location("verify_flavor_artifact", CHECKER)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load artifact checker")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Completed:
    def __init__(self, stdout=b"", stderr=b"", returncode=0):
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode


class ArtifactFixture:
    def __init__(self, root: Path, flavor: str, executable: str = "UnexpectedExecutable"):
        self.app = root / ("Shipping.app" if flavor == "shipping" else "ModelB.app")
        self.app.mkdir()
        self.executable = executable
        self.write_plist(
            self.app / "Info.plist",
            {
                "CFBundleIdentifier": "network.columba.Columba",
                "CFBundleExecutable": executable,
                "CFBundlePackageType": "APPL",
                "DTPlatformName": "iphonesimulator",
            },
        )
        (self.app / executable).write_bytes(
            b"Mach-O debug/source/path/PacketTunnelProvider.swift\0TunnelManager.swift"
        )
        self.outputs = {
            ("otool", str(self.app / executable)): (
                b"binary:\n\t/System/Library/Frameworks/Foundation.framework/Foundation\n"
            ),
            ("nm", str(self.app / executable)): b"_$s7Columba13ShippingGraphV\n",
        }
        if flavor == "shipping":
            framework = self.app / "Frameworks/Python.framework"
            framework.mkdir(parents=True)
            self.write_plist(
                framework / "Info.plist",
                {
                    "CFBundleIdentifier": "org.python.Python",
                    "CFBundleExecutable": "Python",
                    "CFBundlePackageType": "FMWK",
                },
            )
            (framework / "Python").write_bytes(b"python")
            stdlib = self.app / "python/lib/python3.13"
            stdlib.mkdir(parents=True)
            (stdlib / "os.py").write_text("pass\n", encoding="utf-8")
            packages = self.app / "app_packages"
            packages.mkdir()
            (packages / "rns.py").write_text("pass\n", encoding="utf-8")
            self.outputs[("otool", str(self.app / executable))] += (
                b"\t@rpath/Python.framework/Python\n"
            )
        else:
            self.outputs[("otool", str(self.app / executable))] += (
                b"\t/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension\n"
            )
            self.extension = self.app / "PlugIns/ColumbaNetworkExtension.appex"
            self.extension.mkdir(parents=True)
            extension_executable = "ArbitraryTunnelExecutable"
            self.write_plist(
                self.extension / "Info.plist",
                {
                    "CFBundleIdentifier": "network.columba.Columba.tunnel",
                    "CFBundleExecutable": extension_executable,
                    "CFBundlePackageType": "XPC!",
                    "DTPlatformName": "iphonesimulator",
                    "NSExtension": {
                        "NSExtensionPointIdentifier": (
                            "com.apple.networkextension.packet-tunnel"
                        ),
                        "NSExtensionPrincipalClass": (
                            "ColumbaNetworkExtension.PacketTunnelProvider"
                        ),
                    },
                },
            )
            (self.extension / extension_executable).write_bytes(b"Mach-O")
            self.outputs[("otool", str(self.extension / extension_executable))] = (
                b"extension:\n"
                b"\t/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension\n"
            )

    @staticmethod
    def write_plist(path: Path, value) -> None:
        with path.open("wb") as stream:
            plistlib.dump(value, stream)

    def run(self, command, **_kwargs):
        tool = Path(command[0]).name
        binary = command[-1]
        if tool == "codesign":
            return Completed(returncode=1, stderr=b"code object is not signed at all")
        key = (tool, binary)
        if key not in self.outputs:
            return Completed(returncode=127, stderr=b"unexpected tool invocation")
        return Completed(stdout=self.outputs[key])


class ArtifactCheckerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.checker = load_checker()

    def verify(self, fixture: ArtifactFixture, flavor: str) -> None:
        self.checker.verify_artifact(
            flavor,
            fixture.app,
            run=fixture.run,
            allow_unsigned_simulator=True,
        )

    def assert_rejected(self, fixture: ArtifactFixture, flavor: str, message: str) -> None:
        with self.assertRaisesRegex(self.checker.VerificationError, message):
            self.verify(fixture, flavor)

    def test_shipping_passes_with_discovered_executable_and_ignores_debug_strings(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "shipping", "NotColumbaApp")
            self.verify(fixture, "shipping")

    def test_modelb_passes_with_exact_extension_and_discovered_executables(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "modelb", "NotModelBApp")
            self.verify(fixture, "modelb")

    def test_rejects_wrong_host_bundle_identifier_for_each_flavor(self):
        for flavor in ("shipping", "modelb"):
            with self.subTest(flavor=flavor), tempfile.TemporaryDirectory() as directory:
                fixture = ArtifactFixture(Path(directory), flavor)
                plist_path = fixture.app / "Info.plist"
                with plist_path.open("rb") as stream:
                    metadata = plistlib.load(stream)
                metadata["CFBundleIdentifier"] = "com.attacker.WrongHost"
                fixture.write_plist(plist_path, metadata)
                self.assert_rejected(fixture, flavor, "host CFBundleIdentifier")

    def test_unsigned_device_artifacts_fail_closed_for_each_flavor(self):
        for flavor in ("shipping", "modelb"):
            with self.subTest(flavor=flavor), tempfile.TemporaryDirectory() as directory:
                fixture = ArtifactFixture(Path(directory), flavor)
                plist_paths = [fixture.app / "Info.plist"]
                if flavor == "modelb":
                    plist_paths.append(fixture.extension / "Info.plist")
                for plist_path in plist_paths:
                    with plist_path.open("rb") as stream:
                        metadata = plistlib.load(stream)
                    metadata["DTPlatformName"] = "iphoneos"
                    fixture.write_plist(plist_path, metadata)
                self.assert_rejected(fixture, flavor, "unsigned.*iphoneos|signature")

    def test_unsigned_simulator_requires_explicit_exception(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "shipping")
            with self.assertRaisesRegex(
                self.checker.VerificationError,
                "unsigned.*simulator.*explicit",
            ):
                self.checker.verify_artifact(
                    "shipping",
                    fixture.app,
                    run=fixture.run,
                )
            self.verify(fixture, "shipping")

    def test_debug_dylib_products_are_inspected_as_application_code(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "shipping")
            executable = fixture.app / fixture.executable
            debug_image = fixture.app / "Shipping.debug.dylib"
            debug_image.write_bytes(b"Mach-O")
            fixture.outputs[("otool", str(executable))] = (
                b"stub:\n\t@rpath/Shipping.debug.dylib\n"
            )
            fixture.outputs[("otool", str(debug_image))] = (
                b"debug:\n\t@rpath/Python.framework/Python\n"
            )
            fixture.outputs[("nm", str(debug_image))] = b"_$s7Columba13ShippingGraphV\n"
            self.verify(fixture, "shipping")
            fixture.outputs[("nm", str(debug_image))] += (
                b"_$s7Columba19PacketTunnelProviderC\n"
            )
            self.assert_rejected(fixture, "shipping", "Model B symbol")

        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "modelb")
            host_executable = fixture.app / fixture.executable
            host_debug = fixture.app / "ModelB.debug.dylib"
            host_debug.write_bytes(b"Mach-O")
            fixture.outputs[("otool", str(host_executable))] = (
                b"stub:\n\t@rpath/ModelB.debug.dylib\n"
            )
            fixture.outputs[("otool", str(host_debug))] = (
                b"debug:\n"
                b"\t/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension\n"
            )
            extension_executable = next(
                path
                for path in fixture.extension.iterdir()
                if path.name not in ("Info.plist",)
            )
            extension_debug = fixture.extension / "Extension.debug.dylib"
            extension_debug.write_bytes(b"Mach-O")
            fixture.outputs[("otool", str(extension_executable))] = (
                b"stub:\n\t@rpath/Extension.debug.dylib\n"
            )
            fixture.outputs[("otool", str(extension_debug))] = (
                b"debug:\n"
                b"\t/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension\n"
            )
            self.verify(fixture, "modelb")

    def test_debug_dylib_resolution_rejects_missing_or_ambiguous_images(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "shipping")
            executable = fixture.app / fixture.executable
            fixture.outputs[("otool", str(executable))] = (
                b"stub:\n\t@rpath/Missing.debug.dylib\n"
            )
            self.assert_rejected(fixture, "shipping", "missing debug code image")

        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "shipping")
            executable = fixture.app / fixture.executable
            fixture.outputs[("otool", str(executable))] = (
                b"stub:\n\t@rpath/Ambiguous.debug.dylib\n"
            )
            root_image = fixture.app / "Ambiguous.debug.dylib"
            framework_image = fixture.app / "Frameworks/Ambiguous.debug.dylib"
            root_image.write_bytes(b"clean")
            framework_image.write_bytes(b"PacketTunnelProvider")
            self.assert_rejected(fixture, "shipping", "ambiguous locations")

    def test_shipping_rejects_plugins_even_without_an_appex(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "shipping")
            (fixture.app / "PlugIns").mkdir()
            self.assert_rejected(fixture, "shipping", "PlugIns")

    def test_shipping_rejects_extension_and_forbidden_names(self):
        mutations = (
            "PlugIns/ColumbaNetworkExtension.appex",
            "Resources/PacketTunnel-notes.txt",
        )
        for relative in mutations:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as directory:
                fixture = ArtifactFixture(Path(directory), "shipping")
                path = fixture.app / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.mkdir() if path.suffix == ".appex" else path.write_text("leak")
                self.assert_rejected(fixture, "shipping", "forbidden|PlugIns")

    def test_shipping_rejects_networkextension_linkage_and_active_symbols(self):
        for output_key, leak in (
            ("otool", b"/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension\n"),
            ("nm", b"_$s7Columba19PacketTunnelProviderC\n"),
        ):
            with self.subTest(tool=output_key), tempfile.TemporaryDirectory() as directory:
                fixture = ArtifactFixture(Path(directory), "shipping")
                key = (output_key, str(fixture.app / fixture.executable))
                fixture.outputs[key] += leak
                self.assert_rejected(fixture, "shipping", "NetworkExtension|Model B symbol")

    def test_shipping_rejects_each_missing_python_payload(self):
        relative_paths = (
            "Frameworks/Python.framework",
            "python/lib",
            "app_packages",
        )
        for relative in relative_paths:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as directory:
                fixture = ArtifactFixture(Path(directory), "shipping")
                path = fixture.app / relative
                if path.is_dir():
                    for child in sorted(path.rglob("*"), reverse=True):
                        child.unlink() if child.is_file() else child.rmdir()
                    path.rmdir()
                self.assert_rejected(fixture, "shipping", "Python|python|app_packages")

    def test_shipping_rejects_malformed_or_empty_python_framework(self):
        mutations = ("missing-plist", "wrong-package-type", "empty-executable")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                fixture = ArtifactFixture(Path(directory), "shipping")
                framework = fixture.app / "Frameworks/Python.framework"
                if mutation == "missing-plist":
                    (framework / "Info.plist").unlink()
                elif mutation == "wrong-package-type":
                    with (framework / "Info.plist").open("rb") as stream:
                        metadata = plistlib.load(stream)
                    metadata["CFBundlePackageType"] = "BNDL"
                    fixture.write_plist(framework / "Info.plist", metadata)
                else:
                    (framework / "Python").write_bytes(b"")
                self.assert_rejected(
                    fixture,
                    "shipping",
                    "Python.framework.*Info.plist|CFBundlePackageType|executable is empty",
                )

    def test_modelb_rejects_missing_extension_and_wrong_package_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "modelb")
            fixture.extension.rename(fixture.app / "PlugIns/Wrong.appex")
            self.assert_rejected(fixture, "modelb", "ColumbaNetworkExtension.appex")

        for plist_path in ("Info.plist", "PlugIns/ColumbaNetworkExtension.appex/Info.plist"):
            with self.subTest(plist=plist_path), tempfile.TemporaryDirectory() as directory:
                fixture = ArtifactFixture(Path(directory), "modelb")
                path = fixture.app / plist_path
                with path.open("rb") as stream:
                    metadata = plistlib.load(stream)
                metadata["CFBundlePackageType"] = "BNDL"
                fixture.write_plist(path, metadata)
                self.assert_rejected(fixture, "modelb", "CFBundlePackageType")

    def test_modelb_rejects_extra_extension_or_incomplete_extension_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "modelb")
            (fixture.app / "PlugIns/Unexpected.appex").mkdir()
            self.assert_rejected(fixture, "modelb", "exactly one")

        for key in ("NSExtensionPointIdentifier", "NSExtensionPrincipalClass"):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                fixture = ArtifactFixture(Path(directory), "modelb")
                path = fixture.extension / "Info.plist"
                with path.open("rb") as stream:
                    metadata = plistlib.load(stream)
                del metadata["NSExtension"][key]
                fixture.write_plist(path, metadata)
                self.assert_rejected(fixture, "modelb", "NSExtension metadata")

    def test_modelb_rejects_wrong_extension_identity_or_principal(self):
        mutations = (
            ("CFBundleIdentifier", "network.columba.attacker.tunnel", "CFBundleIdentifier"),
            (
                "NSExtensionPrincipalClass",
                "Attacker.PacketTunnelProvider",
                "NSExtensionPrincipalClass",
            ),
        )
        for key, value, diagnostic in mutations:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                fixture = ArtifactFixture(Path(directory), "modelb")
                path = fixture.extension / "Info.plist"
                with path.open("rb") as stream:
                    metadata = plistlib.load(stream)
                if key == "CFBundleIdentifier":
                    metadata[key] = value
                else:
                    metadata["NSExtension"][key] = value
                fixture.write_plist(path, metadata)
                self.assert_rejected(fixture, "modelb", diagnostic)

    def test_modelb_plugins_root_rejects_every_extra_entry_type(self):
        mutations = ("unexpected.txt", "UnexpectedDirectory")
        for name in mutations:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                fixture = ArtifactFixture(Path(directory), "modelb")
                extra = fixture.app / "PlugIns" / name
                if "." in name:
                    extra.write_text("unexpected", encoding="utf-8")
                else:
                    extra.mkdir()
                self.assert_rejected(fixture, "modelb", "PlugIns.*exactly one entry")

    def test_modelb_rejects_python_packaging_leaks(self):
        leaks = (
            "Frameworks/Python.framework/Python",
            "Frameworks/Python.xcframework/Info.plist",
            "python/lib/os.py",
            "app_packages/rns.py",
            "Resources/site-packages/pkg.py",
            "Resources/runtime.whl",
            "Headers/Columba-Bridging-Header.h",
        )
        for relative in leaks:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as directory:
                fixture = ArtifactFixture(Path(directory), "modelb")
                path = fixture.app / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("leak", encoding="utf-8")
                self.assert_rejected(fixture, "modelb", "Python packaging")

    def test_modelb_requires_networkextension_linkage_in_host_and_extension(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "modelb")
            app_key = ("otool", str(fixture.app / fixture.executable))
            fixture.outputs[app_key] = b"Foundation.framework/Foundation\n"
            self.assert_rejected(fixture, "modelb", "host.*NetworkExtension")

        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "modelb")
            extension_executable = fixture.extension / "ArbitraryTunnelExecutable"
            fixture.outputs[("otool", str(extension_executable))] = b"Foundation\n"
            self.assert_rejected(fixture, "modelb", "extension.*NetworkExtension")

    def test_modelb_rejects_python_framework_linkage_without_an_embedded_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "modelb")
            key = ("otool", str(fixture.app / fixture.executable))
            fixture.outputs[key] += b"\t@rpath/Python.framework/Python\n"
            self.assert_rejected(fixture, "modelb", "links forbidden Python")

    def test_fails_closed_for_missing_malformed_plist_or_executable(self):
        mutations = ("missing-plist", "malformed-plist", "missing-executable")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                fixture = ArtifactFixture(Path(directory), "shipping")
                if mutation == "missing-plist":
                    (fixture.app / "Info.plist").unlink()
                elif mutation == "malformed-plist":
                    (fixture.app / "Info.plist").write_bytes(b"not a plist")
                else:
                    (fixture.app / fixture.executable).unlink()
                self.assert_rejected(fixture, "shipping", "Info.plist|executable")

    def test_fails_closed_when_otool_nm_or_codesign_fails(self):
        for tool in ("otool", "nm"):
            with self.subTest(tool=tool), tempfile.TemporaryDirectory() as directory:
                fixture = ArtifactFixture(Path(directory), "shipping")
                original_run = fixture.run

                def failed_run(command, _tool=tool, **kwargs):
                    if Path(command[0]).name == _tool:
                        return Completed(returncode=2, stderr=b"tool failed")
                    return original_run(command, **kwargs)

                fixture.run = failed_run
                self.assert_rejected(fixture, "shipping", tool)

        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "shipping")
            (fixture.app / "_CodeSignature").mkdir()
            self.assert_rejected(fixture, "shipping", "codesign")

    def test_signed_entitlements_are_checked_but_unsigned_artifacts_are_supported(self):
        cases = (
            ("shipping", {}, True),
            ("shipping", {"com.apple.developer.networking.networkextension": ["packet-tunnel-provider"]}, False),
            ("modelb", {"com.apple.developer.networking.networkextension": ["packet-tunnel-provider"]}, True),
            ("modelb", {}, False),
            ("modelb", {"com.apple.developer.networking.networkextension": ["dns-proxy"]}, False),
            (
                "modelb",
                {
                    "com.apple.developer.networking.networkextension": [
                        "packet-tunnel-provider",
                        "dns-proxy",
                    ]
                },
                False,
            ),
            (
                "modelb",
                {
                    "com.apple.developer.networking.networkextension": [
                        "packet-tunnel-provider",
                        "packet-tunnel-provider",
                    ]
                },
                False,
            ),
        )
        for flavor, entitlements, passes in cases:
            with self.subTest(flavor=flavor, entitlements=entitlements), tempfile.TemporaryDirectory() as directory:
                fixture = ArtifactFixture(Path(directory), flavor)
                signed_paths = [fixture.app]
                if flavor == "modelb":
                    signed_paths.append(fixture.extension)
                for path in signed_paths:
                    (path / "_CodeSignature").mkdir()
                payload = plistlib.dumps(entitlements)
                base_run = fixture.run

                def signed_run(command, **kwargs):
                    if Path(command[0]).name == "codesign":
                        return Completed(stdout=payload)
                    return base_run(command, **kwargs)

                fixture.run = signed_run
                if passes:
                    self.verify(fixture, flavor)
                else:
                    self.assert_rejected(fixture, flavor, "entitlement")

    def test_modelb_entitlement_diagnostic_distinguishes_host_and_extension(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "modelb")
            for path in (fixture.app, fixture.extension):
                (path / "_CodeSignature").mkdir()
            valid = plistlib.dumps(
                {"com.apple.developer.networking.networkextension": ["packet-tunnel-provider"]}
            )
            invalid = plistlib.dumps(
                {"com.apple.developer.networking.networkextension": ["dns-proxy"]}
            )
            base_run = fixture.run

            def host_invalid_run(command, **kwargs):
                if Path(command[0]).name == "codesign":
                    return Completed(stdout=invalid if Path(command[-1]) == fixture.app else valid)
                return base_run(command, **kwargs)

            fixture.run = host_invalid_run
            self.assert_rejected(fixture, "modelb", "Model B host effective entitlement")

            def extension_invalid_run(command, **kwargs):
                if Path(command[0]).name == "codesign":
                    return Completed(stdout=valid if Path(command[-1]) == fixture.app else invalid)
                return base_run(command, **kwargs)

            fixture.run = extension_invalid_run
            self.assert_rejected(fixture, "modelb", "Model B extension effective entitlement")

    def test_empty_adhoc_entitlements_require_explicit_simulator_exception(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "modelb")
            for path in (fixture.app, fixture.extension):
                (path / "_CodeSignature").mkdir()
            payload = plistlib.dumps({})
            base_run = fixture.run

            def empty_entitlements_run(command, **kwargs):
                if Path(command[0]).name == "codesign":
                    return Completed(stdout=payload)
                return base_run(command, **kwargs)

            fixture.run = empty_entitlements_run
            self.assert_rejected(fixture, "modelb", "entitlement")
            self.checker.verify_artifact(
                "modelb",
                fixture.app,
                run=fixture.run,
                allow_empty_simulator_entitlements=True,
            )

            with (fixture.extension / "Info.plist").open("rb") as stream:
                metadata = plistlib.load(stream)
            metadata["DTPlatformName"] = "iphoneos"
            fixture.write_plist(fixture.extension / "Info.plist", metadata)
            with self.assertRaisesRegex(
                self.checker.VerificationError,
                "DTPlatformName values must match",
            ):
                self.checker.verify_artifact(
                    "modelb",
                    fixture.app,
                    run=fixture.run,
                    allow_empty_simulator_entitlements=True,
                )

    def test_rejects_out_of_bundle_and_dangling_symlinks_before_tool_access(self):
        mutations = ("extension", "app-executable", "python-framework", "python-payload", "dangling")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                flavor = "modelb" if mutation in ("extension", "dangling") else "shipping"
                fixture = ArtifactFixture(root, flavor)
                outside = root / "outside"
                if mutation == "extension":
                    fixture.extension.rename(outside)
                    fixture.extension.symlink_to(outside, target_is_directory=True)
                elif mutation == "app-executable":
                    executable = fixture.app / fixture.executable
                    executable.rename(outside)
                    executable.symlink_to(outside)
                elif mutation == "python-framework":
                    framework = fixture.app / "Frameworks/Python.framework"
                    framework.rename(outside)
                    framework.symlink_to(outside, target_is_directory=True)
                elif mutation == "python-payload":
                    payload = fixture.app / "app_packages"
                    payload.rename(outside)
                    payload.symlink_to(outside, target_is_directory=True)
                else:
                    (fixture.app / "Resources").mkdir()
                    (fixture.app / "Resources/dangling").symlink_to(root / "missing")
                self.assert_rejected(fixture, flavor, "symlink|contained|resolve")

    def test_rejects_top_level_app_symlink_but_allows_safe_internal_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = ArtifactFixture(root, "shipping")
            real_app = root / "Real.app"
            fixture.app.rename(real_app)
            fixture.app.symlink_to(real_app, target_is_directory=True)
            self.assert_rejected(fixture, "shipping", "top-level.*symlink")

        with tempfile.TemporaryDirectory() as directory:
            fixture = ArtifactFixture(Path(directory), "shipping")
            resources = fixture.app / "Resources"
            resources.mkdir()
            (resources / "target.txt").write_text("safe", encoding="utf-8")
            (resources / "internal-link").symlink_to(resources / "target.txt")
            self.verify(fixture, "shipping")

    def test_cli_rejects_unknown_flavor(self):
        result = subprocess.run(
            ["python3", str(CHECKER), "unknown", "/tmp/no.app"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)


class WorkflowContractTests(unittest.TestCase):
    def test_workflow_uses_explicit_flavor_schemes_and_deterministic_artifacts(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("Columba-Swift", workflow)
        self.assertGreaterEqual(workflow.count("-scheme Columba"), 3)
        self.assertGreaterEqual(workflow.count("-scheme Columba-ModelB"), 2)
        self.assertIn('-derivedDataPath "$PWD/DerivedData-Python"', workflow)
        self.assertIn('-derivedDataPath "$PWD/DerivedData-ModelB"', workflow)
        self.assertIn(
            'SHIPPING_APP="$PWD/DerivedData-Python/Build/Products/Debug-iphonesimulator/ColumbaApp.app"',
            workflow,
        )
        self.assertIn(
            'MODELB_APP="$PWD/DerivedData-ModelB/Build/Products/Debug-iphonesimulator/ColumbaModelBApp.app"',
            workflow,
        )
        self.assertIn('verify-flavor-artifact.py shipping "$SHIPPING_APP"', workflow)
        self.assertIn('modelb "$MODELB_APP" --allow-empty-simulator-entitlements', workflow)

    def test_workflow_keeps_shipping_tests_and_coverage_without_modelb_tests(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("-only-testing:ColumbaAppTests", workflow)
        self.assertNotIn("-only-testing:ColumbaModelBAppTests", workflow)
        self.assertIn("-enableCodeCoverage YES", workflow)
        self.assertIn("-resultBundlePath TestResults.xcresult", workflow)
        self.assertIn("rm -rf TestResults.xcresult", workflow)

    def test_every_shell_block_is_fail_fast_and_builds_use_adhoc_signing(self):
        lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            if line.strip() == "run: |":
                self.assertEqual(lines[index + 1].strip(), "set -euo pipefail")
        workflow = WORKFLOW.read_text(encoding="utf-8")
        signing = (
            "CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- "
            'CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" '
            'PROVISIONING_PROFILE_SPECIFIER=""'
        )
        self.assertEqual(workflow.count(signing), 3)
        self.assertIn("test_host_entitlements_contract", workflow)
        self.assertIn("test_ci_artifact_isolation", workflow)
        self.assertIn("--allow-empty-simulator-entitlements", workflow)
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", workflow)


if __name__ == "__main__":
    unittest.main()
