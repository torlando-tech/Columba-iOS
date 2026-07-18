#!/usr/bin/env python3
"""Verify reciprocal runtime isolation in a built Columba application.

The shipping binary's Model B marker check inspects exported/defined Mach-O
symbols with ``nm`` rather than broad binary strings. Debug Mach-O files retain
source paths and string literals, so scanning every byte for Swift type names
would produce false failures without proving that the declarations are linked.
The checker combines this symbol check with product layout and framework load
commands; existing source-membership static contracts provide the source-graph
proof. Model B's positive graph proof is its exact embedded extension plus
NetworkExtension load commands in both host and extension.

Unsigned simulator products are supported. If an artifact has a _CodeSignature
directory, effective entitlements become mandatory and are read with codesign.
"""

import argparse
from pathlib import Path
import plistlib
import subprocess
import sys
from typing import Callable, Dict, Iterable, Optional, Sequence


NETWORK_EXTENSION_LOAD = b"/NetworkExtension.framework/"
PYTHON_LOAD = b"/Python.framework/"
MODEL_B_SYMBOLS = (
    b"PacketTunnelProvider",
    b"ProxyRnsBackend",
    b"NEReticulumNode",
    b"TunnelManager",
)
NETWORK_EXTENSION_ENTITLEMENT = (
    "com.apple.developer.networking.networkextension"
)


class VerificationError(RuntimeError):
    """An artifact violates or cannot prove the requested flavor contract."""


def _default_run(command: Sequence[str], **kwargs):
    return subprocess.run(command, **kwargs)


def _command_output(
    command: Sequence[str],
    description: str,
    run: Callable = _default_run,
) -> bytes:
    try:
        result = run(
            list(command),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise VerificationError(
            "{} tool invocation failed: {}".format(description, error)
        )
    if result.returncode != 0:
        # Do not relay tool stderr. In particular, codesign diagnostics can
        # include signing identities, which CI does not need to disclose.
        raise VerificationError(
            "{} tool failed with status {}".format(description, result.returncode)
        )
    output = result.stdout
    if isinstance(output, str):
        return output.encode("utf-8", errors="replace")
    return output


def _load_bundle(bundle: Path, expected_type: str, label: str) -> Dict:
    if not bundle.is_dir():
        raise VerificationError("{} does not exist as a directory: {}".format(label, bundle))
    plist_path = bundle / "Info.plist"
    try:
        with plist_path.open("rb") as stream:
            metadata = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise VerificationError("{} Info.plist is missing or malformed: {}".format(label, error))
    if not isinstance(metadata, dict):
        raise VerificationError("{} Info.plist root is not a dictionary".format(label))
    if metadata.get("CFBundlePackageType") != expected_type:
        raise VerificationError(
            "{} CFBundlePackageType must be {}, found {!r}".format(
                label, expected_type, metadata.get("CFBundlePackageType")
            )
        )
    identifier = metadata.get("CFBundleIdentifier")
    if not isinstance(identifier, str) or not identifier.strip():
        raise VerificationError("{} CFBundleIdentifier is missing".format(label))
    return metadata


def _bundle_executable(bundle: Path, metadata: Dict, label: str) -> Path:
    name = metadata.get("CFBundleExecutable")
    if (
        not isinstance(name, str)
        or not name
        or Path(name).name != name
        or name in (".", "..")
    ):
        raise VerificationError(
            "{} CFBundleExecutable is missing or unsafe".format(label)
        )
    executable = bundle / name
    if not executable.is_file():
        raise VerificationError("{} executable does not exist: {}".format(label, executable))
    return executable


def _linked_libraries(executable: Path, label: str, run: Callable) -> bytes:
    return _command_output(
        ("otool", "-L", str(executable)),
        "otool for {}".format(label),
        run,
    )


def _defined_symbols(executable: Path, label: str, run: Callable) -> bytes:
    return _command_output(
        ("nm", "-jU", str(executable)),
        "nm for {}".format(label),
        run,
    )


def _contains_regular_file(directory: Path) -> bool:
    return directory.is_dir() and any(path.is_file() for path in directory.rglob("*"))


def _verify_entitlements_if_signed(
    bundle: Path, flavor: str, label: str, run: Callable
) -> None:
    if not (bundle / "_CodeSignature").is_dir():
        return
    payload = _command_output(
        ("codesign", "-d", "--entitlements", ":-", str(bundle)),
        "codesign entitlements for {}".format(label),
        run,
    )
    try:
        entitlements = plistlib.loads(payload)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise VerificationError(
            "codesign returned malformed entitlements for {}: {}".format(label, error)
        )
    if not isinstance(entitlements, dict):
        raise VerificationError("effective entitlements for {} are not a dictionary".format(label))
    network_extension = entitlements.get(NETWORK_EXTENSION_ENTITLEMENT)
    if flavor == "shipping" and network_extension is not None:
        raise VerificationError(
            "shipping effective entitlements contain the networkextension entitlement"
        )
    if flavor == "modelb" and not network_extension:
        raise VerificationError(
            "Model B {} effective entitlements lack networkextension".format(label)
        )


def _shipping_forbidden_paths(app: Path) -> Iterable[Path]:
    for path in app.rglob("*"):
        relative_parts = path.relative_to(app).parts
        lowered = path.name.casefold()
        if (
            "plugins" in (part.casefold() for part in relative_parts)
            or path.suffix.casefold() == ".appex"
            or "networkextension" in lowered
            or "packettunnel" in lowered
        ):
            yield path


def _is_python_packaging_path(path: Path, app: Path) -> bool:
    parts = [part.casefold() for part in path.relative_to(app).parts]
    name = path.name.casefold()
    exact_components = {
        "python.framework",
        "python.xcframework",
        "python",
        "app_packages",
        "site-packages",
        "stdlib",
    }
    return bool(
        exact_components.intersection(parts)
        or any(part.startswith("python") for part in parts)
        or name.endswith(".whl")
        or "bridging-header" in name
    )


def _verify_shipping(app: Path, executable: Path, libraries: bytes, run: Callable) -> None:
    forbidden = next(iter(_shipping_forbidden_paths(app)), None)
    if forbidden is not None:
        raise VerificationError("shipping artifact contains forbidden path or PlugIns: {}".format(forbidden))
    if NETWORK_EXTENSION_LOAD in libraries:
        raise VerificationError("shipping executable links NetworkExtension.framework")
    symbols = _defined_symbols(executable, "shipping app", run)
    marker = next((name for name in MODEL_B_SYMBOLS if name in symbols), None)
    if marker is not None:
        raise VerificationError(
            "shipping executable contains active Model B symbol {}".format(
                marker.decode("ascii")
            )
        )
    if PYTHON_LOAD not in libraries:
        raise VerificationError("shipping executable does not link Python.framework")
    framework = app / "Frameworks/Python.framework"
    if not _contains_regular_file(framework):
        raise VerificationError("shipping Python.framework payload is missing or empty")
    stdlib = app / "python/lib"
    if not _contains_regular_file(stdlib):
        raise VerificationError("shipping python/lib standard-library payload is missing or empty")
    packages = app / "app_packages"
    if not _contains_regular_file(packages):
        raise VerificationError("shipping app_packages wheel payload is missing or empty")
    _verify_entitlements_if_signed(app, "shipping", "app", run)


def _verify_modelb(app: Path, libraries: bytes, run: Callable) -> None:
    extension = app / "PlugIns/ColumbaNetworkExtension.appex"
    plugins = app / "PlugIns"
    embedded_extensions = (
        sorted(path for path in plugins.rglob("*.appex"))
        if plugins.is_dir()
        else []
    )
    if embedded_extensions != [extension]:
        raise VerificationError(
            "Model B PlugIns must contain exactly one ColumbaNetworkExtension.appex"
        )
    extension_metadata = _load_bundle(extension, "XPC!", "Model B extension")
    extension_point = extension_metadata.get("NSExtension")
    if not isinstance(extension_point, dict) or extension_point.get(
        "NSExtensionPointIdentifier"
    ) != "com.apple.networkextension.packet-tunnel" or not isinstance(
        extension_point.get("NSExtensionPrincipalClass"), str
    ) or not extension_point["NSExtensionPrincipalClass"].strip():
        raise VerificationError(
            "Model B extension NSExtension metadata is not a packet-tunnel provider"
        )
    extension_executable = _bundle_executable(
        extension, extension_metadata, "Model B extension"
    )
    extension_libraries = _linked_libraries(
        extension_executable, "Model B extension", run
    )
    if NETWORK_EXTENSION_LOAD not in libraries:
        raise VerificationError("Model B host does not link NetworkExtension.framework")
    if NETWORK_EXTENSION_LOAD not in extension_libraries:
        raise VerificationError("Model B extension does not link NetworkExtension.framework")
    if PYTHON_LOAD in libraries or PYTHON_LOAD in extension_libraries:
        raise VerificationError("Model B executable links forbidden Python.framework")
    leaked = next(
        (path for path in app.rglob("*") if _is_python_packaging_path(path, app)),
        None,
    )
    if leaked is not None:
        raise VerificationError("Model B artifact contains Python packaging output: {}".format(leaked))
    _verify_entitlements_if_signed(app, "modelb", "app", run)
    _verify_entitlements_if_signed(extension, "modelb", "extension", run)


def verify_artifact(flavor: str, app_path, run: Callable = _default_run) -> None:
    """Verify *app_path* as ``shipping`` or ``modelb``; raise on uncertainty."""
    if flavor not in ("shipping", "modelb"):
        raise VerificationError("unsupported flavor: {}".format(flavor))
    app = Path(app_path)
    metadata = _load_bundle(app, "APPL", "{} app".format(flavor))
    executable = _bundle_executable(app, metadata, "{} app".format(flavor))
    libraries = _linked_libraries(executable, "{} app".format(flavor), run)
    if flavor == "shipping":
        _verify_shipping(app, executable, libraries, run)
    else:
        _verify_modelb(app, libraries, run)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("flavor", choices=("shipping", "modelb"))
    parser.add_argument("app", type=Path)
    arguments = parser.parse_args(argv)
    try:
        verify_artifact(arguments.flavor, arguments.app)
    except VerificationError as error:
        print("artifact verification failed: {}".format(error), file=sys.stderr)
        return 1
    print("{} artifact isolation verified: {}".format(arguments.flavor, arguments.app))
    return 0


if __name__ == "__main__":
    sys.exit(main())
