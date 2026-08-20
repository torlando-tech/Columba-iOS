import ast
import pathlib
import re
import threading
import unittest
from unittest import mock
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[2]


class QRContactSendPathContractTests(unittest.TestCase):
    def _read(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def _swift_function(self, relative: str, signature: str, next_marker: str) -> str:
        source = self._read(relative)
        start = source.index(signature)
        end = source.index(next_marker, start)
        return source[start:end]

    def _load_resolve_path(self, *, resolves_after_sleep: bool):
        source = self._read("app/rns_bridge.py")
        tree = ast.parse(source)
        function = next(
            node for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "resolve_path"
        )

        class FakeTransport:
            requests = 0
            path_known = False

            @classmethod
            def has_path(cls, _destination: bytes) -> bool:
                return cls.path_known

            @classmethod
            def request_path(cls, _destination: bytes) -> None:
                cls.requests += 1

        class FakeIdentity:
            @staticmethod
            def recall(_destination: bytes):
                return object() if FakeTransport.path_known else None

        class FakeRNS:
            Transport = FakeTransport
            Identity = FakeIdentity

        class FakeTime:
            now = 0.0

            @classmethod
            def monotonic(cls) -> float:
                return cls.now

            @classmethod
            def sleep(cls, interval: float) -> None:
                cls.now += interval
                if resolves_after_sleep:
                    FakeTransport.path_known = True

        namespace = {
            "Any": Any,
            "RNS": FakeRNS,
            "time": FakeTime,
            "_lock": threading.Lock(),
            "_state": {"started": True},
        }
        exec(compile(ast.Module(body=[function], type_ignores=[]), "rns_bridge.py", "exec"), namespace)
        return namespace["resolve_path"], FakeTransport

    def test_contact_add_and_details_do_not_request_paths(self) -> None:
        contacts = self._swift_function(
            "Sources/ColumbaApp/ViewModels/ContactsViewModel.swift",
            "public func addContactFromQR(",
            "/// Convert a hex string to Data",
        )
        details = self._read("Sources/ColumbaApp/Views/Contacts/NodeDetailsView.swift")

        self.assertNotIn("requestPath", contacts)
        self.assertNotIn("requestPath", details)
        self.assertNotIn("Tap an action to issue a path request", details)

    def test_contacts_plus_menu_supports_passive_hash_only_add(self) -> None:
        contacts_view = self._read("Sources/ColumbaApp/Views/Contacts/ContactsView.swift")
        add_sheet = self._read("Sources/ColumbaApp/Views/Contacts/AddContactSheet.swift")
        add_hash = self._swift_function(
            "Sources/ColumbaApp/ViewModels/ContactsViewModel.swift",
            "public func addContactFromHash(",
            "/// Convert a hex string to Data",
        )

        self.assertIn('Image(systemName: "plus")', contacts_view)
        self.assertIn('.accessibilityLabel("Add Contact")', contacts_view)
        self.assertIn('Button("Scan QR Code")', contacts_view)
        self.assertIn('Button("Enter Address Manually")', contacts_view)
        self.assertIn("ManualContactEntrySheet(", contacts_view)
        self.assertIn("struct ManualContactEntrySheet: View", add_sheet)
        self.assertIn("PasteButton(payloadType: String.self)", add_sheet)
        self.assertIn('accessibilityIdentifier("paste_contact_address")', add_sheet)
        self.assertIn("ContactsViewModel.parseContactInput", add_sheet)
        self.assertIn("viewModel.addContactFromHash", add_sheet)
        self.assertIn("onExistingContact", add_sheet)
        self.assertNotIn(".alert(item: $existingContactNotice)", add_sheet)
        self.assertIn("onDismiss: presentPendingExistingContactNotice", contacts_view)
        self.assertIn("pendingExistingContactNotice = notice", contacts_view)
        self.assertIn('Button("OK")', contacts_view)
        self.assertIn("existingContactNotice = nil", contacts_view)
        self.assertGreaterEqual(add_sheet.count(".interactiveDismissDisabled(isAdding)"), 2)
        self.assertGreaterEqual(add_sheet.count(".disabled(isAdding)"), 3)
        self.assertIn("messageRepository.ensureConversation", add_hash)
        self.assertIn("messageRepository.setFavorite", add_hash)
        self.assertIn("applyAnnouncedDisplayName", add_hash)
        self.assertIn("fetchConversations(for: [destinationHash])", add_hash)
        self.assertIn("networkAnnounces.first", add_hash)
        self.assertIn("pendingAnnounces.first", add_hash)
        self.assertNotIn("requestPath", add_hash)

    def test_shipping_send_resolves_path_before_bridge_send(self) -> None:
        backend = self._swift_function(
            "Sources/RNSBackendPy/PythonRNSBackend.swift",
            "public func sendLxmfMessage(",
            "public func sendReaction(",
        )
        resolve = backend.index("bridge.resolvePath")
        send = backend.index("bridge.sendOpportunistic")
        self.assertLess(resolve, send)

    def test_shipping_path_wait_uses_dedicated_bridge_queue(self) -> None:
        body = self._swift_function(
            "Sources/PythonBridge/PythonBridge.swift",
            "    public func resolvePath(",
            "    /// Send an LXMF message via the Python bridge.",
        )
        self.assertIn("runOnQueue(on: pathResolutionQueue)", body)

    def test_shipping_reaction_resolves_path_before_send(self) -> None:
        body = self._swift_function(
            "Sources/RNSBackendPy/PythonRNSBackend.swift",
            "    public func sendReaction(",
            "    /// Set / clear the outbound LXMF propagation node.",
        )
        self.assertLess(body.index("bridge.resolvePath"), body.index("bridge.sendOpportunistic"))

    def test_failed_send_is_persisted_with_actionable_reason(self) -> None:
        body = self._swift_function(
            "Sources/ColumbaApp/ViewModels/MessagingViewModel.swift",
            "    public func sendMessage(\n        text: String,",
            "    /// Retry sending a failed message.",
        )
        start = body.index("        } catch {\n            var failure")
        final_failure = body[start:]
        self.assertIn("lxMessage.state = .failed", final_failure)
        self.assertIn("persistMessage(lxMessage, replacing: localRetryHash)", final_failure)
        self.assertIn("failure.localizedDescription", final_failure)
        self.assertIn("DiagLog.log", final_failure)
        self.assertNotIn('errorMessage = "Failed to send: \\(error.localizedDescription)"', final_failure)

    def test_failed_send_retry_preserves_identity_and_payload(self) -> None:
        source = self._read("Sources/ColumbaApp/ViewModels/MessagingViewModel.swift")
        self.assertIn("Data((0..<32).map", source)
        self.assertIn("localRetryHash", source)
        retry = self._swift_function(
            "Sources/ColumbaApp/ViewModels/MessagingViewModel.swift",
            "    public func retryMessage(",
            "    /// Delete a message from the conversation.",
        )
        self.assertIn("imageData: failedMessage.imageData", retry)
        self.assertIn("attachments: failedMessage.attachments", retry)
        self.assertNotIn("repository.deleteMessage", retry)

    def test_retry_replacement_is_staged_and_atomic(self) -> None:
        send = self._swift_function(
            "Sources/ColumbaApp/ViewModels/MessagingViewModel.swift",
            "    public func sendMessage(\n",
            "    /// Retry sending a failed message.",
        )
        repository = self._read("Sources/ColumbaApp/Services/MessageRepository.swift")
        stage = send.index("lxMessage.state = .sending")
        wire_send = send.index("sendOutbound(")
        self.assertLess(stage, wire_send)
        self.assertIn("repository.stageRetry(lxMessage, replacing: storedHash)", send)
        self.assertIn("config.observesSuspensionNotifications = true", repository)
        self.assertIn("try await replacementPool.write", repository)
        self.assertIn("lxMessage.method = selectedDeliveryMethod", send)
        self.assertIn("retryMessage.method = .propagated", send)
        self.assertIn("replacementSourceMissing", repository)
        self.assertNotIn("repository.deleteMessage(oldHash)", send)

    def test_interrupted_retry_is_recovered_once_as_failed(self) -> None:
        view_model = self._read("Sources/ColumbaApp/ViewModels/MessagingViewModel.swift")
        repository = self._read("Sources/ColumbaApp/Services/MessageRepository.swift")
        app_services = self._read("Sources/ColumbaApp/Services/AppServices.swift")
        self.assertGreaterEqual(app_services.count("messageRepository.recoverInterruptedRetries()"), 3)
        self.assertIn("Verify whether it arrived before retrying", view_model)
        self.assertIn("repository.hasUncertainRetry(for: conversationHash)", view_model)
        self.assertIn("public func recoverInterruptedRetries", repository)
        self.assertIn("LXMFSwift.LXMessageState.sending.rawValue", repository)
        self.assertIn("receiving_interface = ?", repository)
        self.assertIn("Self.stagedRetryMarker", repository)
        self.assertIn("Self.uncertainRetryMarker", repository)
        self.assertIn("message_id = ? AND incoming = 0 AND state = ?", repository)
        self.assertIn("receiving_interface IS NULL OR receiving_interface LIKE ?", repository)
        self.assertIn('Self.uncertainRetryMarker + "%"', repository)
        self.assertIn("public func hasUncertainRetry", repository)

    def test_existing_qr_contact_can_refresh_peer_identity(self) -> None:
        add_sheet = self._read("Sources/ColumbaApp/Views/Contacts/AddContactSheet.swift")
        contacts = self._swift_function(
            "Sources/ColumbaApp/ViewModels/ContactsViewModel.swift",
            "public func addContactFromQR(",
            "/// Convert a hex string to Data",
        )
        self.assertNotIn("alreadyExists = true\n            return", add_sheet)
        self.assertIn("guard remembered else", contacts)
        self.assertLess(contacts.index("guard remembered else"), contacts.index("guard !myContacts.contains"))

    def test_relay_fallback_defaults_on_when_unset(self) -> None:
        settings = self._swift_function(
            "Sources/ColumbaApp/Services/SettingsRepository.swift",
            "    public func getRetryViaRelay()",
            "    /// Set whether to retry via relay on direct failure.",
        )
        self.assertIn("object(forKey:", settings)
        self.assertIn("return true", settings)

    def test_python_path_resolver_requests_once_and_is_bounded(self) -> None:
        bridge = self._read("app/rns_bridge.py")
        match = re.search(r"def resolve_path\(.*?\n(?=\ndef )", bridge, re.DOTALL)
        self.assertIsNotNone(match)
        assert match is not None
        body = match.group(0)
        self.assertIn("RNS.Transport.has_path", body)
        self.assertEqual(body.count("RNS.Transport.request_path"), 1)
        self.assertIn("time.monotonic()", body)
        self.assertIn("timeout_seconds", body)

    def test_python_path_resolver_is_passive_for_known_path(self) -> None:
        resolve_path, transport = self._load_resolve_path(resolves_after_sleep=False)
        transport.path_known = True

        result = resolve_path("00" * 16, 1.0)

        self.assertTrue(result["ok"])
        self.assertEqual(0, transport.requests)

    def test_python_path_resolver_requests_once_then_observes_resolution(self) -> None:
        resolve_path, transport = self._load_resolve_path(resolves_after_sleep=True)

        result = resolve_path("00" * 16, 1.0)

        self.assertTrue(result["ok"])
        self.assertEqual(1, transport.requests)

    def test_python_path_resolver_times_out_after_one_request(self) -> None:
        resolve_path, transport = self._load_resolve_path(resolves_after_sleep=False)

        result = resolve_path("00" * 16, 0.2)

        self.assertEqual({"ok": False, "reason": "timeout"}, result)
        self.assertEqual(1, transport.requests)

    def test_python_remembered_identity_is_bound_to_delivery_destination(self) -> None:
        try:
            import RNS
            import app.rns_bridge as bridge
        except ImportError as exc:
            self.skipTest(f"embedded RNS runtime unavailable: {exc}")

        identity = RNS.Identity()
        destination = RNS.Destination(
            identity,
            RNS.Destination.OUT,
            RNS.Destination.SINGLE,
            "lxmf",
            "delivery",
        )
        destination_hash = bytes(getattr(destination, "hash"))
        public_key = identity.get_public_key()
        self.assertIsNotNone(public_key)
        assert public_key is not None
        original_started = bridge._state["started"]
        bridge._state["started"] = True
        try:
            with mock.patch.object(RNS.Identity, "remember") as remember, \
                 mock.patch.object(RNS.Identity, "persist_data") as persist:
                persist.return_value = False
                persistence_failure = bridge.remember_peer_identity(
                    destination_hash.hex(),
                    public_key.hex(),
                )
                self.assertFalse(persistence_failure["ok"])
                self.assertEqual("persist-failed", persistence_failure["reason"])

                remember.reset_mock()
                persist.reset_mock()
                persist.return_value = None
                result = bridge.remember_peer_identity(
                    destination_hash.hex(),
                    public_key.hex(),
                )
                self.assertTrue(result["ok"])
                remember.assert_called_once()
                persist.assert_called_once()

                mismatch = bridge.remember_peer_identity(
                    (b"\x00" * 16).hex(),
                    public_key.hex(),
                )
                self.assertEqual("identity-mismatch", mismatch["reason"])
                self.assertEqual(1, remember.call_count)
        finally:
            bridge._state["started"] = original_started

    def test_qr_sheet_stays_open_when_identity_persistence_fails(self) -> None:
        contacts = self._swift_function(
            "Sources/ColumbaApp/ViewModels/ContactsViewModel.swift",
            "public func addContactFromQR(",
            "/// Convert a hex string to Data",
        )
        sheet = self._read("Sources/ColumbaApp/Views/Contacts/AddContactSheet.swift")
        self.assertIn("async -> Bool", contacts)
        self.assertIn("let succeeded = await viewModel.addContactFromQR", sheet)
        self.assertIn("guard succeeded else", sheet)
        self.assertIn("viewModel.errorMessage", sheet)


if __name__ == "__main__":
    unittest.main()
