import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
APP_SERVICES = ROOT / "Sources/ColumbaApp/Services/AppServices.swift"


class PythonInboundPersistenceContractTests(unittest.TestCase):
    def test_message_save_precedes_display_name_enrichment(self):
        source = APP_SERVICES.read_text(encoding="utf-8")
        start = source.index("private func persistInboundFromPython(")
        end = source.index("private func handlePythonEvent(", start)
        body = source[start:end]

        save = body.index("try await repo.saveMessage(message)")
        ensure = body.index("try await repo.ensureConversation(sourceHash, displayName: displayName)")
        self.assertLess(
            save,
            ensure,
            "Inbound save must create/update the conversation before display-name enrichment; "
            "pre-creating it with a newer timestamp leaves lastMessagePreview empty.",
        )


if __name__ == "__main__":
    unittest.main()
