import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCREEN = ROOT / "Sources/ColumbaApp/Views/Settings/MigrationScreen.swift"
VIEW_MODEL = ROOT / "Sources/ColumbaApp/ViewModels/MigrationViewModel.swift"


def source(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class MigrationExportFlowContractTests(unittest.TestCase):
    def test_password_export_opens_file_exporter_without_intermediate_save_action(self) -> None:
        screen = source(SCREEN)
        view_model = source(VIEW_MODEL)

        self.assertNotIn('Text("Save Backup File")', screen)
        self.assertNotIn('Text("Export complete!")', screen)
        self.assertNotIn("case .exportComplete", view_model)
        self.assertIn("Task { await beginExport() }", screen)

        begin_export = screen.split("private func beginExport() async {", 1)[1].split(
            "private func handleFileImport", 1
        )[0]
        self.assertIn("guard let url = await viewModel.startExport() else { return }", begin_export)
        self.assertIn("exportDocument = ColumbaBackupDocument(data: data)", begin_export)
        self.assertLess(
            begin_export.index("exportDocument = ColumbaBackupDocument(data: data)"),
            begin_export.index("showFileExporter = true"),
        )

    def test_export_picker_completion_is_retryable_and_generation_safe(self) -> None:
        screen = source(SCREEN)
        view_model = source(VIEW_MODEL)

        exporter_completion = screen.split(".fileExporter(", 1)[1].split("// MARK: - Export Section", 1)[0]
        self.assertIn("viewModel.handleExportSaveResult(result)", exporter_completion)
        self.assertIn("var canStartExport: Bool", view_model)
        self.assertIn("guard canStartExport else { return nil }", view_model)
        self.assertIn("CocoaError.Code.userCancelled", view_model)
        self.assertIn("state = .idle", view_model)
        self.assertIn('state = .error(message: "Save failed:', view_model)
        self.assertLess(
            view_model.index("activeExportGeneration = nil\n            state = .exporting(progress: 1)"),
            view_model.index("return url"),
        )


if __name__ == "__main__":
    unittest.main()
