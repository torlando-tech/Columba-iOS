#!/usr/bin/env python3
"""Regression contracts for the three runtime bugs reported on 2026-07-19."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROJECT_FILE = ROOT / "Columba.xcodeproj/project.pbxproj"
BRIDGE_PY = ROOT / "app/rns_bridge.py"
PYTHON_BRIDGE = ROOT / "Sources/PythonBridge/PythonBridge.swift"
RNS_BACKEND = ROOT / "Sources/RNSAPI/Protocols/RnsBackend.swift"
PY_BACKEND = ROOT / "Sources/RNSBackendPy/PythonRNSBackend.swift"
SWIFT_BACKEND = ROOT / "Sources/RNSBackendSwift/SwiftRNSBackend.swift"
APP_SERVICES = ROOT / "Sources/ColumbaApp/Services/AppServices.swift"
SETTINGS_VIEW = ROOT / "Sources/ColumbaApp/Views/Settings/SettingsView.swift"
MAIN_TAB_VIEW = ROOT / "Sources/ColumbaApp/Views/MainTabView.swift"
MESSAGE_BUBBLE = ROOT / "Sources/ColumbaApp/Views/Messaging/MessageBubble.swift"
MESSAGING_VIEW = ROOT / "Sources/ColumbaApp/Views/Messaging/MessagingView.swift"
TEXT_SIZE_PICKER = ROOT / "Sources/ColumbaApp/Views/Messaging/TextSizePickerSheet.swift"
INCOMING_MESSAGE_HANDLER = ROOT / "Sources/ColumbaApp/Services/IncomingMessageHandler.swift"
LOCATION_SHARING_MANAGER = ROOT / "Sources/ColumbaApp/Services/LocationSharingManager.swift"


class ReportedRuntimeBugContracts(unittest.TestCase):
    def test_ios_conversation_message_text_scale_parity_contract(self) -> None:
        settings_repository = (
            ROOT / "Sources/ColumbaApp/Services/SettingsRepository.swift"
        ).read_text()
        messaging_view = MESSAGING_VIEW.read_text()
        text_size_picker = TEXT_SIZE_PICKER.read_text()
        message_bubble = MESSAGE_BUBBLE.read_text()
        migration_exporter = (
            ROOT / "Sources/ColumbaApp/Services/MigrationExporter.swift"
        ).read_text()
        migration_importer = (
            ROOT / "Sources/ColumbaApp/Services/MigrationImporter.swift"
        ).read_text()

        self.assertIn('message_text_scale', settings_repository)
        self.assertIn(
            'Label("Text Size", systemImage: "textformat.size")', messaging_view
        )
        self.assertIn('TextSizePickerSheet(', messaging_view)
        self.assertIn('messageTextScale: messageTextScale', messaging_view)
        self.assertIn('@ScaledMetric(relativeTo: .body)', text_size_picker)
        self.assertIn('.accessibilityLabel("Message text size")', text_size_picker)
        for identifier in (
            "text_size_preview",
            "text_size_percent",
            "text_size_slider",
            "text_size_range_labels",
            "text_size_cancel",
            "text_size_confirm",
        ):
            self.assertIn(f'.accessibilityIdentifier("{identifier}")', text_size_picker)
        self.assertIn('@ScaledMetric(relativeTo: .body)', message_bubble)
        self.assertIn('bodyFontSize * CGFloat(messageTextScale)', message_bubble)
        self.assertIn('.double("message_text_scale"', migration_exporter)
        self.assertIn('case "message_text_scale":', migration_importer)

    def test_inbound_telemetry_retains_lxmf_display_name(self) -> None:
        handler = INCOMING_MESSAGE_HANDLER.read_text()
        telemetry_dispatch = re.search(
            r"handleIncomingTelemetry\(.*?\n\s*\)", handler, re.DOTALL
        )
        self.assertIsNotNone(telemetry_dispatch)
        assert telemetry_dispatch is not None
        self.assertIn("displayName: senderDisplayName", telemetry_dispatch.group(0))
        self.assertNotIn("displayName: nil", telemetry_dispatch.group(0))

        manager = LOCATION_SHARING_MANAGER.read_text()
        self.assertIn("TelemetryDisplayNameResolver.resolve(", manager)

    def test_inbound_event_preserves_canonical_lxmf_hash_end_to_end(self) -> None:
        bridge = BRIDGE_PY.read_text()
        callback = re.search(
            r"def _delivery_callback\(.*?\n(?=\ndef )", bridge, re.DOTALL
        )
        self.assertIsNotNone(callback)
        assert callback is not None
        callback_source = callback.group(0)
        self.assertIn("message_hash", callback_source)
        self.assertIn("_canonical_inbound_hash(message)", callback_source)
        self.assertIn(
            'message_hash = canonical_hash.hex() if canonical_hash is not None else ""',
            callback_source,
        )
        self.assertNotIn("Ignoring inbound LXMF message", callback_source)

        canonical_helper = re.search(
            r"def _canonical_inbound_hash\(.*?\n(?=\ndef )", bridge, re.DOTALL
        )
        self.assertIsNotNone(canonical_helper)
        assert canonical_helper is not None
        helper_source = canonical_helper.group(0)
        self.assertIn('getattr(message, "hash", None)', helper_source)
        self.assertIn('getattr(message, "message_id", None)', helper_source)
        self.assertIn("LXMF.LXMessage.unpack_from_bytes", helper_source)

        py_bridge = PYTHON_BRIDGE.read_text()
        self.assertRegex(
            py_bridge,
            r"case inbound\(sourceHash: String, messageHash: String, content:",
        )
        self.assertIsNotNone(re.search(
            r'case "inbound":.*?key: "message_hash".*?\.inbound\(sourceHash: h, messageHash:',
            py_bridge,
            re.DOTALL,
        ))

        backend_event = RNS_BACKEND.read_text()
        self.assertRegex(
            backend_event,
            r"case inbound\(sourceHash: String, messageHash: String, content:",
        )

        py_backend = PY_BACKEND.read_text()
        self.assertIsNotNone(re.search(
            r"case let \.inbound\(s, mh, c, ti, fh, t\):.*?"
            r"\.inbound\(sourceHash: s, messageHash: mh, content: c",
            py_backend,
            re.DOTALL,
        ))

        swift_backend = SWIFT_BACKEND.read_text()
        self.assertRegex(
            swift_backend,
            r"\.inbound\(sourceHash: message\.sourceHash\.hexHash, "
            r"messageHash: message\.hash\.hexHash, content:",
        )

        app_services = APP_SERVICES.read_text()
        persist = re.search(
            r"private func persistInboundFromPython\b.*?\n    }\n\n    private func handlePythonEvent",
            app_services,
            re.DOTALL,
        )
        self.assertIsNotNone(persist)
        assert persist is not None
        persist_source = persist.group(0)
        self.assertIn("messageHashHex: String", persist_source)
        self.assertIn("Data(hexString: messageHashHex)", persist_source)
        self.assertIn("parsedHash.count == 32", persist_source)
        self.assertIn("Data([0x00]) + Data(SHA256.hash(data: seed))", persist_source)
        self.assertIn("persistInbound using local non-wire message id", persist_source)
        self.assertIsNotNone(re.search(
            r"case \.inbound\(let sourceHash, let messageHash, let content,"
            r".*?persistInboundFromPython\(sourceHash: data, messageHashHex: messageHash,",
            app_services,
            re.DOTALL,
        ))

    def test_non_wire_persistence_ids_cannot_target_reactions_or_replies(self) -> None:
        bubble = MESSAGE_BUBBLE.read_text()
        self.assertIn(
            "self.messageHash = lxMessage.hash.count == 32 ? lxMessage.hash : nil",
            bubble,
        )
        self.assertIn(
            "self.messageHash = record.messageId.count == 32 ? record.messageId : nil",
            bubble,
        )

        messaging = MESSAGING_VIEW.read_text()
        self.assertIsNotNone(re.search(
            r"guard message\.messageHash != nil,\s+"
            r"vm\.canTargetMessage\(messageId: message\.id\) else \{ return \}",
            messaging,
        ))
        self.assertIsNotNone(re.search(
            r"guard msg\.messageHash != nil,\s+"
            r"viewModel\?\.canTargetMessage\(messageId: msg\.id\) == true else \{ return \}",
            messaging,
        ))
        self.assertIn("target.isTargetSafe", messaging)
        self.assertIn(
            'return hash.map { String(format: "%02x", $0) }.joined()',
            messaging,
        )

    def test_rnode_cover_dismissal_clears_editing_state(self) -> None:
        settings = SETTINGS_VIEW.read_text()
        cover = re.search(
            r"\.fullScreenCover\(isPresented: Binding\(.*?\n        \}\n        #endif",
            settings,
            re.DOTALL,
        )
        self.assertIsNotNone(cover)
        assert cover is not None
        self.assertIsNotNone(re.search(
            r"onDismiss:\s*\{.*?interfaceViewModel\?\.dismissConfigSheet\(\).*?\}",
            cover.group(0),
            re.DOTALL,
        ))

    def test_onboarding_rnode_request_is_consumed_after_main_tab_is_mounted(self) -> None:
        main_tab = MAIN_TAB_VIEW.read_text()
        self.assertIn(".onAppear {\n            consumePendingRNodeSetup()", main_tab)
        self.assertIsNotNone(re.search(
            r"\.onChange\(of: pendingRNodeSetup\).*?if requested \{\s*"
            r"consumePendingRNodeSetup\(\)",
            main_tab,
            re.DOTALL,
        ))
        consumer = re.search(
            r"private func consumePendingRNodeSetup\(\).*?\n    }",
            main_tab,
            re.DOTALL,
        )
        self.assertIsNotNone(consumer)
        assert consumer is not None
        source = consumer.group(0)
        self.assertIn("selectedTab = .settings", source)
        self.assertIn("shouldOpenRNodeWizard = true", source)
        self.assertIn("pendingRNodeSetup = false", source)

        settings = SETTINGS_VIEW.read_text()
        self.assertIsNotNone(re.search(
            r"\.onChange\(of: shouldOpenRNodeWizard\).*?if requested \{\s*"
            r"openRequestedRNodeWizard\(\)",
            settings,
            re.DOTALL,
        ))
        self.assertIn("openRequestedRNodeWizard()\n\n            // Poll connection state", settings)
        self.assertIn("private func openRequestedRNodeWizard()", settings)

        consumer = re.search(
            r"private func openRequestedRNodeWizard\(\).*?\n    }",
            settings,
            re.DOTALL,
        )
        self.assertIsNotNone(consumer)
        assert consumer is not None
        consumer_source = consumer.group(0)
        self.assertIn("#if os(iOS) && COLUMBA_RNODE_ENABLED", consumer_source)
        self.assertLess(
            consumer_source.index("#if os(iOS) && COLUMBA_RNODE_ENABLED"),
            consumer_source.index("shouldOpenRNodeWizard = false"),
        )

        project = PROJECT_FILE.read_text()
        shipping_release = re.search(
            r"TREL /\* Release \*/ = \{.*?\n\t\t\};",
            project,
            re.DOTALL,
        )
        self.assertIsNotNone(shipping_release)
        assert shipping_release is not None
        self.assertIn("COLUMBA_RNODE_ENABLED", shipping_release.group(0))

    def test_incoming_message_size_limit_contract(self) -> None:
        bridge = BRIDGE_PY.read_text()
        self.assertIn("def set_incoming_message_size_limit_kb(", bridge)
        self.assertIn("router.delivery_per_transfer_limit = bounded", bridge)
        self.assertIn('return {"ok": True, "reason": "ok", "limit_kb": bounded}', bridge)

        py_bridge = PYTHON_BRIDGE.read_text()
        self.assertIn("public func setIncomingMessageSizeLimitKB(_ limitKB: Int) async throws -> Bool", py_bridge)
        self.assertIn('PyObject_GetAttrString(module, "set_incoming_message_size_limit_kb")', py_bridge)

        py_backend = PY_BACKEND.read_text()
        self.assertIn("public func setIncomingMessageSizeLimitKB(_ limitKB: Int) async throws -> Bool", py_backend)

        settings = SETTINGS_VIEW.read_text()
        self.assertIn("Incoming Size Limit", settings)
        self.assertIn('"1 MB"', settings)
        self.assertIn('"Unlimited"', settings)
        self.assertIn("packed incoming LXMF messages", settings)

        migration_exporter = (ROOT / "Sources/ColumbaApp/Services/MigrationExporter.swift").read_text()
        self.assertIn('incoming_message_size_limit_kb', migration_exporter)
        migration_importer = (ROOT / "Sources/ColumbaApp/Services/MigrationImporter.swift").read_text()
        self.assertIn('case "incoming_message_size_limit_kb":', migration_importer)
        self.assertIn("importedIncomingMessageSizeLimit = true", migration_importer)
        self.assertIn("await appServices?.applyIncomingMessageSizeLimitFromSettings()", migration_importer)
        self.assertIn('Text("Custom (\\(vm.incomingMessageSizeLimitKB) KB)")', settings)


if __name__ == "__main__":
    unittest.main()
