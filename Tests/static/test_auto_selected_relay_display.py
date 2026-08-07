from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
SETTINGS_VIEW = ROOT / "Sources/ColumbaApp/Views/Settings/SettingsView.swift"


def test_current_relay_reads_live_propagation_manager_selection() -> None:
    source = SETTINGS_VIEW.read_text(encoding="utf-8")
    card = re.search(
        r"private func deliveryRetrievalCard\(.+?(?=\n    // MARK:|\Z)",
        source,
        flags=re.DOTALL,
    )
    assert card is not None
    body = card.group(0)

    assert "appServices.propagationManager?.selectedNodeName" in body
    assert 'Text(vm.selectedRelayName ?? "None")' not in body
