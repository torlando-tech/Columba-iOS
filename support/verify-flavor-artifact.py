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

Unsigned simulator products are supported only through an explicit verifier
option. Device products must be signed. If an artifact has a _CodeSignature
directory, effective entitlements become mandatory and are read with codesign.
"""

import argparse
from pathlib import Path
import plistlib
import subprocess
import sys
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple


NETWORK_EXTENSION_LOAD = b"/NetworkExtension.framework/"
PYTHON_LOAD = b"/Python.framework/"
MODEL_B_SYMBOLS = (
    b"PacketTunnelProvider",
    b"ProxyRnsBackend",
    b"NEReticulumNode",
    b"TunnelManager",
)
SHIPPING_RNODE_C_ABI_SYMBOLS = (
    b"_columba_rnode_connect",
    b"_columba_rnode_disconnect",
    b"_columba_rnode_state",
    b"_columba_rnode_read",
    b"_columba_rnode_write",
    b"_columba_rnode_set_online",
)
SHIPPING_RNODE_PYTHON_PAYLOADS = (
    "app/rnode/IOSRNodeInterface.py",
    "app/rnode/IOSRNodeDriver.py",
)
NETWORK_EXTENSION_ENTITLEMENT = (
    "com.apple.developer.networking.networkextension"
)
PACKET_TUNNEL_ENTITLEMENT = ["packet-tunnel-provider"]
HOST_BUNDLE_IDENTIFIERS = {
    "shipping": "network.columba.Columba",
    "modelb": "network.columba.Columba",
}
EXTENSION_BUNDLE_IDENTIFIER = "network.columba.Columba.tunnel"
EXTENSION_PRINCIPAL_CLASS = "ColumbaNetworkExtension.PacketTunnelProvider"


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


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _resolve_contained(path: Path, app_root: Path, label: str) -> Path:
    try:
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise VerificationError("{} cannot resolve safely: {}".format(label, error))
    if not _is_within(resolved, app_root):
        raise VerificationError(
            "{} is not contained in the application bundle: {}".format(label, path)
        )
    return resolved


def _audit_bundle_tree(app: Path, app_root: Path) -> None:
    try:
        entries = app.rglob("*")
        for entry in entries:
            _resolve_contained(entry, app_root, "bundle entry or symlink")
    except VerificationError:
        raise
    except (OSError, RuntimeError) as error:
        raise VerificationError("application bundle traversal failed closed: {}".format(error))


def _load_bundle(bundle: Path, expected_type: str, label: str, app_root: Path) -> Dict:
    _resolve_contained(bundle, app_root, label)
    if not bundle.is_dir():
        raise VerificationError("{} does not exist as a directory: {}".format(label, bundle))
    plist_path = bundle / "Info.plist"
    _resolve_contained(plist_path, app_root, "{} Info.plist".format(label))
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


def _bundle_executable(
    bundle: Path, metadata: Dict, label: str, app_root: Path
) -> Path:
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
    _resolve_contained(executable, app_root, "{} executable".format(label))
    if not executable.is_file():
        raise VerificationError("{} executable does not exist: {}".format(label, executable))
    return executable


def _linked_libraries(executable: Path, label: str, run: Callable) -> bytes:
    return _command_output(
        ("otool", "-L", str(executable)),
        "otool for {}".format(label),
        run,
    )


def _bundle_linkage(
    bundle: Path,
    executable: Path,
    label: str,
    app_root: Path,
    run: Callable,
) -> Tuple[bytes, List[Path]]:
    """Return recursive load commands and in-bundle code images.

    Xcode Debug products use a tiny executable that loads a sibling
    ``*.debug.dylib`` containing the application code. Checking only the plist
    executable misses the real framework linkage and symbols.
    """
    queue = [executable]
    images = []
    seen = set()
    outputs = []
    while queue:
        image = queue.pop(0)
        resolved = _resolve_contained(
            image, app_root, "{} code image".format(label)
        )
        if resolved in seen:
            continue
        seen.add(resolved)
        images.append(image)
        output = _linked_libraries(image, label, run)
        outputs.append(output)
        for raw_line in output.splitlines()[1:]:
            stripped = raw_line.strip()
            dependency = stripped.split(None, 1)[0] if stripped else b""
            if (
                not dependency.startswith(b"@rpath/")
                or not dependency.endswith(b".debug.dylib")
            ):
                continue
            try:
                relative = dependency[len(b"@rpath/") :].decode("utf-8")
            except UnicodeDecodeError:
                raise VerificationError(
                    "{} contains a non-UTF-8 @rpath dependency".format(label)
                )
            candidates = (bundle / relative, bundle / "Frameworks" / relative)
            existing = [candidate for candidate in candidates if candidate.exists()]
            if not existing:
                raise VerificationError(
                    "{} references a missing debug code image: {}".format(
                        label, dependency.decode("utf-8")
                    )
                )
            if len(existing) != 1:
                raise VerificationError(
                    "{} has ambiguous locations for debug code image: {}".format(
                        label, dependency.decode("utf-8")
                    )
                )
            candidate = existing[0]
            _resolve_contained(
                candidate, app_root, "{} @rpath image".format(label)
            )
            if not candidate.is_file():
                raise VerificationError(
                    "{} @rpath image is not a file".format(label)
                )
            queue.append(candidate)
    return b"\n".join(outputs), images


def _defined_symbols(executable: Path, label: str, run: Callable) -> bytes:
    return _command_output(
        ("nm", "-jU", str(executable)),
        "nm for {}".format(label),
        run,
    )


def _contains_regular_file(directory: Path, app_root: Path, label: str) -> bool:
    _resolve_contained(directory, app_root, label)
    return directory.is_dir() and any(path.is_file() for path in directory.rglob("*"))


def _verify_entitlements_if_signed(
    bundle: Path,
    flavor: str,
    label: str,
    app_root: Path,
    run: Callable,
    platform_name: Optional[str] = None,
    allow_empty_simulator_entitlements: bool = False,
    allow_unsigned_simulator: bool = False,
) -> None:
    signature = bundle / "_CodeSignature"
    if not signature.exists():
        if platform_name != "iphonesimulator":
            raise VerificationError(
                "unsigned {} artifact is not permitted for {}".format(
                    platform_name or "unknown-platform", label
                )
            )
        if not allow_unsigned_simulator:
            raise VerificationError(
                "unsigned simulator artifact requires the explicit "
                "--allow-unsigned-simulator option for {}".format(label)
            )
        return
    _resolve_contained(signature, app_root, "{} signature".format(label))
    if not signature.is_dir():
        raise VerificationError("{} signature is not a directory".format(label))
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
    if (
        flavor == "modelb"
        and not entitlements
        and allow_empty_simulator_entitlements
        and platform_name == "iphonesimulator"
    ):
        return
    if flavor == "shipping" and NETWORK_EXTENSION_ENTITLEMENT in entitlements:
        raise VerificationError(
            "shipping {} effective entitlements contain the networkextension entitlement".format(
                label
            )
        )
    if flavor == "modelb" and entitlements.get(
        NETWORK_EXTENSION_ENTITLEMENT
    ) != PACKET_TUNNEL_ENTITLEMENT:
        raise VerificationError(
            "Model B {} effective entitlement must equal {!r}".format(
                label, PACKET_TUNNEL_ENTITLEMENT
            )
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


def _verify_shipping(
    app: Path,
    app_root: Path,
    app_metadata: Dict,
    code_images: Sequence[Path],
    libraries: bytes,
    run: Callable,
    allow_unsigned_simulator: bool,
) -> None:
    forbidden = next(iter(_shipping_forbidden_paths(app)), None)
    if forbidden is not None:
        raise VerificationError("shipping artifact contains forbidden path or PlugIns: {}".format(forbidden))
    if NETWORK_EXTENSION_LOAD in libraries:
        raise VerificationError("shipping executable links NetworkExtension.framework")
    symbols = b"\n".join(
        _defined_symbols(image, "shipping app code image", run)
        for image in code_images
    )
    marker = next((name for name in MODEL_B_SYMBOLS if name in symbols), None)
    if marker is not None:
        raise VerificationError(
            "shipping executable contains active Model B symbol {}".format(
                marker.decode("ascii")
            )
        )
    missing_rnode_symbol = next(
        (name for name in SHIPPING_RNODE_C_ABI_SYMBOLS if name not in symbols),
        None,
    )
    if missing_rnode_symbol is not None:
        raise VerificationError(
            "shipping executable is missing Python RNode C ABI symbol {}".format(
                missing_rnode_symbol.decode("ascii")
            )
        )
    if PYTHON_LOAD not in libraries:
        raise VerificationError(
            "shipping application code does not link Python.framework"
        )
    framework = app / "Frameworks/Python.framework"
    if not _contains_regular_file(framework, app_root, "shipping Python.framework"):
        raise VerificationError("shipping Python.framework payload is missing or empty")
    framework_metadata = _load_bundle(
        framework, "FMWK", "shipping Python.framework", app_root
    )
    framework_executable = _bundle_executable(
        framework,
        framework_metadata,
        "shipping Python.framework",
        app_root,
    )
    if framework_executable.stat().st_size == 0:
        raise VerificationError("shipping Python.framework executable is empty")
    stdlib = app / "python/lib"
    if not _contains_regular_file(stdlib, app_root, "shipping python/lib"):
        raise VerificationError("shipping python/lib standard-library payload is missing or empty")
    packages = app / "app_packages"
    if not _contains_regular_file(packages, app_root, "shipping app_packages"):
        raise VerificationError("shipping app_packages wheel payload is missing or empty")
    ble_reticulum = packages / "ble_reticulum/BLEInterface.py"
    _resolve_contained(ble_reticulum, app_root, "shipping ble_reticulum package")
    if not ble_reticulum.is_file() or ble_reticulum.stat().st_size == 0:
        raise VerificationError(
            "shipping app_packages/ble_reticulum runtime is missing or empty"
        )
    for relative in SHIPPING_RNODE_PYTHON_PAYLOADS:
        payload = app / relative
        _resolve_contained(payload, app_root, "shipping Python RNode payload")
        if not payload.is_file() or payload.stat().st_size == 0:
            raise VerificationError(
                "shipping Python RNode payload is missing or empty: {}".format(relative)
            )
    _verify_entitlements_if_signed(
        app,
        "shipping",
        "host",
        app_root,
        run,
        app_metadata.get("DTPlatformName"),
        allow_unsigned_simulator=allow_unsigned_simulator,
    )


def _verify_modelb(
    app: Path,
    app_root: Path,
    app_metadata: Dict,
    libraries: bytes,
    run: Callable,
    allow_empty_simulator_entitlements: bool,
    allow_unsigned_simulator: bool,
) -> None:
    extension = app / "PlugIns/ColumbaNetworkExtension.appex"
    plugins = app / "PlugIns"
    _resolve_contained(plugins, app_root, "Model B PlugIns")
    if not plugins.is_dir():
        raise VerificationError("Model B PlugIns must exist as a directory")
    try:
        plugin_entries = list(plugins.iterdir())
    except OSError as error:
        raise VerificationError("Model B PlugIns cannot be inspected: {}".format(error))
    if len(plugin_entries) != 1 or plugin_entries[0].name != extension.name:
        raise VerificationError(
            "Model B PlugIns root must contain exactly one entry: "
            "ColumbaNetworkExtension.appex"
        )
    _resolve_contained(extension, app_root, "Model B extension")
    extension_metadata = _load_bundle(
        extension, "XPC!", "Model B extension", app_root
    )
    if extension_metadata.get("CFBundleIdentifier") != EXTENSION_BUNDLE_IDENTIFIER:
        raise VerificationError(
            "Model B extension CFBundleIdentifier must be {}".format(
                EXTENSION_BUNDLE_IDENTIFIER
            )
        )
    extension_point = extension_metadata.get("NSExtension")
    if not isinstance(extension_point, dict) or extension_point.get(
        "NSExtensionPointIdentifier"
    ) != "com.apple.networkextension.packet-tunnel":
        raise VerificationError(
            "Model B extension NSExtension metadata is not a packet-tunnel provider"
        )
    if extension_point.get("NSExtensionPrincipalClass") != EXTENSION_PRINCIPAL_CLASS:
        raise VerificationError(
            "Model B extension NSExtension metadata NSExtensionPrincipalClass must be {}".format(
                EXTENSION_PRINCIPAL_CLASS
            )
        )
    extension_executable = _bundle_executable(
        extension, extension_metadata, "Model B extension", app_root
    )
    extension_libraries, _extension_images = _bundle_linkage(
        extension,
        extension_executable,
        "Model B extension",
        app_root,
        run,
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
    host_platform = app_metadata.get("DTPlatformName")
    extension_platform = extension_metadata.get("DTPlatformName")
    if host_platform != extension_platform:
        raise VerificationError(
            "Model B host and extension DTPlatformName values must match"
        )
    allow_empty_for_both = (
        allow_empty_simulator_entitlements
        and host_platform == "iphonesimulator"
        and extension_platform == "iphonesimulator"
    )
    _verify_entitlements_if_signed(
        app,
        "modelb",
        "host",
        app_root,
        run,
        app_metadata.get("DTPlatformName"),
        allow_empty_for_both,
        allow_unsigned_simulator,
    )
    _verify_entitlements_if_signed(
        extension,
        "modelb",
        "extension",
        app_root,
        run,
        extension_metadata.get("DTPlatformName"),
        allow_empty_for_both,
        allow_unsigned_simulator,
    )


def verify_artifact(
    flavor: str,
    app_path,
    run: Callable = _default_run,
    allow_empty_simulator_entitlements: bool = False,
    allow_unsigned_simulator: bool = False,
) -> None:
    """Verify *app_path* as ``shipping`` or ``modelb``; raise on uncertainty."""
    if flavor not in ("shipping", "modelb"):
        raise VerificationError("unsupported flavor: {}".format(flavor))
    app = Path(app_path)
    if app.is_symlink():
        raise VerificationError("top-level application bundle must not be a symlink")
    try:
        app_root = app.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise VerificationError("application bundle cannot resolve safely: {}".format(error))
    if not app_root.is_dir():
        raise VerificationError("application bundle is not a directory: {}".format(app))
    _audit_bundle_tree(app, app_root)
    metadata = _load_bundle(app, "APPL", "{} app".format(flavor), app_root)
    expected_host_identifier = HOST_BUNDLE_IDENTIFIERS[flavor]
    if metadata.get("CFBundleIdentifier") != expected_host_identifier:
        raise VerificationError(
            "{} host CFBundleIdentifier must be {}".format(
                flavor, expected_host_identifier
            )
        )
    platform_name = metadata.get("DTPlatformName")
    if platform_name not in ("iphonesimulator", "iphoneos"):
        raise VerificationError(
            "{} host DTPlatformName must be iphonesimulator or iphoneos".format(
                flavor
            )
        )
    executable = _bundle_executable(
        app, metadata, "{} app".format(flavor), app_root
    )
    libraries, code_images = _bundle_linkage(
        app,
        executable,
        "{} app".format(flavor),
        app_root,
        run,
    )
    if flavor == "shipping":
        _verify_shipping(
            app,
            app_root,
            metadata,
            code_images,
            libraries,
            run,
            allow_unsigned_simulator,
        )
    else:
        _verify_modelb(
            app,
            app_root,
            metadata,
            libraries,
            run,
            allow_empty_simulator_entitlements,
            allow_unsigned_simulator,
        )


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("flavor", choices=("shipping", "modelb"))
    parser.add_argument("app", type=Path)
    parser.add_argument(
        "--allow-empty-simulator-entitlements",
        action="store_true",
        help=(
            "allow an empty ad-hoc entitlement plist only when the built bundle "
            "declares DTPlatformName=iphonesimulator"
        ),
    )
    parser.add_argument(
        "--allow-unsigned-simulator",
        action="store_true",
        help=(
            "allow an unsigned bundle only when it declares "
            "DTPlatformName=iphonesimulator"
        ),
    )
    arguments = parser.parse_args(argv)
    try:
        verify_artifact(
            arguments.flavor,
            arguments.app,
            allow_empty_simulator_entitlements=(
                arguments.allow_empty_simulator_entitlements
            ),
            allow_unsigned_simulator=arguments.allow_unsigned_simulator,
        )
    except VerificationError as error:
        print("artifact verification failed: {}".format(error), file=sys.stderr)
        return 1
    print("{} artifact isolation verified: {}".format(arguments.flavor, arguments.app))
    return 0


if __name__ == "__main__":
    sys.exit(main())
