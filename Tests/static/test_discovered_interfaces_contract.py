import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RNS_BRIDGE = ROOT / "app/rns_bridge.py"
PYTHON_BRIDGE = ROOT / "Sources/PythonBridge/PythonBridge.swift"
PYTHON_BACKEND = ROOT / "Sources/RNSBackendPy/PythonRNSBackend.swift"
DISCOVERED_MODEL = ROOT / "Sources/RNSAPI/Models/DiscoveredInterface.swift"
DISCOVERED_FORMATTING = ROOT / "Sources/RNSAPI/DiscoveredInterfaceFormatting.swift"
CONFIG_WRITER = ROOT / "Sources/ColumbaApp/Services/PythonConfigWriter.swift"
SETTINGS_REPO = ROOT / "Sources/ColumbaApp/Services/SettingsRepository.swift"
APP_SERVICES = ROOT / "Sources/ColumbaApp/Services/AppServices.swift"
ONE_SHOT_PROVIDER = ROOT / "Sources/ColumbaApp/Services/OneShotLocationProvider.swift"
DISCOVERY_VM = ROOT / "Sources/ColumbaApp/ViewModels/DiscoveredInterfacesViewModel.swift"
DISCOVERY_SCREEN = ROOT / "Sources/ColumbaApp/Views/Settings/DiscoveredInterfacesScreen.swift"
INTERFACE_MGMT_SCREEN = ROOT / "Sources/ColumbaApp/Views/Settings/InterfaceManagementScreen.swift"
PBXPROJ = ROOT / "Columba.xcodeproj/project.pbxproj"
LOCALIZATIONS = ROOT / "Sources/ColumbaApp/Resources/Localizable.xcstrings"


def strip_comments(source: str) -> str:
    # Strip // comments so the "absent symbol" assertions check the code,
    # not prose (comments may name a removed API while documenting its
    # removal).
    return "\n".join(line.split("//", 1)[0] for line in source.splitlines())


class DiscoveredInterfacesContractTests(unittest.TestCase):
    def test_rns_bridge_exposes_discovery_json(self) -> None:
        self.assertIn(
            "def discovery_json",
            RNS_BRIDGE.read_text(encoding="utf-8"),
            "app/rns_bridge.py must expose discovery_json() for the Swift bridge",
        )

    def test_python_bridge_forwards_discovery_snapshot(self) -> None:
        source = PYTHON_BRIDGE.read_text(encoding="utf-8")
        self.assertIn("func discovery()", source, "PythonBridge must expose discovery()")
        self.assertIn("discovery_json", source, "PythonBridge.discovery() must call discovery_json")
        self.assertIn(
            "DiscoverySnapshot",
            source,
            "PythonBridge.discovery() must return the RNSAPI DiscoverySnapshot",
        )

    def test_python_backend_implements_discovery(self) -> None:
        self.assertIn(
            "func discovery()",
            PYTHON_BACKEND.read_text(encoding="utf-8"),
            "PythonRNSBackend must implement the backend discovery() seam",
        )

    def test_discovered_interface_model_shape(self) -> None:
        self.assertTrue(DISCOVERED_MODEL.is_file(), "RNSAPI/Models/DiscoveredInterface.swift must exist")
        source = DISCOVERED_MODEL.read_text(encoding="utf-8")
        for symbol in (
            "struct DiscoveredInterface",
            "struct DiscoverySnapshot",
            "isTcpInterface",
            "isRadioInterface",
        ):
            self.assertIn(symbol, source, f"DiscoveredInterface.swift must define {symbol}")

    def test_discovered_interface_formatters_exist(self) -> None:
        self.assertTrue(
            DISCOVERED_FORMATTING.is_file(),
            "RNSAPI/DiscoveredInterfaceFormatting.swift must exist",
        )
        source = DISCOVERED_FORMATTING.read_text(encoding="utf-8")
        for symbol in (
            "DiscoveredTypeFilter",
            "isYggdrasilAddress",
            "formatInterfaceType",
            "formatLastHeard",
            "haversineDistanceKm",
            "formatLoraParamsForClipboard",
            "DiscoveredSorter",
            "DiscoveredFilter",
        ):
            self.assertIn(symbol, source, f"DiscoveredInterfaceFormatting.swift must define {symbol}")

    def test_config_writer_emits_discovery_keys(self) -> None:
        source = CONFIG_WRITER.read_text(encoding="utf-8")
        for key in (
            "discover_interfaces",
            "autoconnect_discovered_interfaces",
            "bootstrap_only",
        ):
            self.assertIn(key, source, f"PythonConfigWriter must emit the {key} RNS config key")

    def test_settings_repository_persists_discovery_settings(self) -> None:
        source = SETTINGS_REPO.read_text(encoding="utf-8")
        for key in ("discoverInterfacesEnabled", "autoconnectDiscoveredCount"):
            self.assertIn(key, source, f"SettingsRepository must persist the {key} setting")

    def test_restart_python_backend_is_a_real_in_process_restart(self) -> None:
        source = APP_SERVICES.read_text(encoding="utf-8")
        code = strip_comments(source)
        self.assertNotIn(
            "ColumbaRelaunchRequired",
            code,
            "the dead ColumbaRelaunchRequired stub notification must be gone",
        )
        start = source.index("func restartPythonBackend")
        end = source.index("\n    func ", start + 1)
        body = strip_comments(source[start:end])
        for symbol in ("shutdownUnlocked", "initializeUnlocked", "ColumbaBackendRestarted"):
            self.assertIn(
                symbol,
                body,
                f"restartPythonBackend() must reference {symbol} (real in-process restart)",
            )
        self.assertGreaterEqual(
            source.count("lastTcpServerAddress"),
            3,
            "lastTcpServerAddress must be declared, assigned, and read (3+ occurrences)",
        )

    def test_one_shot_location_provider_never_prompts(self) -> None:
        self.assertTrue(ONE_SHOT_PROVIDER.is_file(), "OneShotLocationProvider.swift must exist")
        source = ONE_SHOT_PROVIDER.read_text(encoding="utf-8")
        self.assertIn(
            "authorizationStatus",
            source,
            "OneShotLocationProvider must check authorizationStatus",
        )
        self.assertNotIn(
            "requestWhenInUseAuthorization",
            strip_comments(source),
            "OneShotLocationProvider must never call requestWhenInUseAuthorization() "
            "(no fresh location prompt from the discovery screen)",
        )

    def test_view_model_omits_autoconnect_sub_toggle(self) -> None:
        self.assertTrue(DISCOVERY_VM.is_file(), "DiscoveredInterfacesViewModel.swift must exist")
        source = DISCOVERY_VM.read_text(encoding="utf-8")
        self.assertIn("ifacOnly", source, "the VM must expose the ifacOnly display filter")
        self.assertNotIn(
            "autoconnectIfacOnly",
            source,
            "the autoconnect ifacOnly sub-toggle is deliberately omitted on the Python backend",
        )

    def test_discovery_screen_carries_all_a11y_identifiers(self) -> None:
        self.assertTrue(DISCOVERY_SCREEN.is_file(), "DiscoveredInterfacesScreen.swift must exist")
        source = DISCOVERY_SCREEN.read_text(encoding="utf-8")
        for identifier in (
            "discovery_toggle",
            "discovery_search",
            "discovery_ifac_only",
            "discovery_clear_filters",
            "discovery_refresh",
            "discovery_card_add_config",
            "discovery_card_copy_params",
            "discovery_card_use_rnode",
            "discovered_card_",
        ):
            self.assertIn(
                identifier,
                source,
                f"DiscoveredInterfacesScreen.swift must reference the {identifier} a11y identifier",
            )

    def test_interface_management_screen_links_discovery_entry(self) -> None:
        self.assertIn(
            "discovery_entry_card",
            INTERFACE_MGMT_SCREEN.read_text(encoding="utf-8"),
            "InterfaceManagementScreen.swift must expose the discovery_entry_card",
        )

    def test_pbxproj_registers_discovery_files(self) -> None:
        source = PBXPROJ.read_text(encoding="utf-8")
        for file_name in (
            "DiscoveredInterfacesScreen.swift",
            "DiscoveredInterfacesViewModel.swift",
            "OneShotLocationProvider.swift",
            "DiscoveredInterfaceTests.swift",
        ):
            self.assertGreaterEqual(
                source.count(f"/* {file_name} */"),
                2,
                f"{file_name} must have both a PBXFileReference and a PBXBuildFile entry",
            )
            self.assertGreaterEqual(
                source.count(file_name),
                3,
                f"{file_name} must appear in file reference, group children, and a build phase (3+ occurrences)",
            )

        start = source.index("TSRCBP /* Sources */ = {")
        end = source.index("/* End", start)
        tsources = source[start:end]
        self.assertIn(
            "DiscoveredInterfaceTests.swift",
            tsources,
            "DiscoveredInterfaceTests.swift must be in the TSRCBP (ColumbaAppTests) sources phase — "
            "registering it in a source-target phase is the silent-exclusion trap",
        )

    def test_localization_catalog_covers_discovery_strings(self) -> None:
        catalog = json.loads(LOCALIZATIONS.read_text(encoding="utf-8"))
        strings = catalog["strings"]
        required = {
            "Discovered Interfaces",
            "Interface Discovery",
            "Restarting Reticulum…",
            "%lld interfaces found via RNS Discovery",
            "Add to Config",
        }
        self.assertTrue(
            required.issubset(strings),
            f"Localizable.xcstrings must contain the discovery strings; missing: "
            f"{sorted(required - strings.keys())}",
        )

    def test_discovered_filter_applies_ifac_only(self) -> None:
        source = DISCOVERED_FORMATTING.read_text(encoding="utf-8")
        start = source.index("public enum DiscoveredFilter")
        # DiscoveredFilter is the final type in the file; its apply(_:) body
        # is everything from the enum declaration to EOF.
        code = strip_comments(source[start:])
        self.assertIn(
            "ifacOnly",
            code,
            "DiscoveredFilter.apply must reference ifacOnly (the IFAC display filter)",
        )


if __name__ == "__main__":
    unittest.main()
