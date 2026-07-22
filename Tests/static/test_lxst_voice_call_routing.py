#!/usr/bin/env python3
"""Contracts for first-class lxst.telephony call routing."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class LXSTVoiceCallRoutingContracts(unittest.TestCase):
    def _read(self, relative: str) -> str:
        return (ROOT / relative).read_text()

    def test_chat_resolves_before_telephone_receives_target(self) -> None:
        source = self._read("Sources/ColumbaApp/Services/CallManager.swift")
        self.assertIn("resolveTelephonyTarget(from: destinationHash)", source)
        self.assertIn("networkTransport.prepareOutboundCall(target)", source)
        self.assertIn(
            "telephone.call(destinationHash: target.destinationHash, profile: profile)",
            source,
        )
        self.assertNotIn(
            "telephone.call(destinationHash: destinationHash, profile: profile)",
            source,
        )

    def test_resolver_accepts_direct_telephony_announce(self) -> None:
        source = self._read("Sources/ColumbaApp/Services/CallManager.swift")
        resolver = re.search(
            r"private func resolveTelephonyTarget\(.*?\n    }\n\n    private func failOutgoingCall",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(resolver)
        assert resolver is not None
        body = resolver.group(0)
        self.assertIn("source.destinationAspect == .lxstTelephony", body)
        self.assertIn("guard sourceHash == derivedHash", body)
        self.assertIn(
            "TelephonyCallTarget(destinationHash: sourceHash, publicKeys: source.publicKeys)",
            body,
        )

    def test_resolver_prefers_linked_announce_but_derives_fallback(self) -> None:
        source = self._read("Sources/ColumbaApp/Services/CallManager.swift")
        self.assertIn("await pathTable.allEntries().first(where:", source)
        self.assertIn("$0.publicKeys == source.publicKeys", source)
        self.assertIn("$0.destinationHash == derivedHash", source)
        self.assertIn(
            "return TelephonyCallTarget(destinationHash: derivedHash, publicKeys: source.publicKeys)",
            source,
        )

    def test_network_transport_accepts_only_telephony_hash(self) -> None:
        source = self._read(
            "Sources/ColumbaApp/Services/PythonNetworkTransport.swift"
        )
        outbound = re.search(
            r"public func openOutboundCall\(.*?\n    }\n\n    public func identifySelf",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(outbound)
        assert outbound is not None
        body = outbound.group(0)
        self.assertIn("to telephonyHash: Data", body)
        self.assertIn("callDest.hash == telephonyHash", body)
        self.assertIn("transport.initiateLink(to: callDest", body)
        self.assertNotIn("deliveryHash", body)

    def test_phone_node_details_uses_call_action_and_codec_picker(self) -> None:
        details = self._read(
            "Sources/ColumbaApp/Views/Contacts/NodeDetailsView.swift"
        )
        self.assertIn("if c.destinationAspect == .lxstTelephony, let onStartCall", details)
        self.assertIn('title: "Call"', details)
        self.assertIn("onStartCall(c)", details)
        self.assertIn(
            "c.destinationAspect == .lxmfDelivery, let onStartChat",
            details,
        )

        contacts = self._read("Sources/ColumbaApp/Views/Contacts/ContactsView.swift")
        self.assertIn("onStartCall: { contact in", contacts)
        self.assertIn("CodecSelectionSheet { profile in", contacts)
        self.assertIn("destinationHash: contact.identityHash", contacts)

    def test_python_actively_requests_and_awaits_telephony_path(self) -> None:
        bridge = self._read("app/rns_bridge.py")
        open_link = re.search(r"def open_link\(.*?\n(?=\ndef )", bridge, re.DOTALL)
        self.assertIsNotNone(open_link)
        assert open_link is not None
        body = open_link.group(0)
        self.assertIn("identity_public_key_hex", body)
        self.assertIn("candidate.load_public_key", body)
        self.assertIn("candidate_dest.hash != dest_hash", body)
        self.assertIn("RNS.Transport.has_path(dest_hash)", body)
        self.assertIn("RNS.Transport.request_path(dest_hash)", body)
        self.assertIn("deadline = time.monotonic() + 10.0", body)
        self.assertIn('"reason": "no-path"', body)

    def test_public_identity_crosses_into_python_link_open(self) -> None:
        app_services = self._read("Sources/ColumbaApp/Services/AppServices.swift")
        self.assertIn(
            "identityPublicKeyHex: destination.identity?.publicKeyHex",
            app_services,
        )


if __name__ == "__main__":
    unittest.main()
