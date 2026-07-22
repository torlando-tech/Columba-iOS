import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ExplicitDestinationAspectContracts(unittest.TestCase):
    @staticmethod
    def read(relative: str) -> str:
        return (ROOT / relative).read_text()

    def test_exact_aspect_model_and_unknown_type(self):
        compat = self.read("Sources/RNSAPI/Compat.swift")
        contacts = self.read("Sources/ColumbaApp/ViewModels/ContactsViewModel.swift")

        for value in (
            'case lxmfDelivery = "lxmf.delivery"',
            'case lxmfPropagation = "lxmf.propagation"',
            'case lxstTelephony = "lxst.telephony"',
            'case nomadNetworkNode = "nomadnetwork.node"',
            "case unsupported",
        ):
            self.assertIn(value, compat)
        self.assertIn("switch entry.destinationAspect", contacts)
        self.assertIn("case .unsupported:", contacts)
        self.assertIn("self.badgeType = .unsupported", contacts)
        self.assertIn("aspect: .some(contact.aspect)", contacts)

    def test_actions_and_relay_selection_require_exact_aspect(self):
        details = self.read("Sources/ColumbaApp/Views/Contacts/NodeDetailsView.swift")
        contacts_view = self.read("Sources/ColumbaApp/Views/Contacts/ContactsView.swift")
        manager = self.read("Sources/ColumbaApp/Services/PropagationNodeManager.swift")

        self.assertIn("displayedContact.destinationAspect == .lxmfPropagation", details)
        self.assertIn("c.destinationAspect == .lxmfDelivery", details)
        self.assertIn("c.destinationAspect == .lxstTelephony", details)
        self.assertIn("c.destinationAspect == .nomadNetworkNode", details)
        self.assertIn("onStartChat: { contact in", contacts_view)
        self.assertGreaterEqual(
            manager.count("entry.destinationAspect == .lxmfPropagation"), 2
        )
        self.assertIn("info.enabled else", manager)

    def test_saved_contact_enrichment_copies_aspect_on_startup_and_live_updates(self):
        contacts = self.read("Sources/ColumbaApp/ViewModels/ContactsViewModel.swift")

        self.assertIn("existing.aspect != contact.aspect", contacts)
        self.assertIn("aspect: .some(contact.aspect)", contacts)
        self.assertIn("announce.aspect != contact.aspect", contacts)
        self.assertIn("aspect: .some(announce.aspect)", contacts)


if __name__ == "__main__":
    unittest.main()
