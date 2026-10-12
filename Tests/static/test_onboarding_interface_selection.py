from pathlib import Path
import re
import unittest
import json


ROOT = Path(__file__).resolve().parents[2]
ONBOARDING_VIEW = ROOT / "Sources/ColumbaApp/Views/Onboarding/OnboardingView.swift"
RESTORE_SHEET = ROOT / "Sources/ColumbaApp/Views/Onboarding/OnboardingRestoreSheet.swift"
CONNECTIVITY_PAGE = ROOT / "Sources/ColumbaApp/Views/Onboarding/ConnectivityPage.swift"
PERMISSIONS_PAGE = ROOT / "Sources/ColumbaApp/Views/Onboarding/PermissionsPage.swift"
VIEW_MODEL = ROOT / "Sources/ColumbaApp/ViewModels/OnboardingViewModel.swift"
MIGRATION_VIEW_MODEL = ROOT / "Sources/ColumbaApp/ViewModels/MigrationViewModel.swift"
IDENTITY_MANAGER = ROOT / "Sources/ColumbaApp/Services/IdentityManager.swift"
MIGRATION_IMPORTER = ROOT / "Sources/ColumbaApp/Services/MigrationImporter.swift"
MIGRATION_EXPORTER = ROOT / "Sources/ColumbaApp/Services/MigrationExporter.swift"
MIGRATION_DATA = ROOT / "Sources/ColumbaApp/Models/MigrationData.swift"
APP_ENTRY = ROOT / "Sources/ColumbaApp/App/ColumbaApp.swift"
APP_SERVICES = ROOT / "Sources/ColumbaApp/Services/AppServices.swift"
MODEL_B_BLE_SERVICE = ROOT / "Sources/ColumbaApp/Services/ModelBBLEService.swift"
SETTINGS_VIEW = ROOT / "Sources/ColumbaApp/Views/Settings/SettingsView.swift"


def source(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class OnboardingInterfaceSelectionContracts(unittest.TestCase):
    def test_connectivity_choices_are_shared_by_both_hosts(self) -> None:
        text = source(CONNECTIVITY_PAGE)
        self.assertIn("@Binding var selectedInterfaces: Set<OnboardingInterfaceType>", text)
        self.assertNotIn("COLUMBA_RUNTIME_", text)
        self.assertIn("OnboardingInterfaceType.allCases.filter { $0 != .nearby }", text)
        self.assertIn("selectedInterfaces.insert(type)", text)
        self.assertIn("selectedInterfaces.remove(type)", text)

    def test_shipping_selection_is_bound_into_the_flow(self) -> None:
        text = source(ONBOARDING_VIEW)
        self.assertIn("selectedInterfaces: $viewModel.selectedInterfaces", text)
        self.assertNotIn("if viewModel.bluetoothAuthorization == .notDetermined", text)

    def test_skip_completes_only_after_success_and_surfaces_failures(self) -> None:
        text = source(ONBOARDING_VIEW)
        skip_ui = text.split("// First-run setup offers", 1)[1].split("// Page content", 1)[0]
        self.assertNotIn("try?", skip_ui)
        self.assertIn("do {", skip_ui)
        self.assertIn("catch {", skip_ui)
        self.assertIn("skipErrorMessage = error.localizedDescription", skip_ui)
        self.assertIn(".disabled(viewModel.isSaving)", skip_ui)
        self.assertLess(skip_ui.index("try await viewModel.skipOnboarding"), skip_ui.index("onComplete()"))
        self.assertIn('"Unable to Skip Setup"', text)
        self.assertIn('Text("Use Defaults")', skip_ui)
        self.assertIn('Button("Close", action: onCancel)', skip_ui)

        restore_parent = text.split("OnboardingRestoreSheet(viewModel: session.viewModel)", 1)[1].split(
            "#endif", 1
        )[0]
        self.assertNotIn("try?", restore_parent)
        self.assertLess(
            restore_parent.index("try await viewModel.completeRestoredOnboarding"),
            restore_parent.index("restoreSession = nil"),
        )
        self.assertLess(
            restore_parent.index("restoreSession = nil"),
            restore_parent.index("onComplete()"),
        )

        restore_sheet = source(RESTORE_SHEET)
        self.assertIn("let onComplete: (ImportResult) async throws -> Void", restore_sheet)
        self.assertIn("try await onComplete(result)", restore_sheet)
        self.assertIn("finishErrorMessage = error.localizedDescription", restore_sheet)
        self.assertIn(".disabled(isOperationLocked)", restore_sheet)
        self.assertIn(".interactiveDismissDisabled(isOperationLocked)", restore_sheet)
        self.assertIn("isFinishing || viewModel.isImporting", restore_sheet)

        view_model = source(VIEW_MODEL)
        self.assertIn("guard qrCodeString.isEmpty else { return }", view_model)
        self.assertIn("guard !isSaving else { throw OnboardingFlowError.operationInProgress }", view_model)
        self.assertGreaterEqual(view_model.count("try beginSaving()"), 3)
        self.assertGreaterEqual(view_model.count("createOrResumeIdentity("), 4)
        resume = view_model.split("private func createOrResumeIdentity(", 1)[1].split(
            "/// Seed the chosen TCP relay", 1
        )[0]
        self.assertLess(
            resume.index("identityManager.createIdentity"),
            resume.index("createdIdentity = local"),
        )
        self.assertLess(resume.index("createdIdentity = local"), resume.index("return local"))

        finish = text.split("onFinish: {", 1)[1].split("}\n        )", 1)[0]
        self.assertNotIn("try?", finish)
        self.assertIn("catch {", finish)
        self.assertIn("if viewModel.currentPage < 4", text)
        self.assertIn("sheet(item: $restoreSession)", text)
        self.assertIn("RestoreSession(viewModel: vm)", text)
        self.assertNotIn("showRestoreSheet", text)
        self.assertNotIn("migrationVM", text)

    def test_educational_copy_and_safe_settings_review(self) -> None:
        welcome = source(ROOT / "Sources/ColumbaApp/Views/Onboarding/WelcomePage.swift")
        identity = source(ROOT / "Sources/ColumbaApp/Views/Onboarding/IdentityPage.swift")
        connectivity = source(CONNECTIVITY_PAGE)
        permissions = source(PERMISSIONS_PAGE)
        complete = source(ROOT / "Sources/ColumbaApp/Views/Onboarding/CompletePage.swift")
        restore = source(RESTORE_SHEET)
        background = source(ROOT / "Sources/ColumbaApp/Views/Onboarding/BackgroundDeliveryPage.swift")
        settings = source(SETTINGS_VIEW)
        view_model = source(VIEW_MODEL)

        self.assertIn("Private messaging without a central account", welcome)
        self.assertIn("private cryptographic identity", welcome)
        self.assertIn("Choose a Display Name", identity)
        self.assertIn("Select one or more", connectivity)
        self.assertIn("Select at least one connection method", connectivity)
        self.assertIn("Recommended Relays", connectivity)
        self.assertIn("iOS Notifications", permissions)
        self.assertNotIn("Push Notifications", permissions)
        self.assertNotIn("Someone you know comes online", permissions)
        self.assertIn("encrypted backup from Settings", complete)
        self.assertIn("ScrollView", complete)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", complete)
        self.assertIn(".presentationDetents([.large])", complete)
        self.assertNotIn(".presentationDetents([.medium])", complete)
        self.assertIn("app settings may be updated", restore)
        self.assertNotIn("Your traffic isn't sent to any server", background)

        self.assertIn("Review Setup Guide", settings)
        self.assertIn("existingIdentity: existingIdentity", settings)
        self.assertIn("fullScreenCover(item: $onboardingReviewIdentity)", settings)
        self.assertIn("onCancel: { onboardingReviewIdentity = nil }", settings)
        self.assertNotIn("showOnboardingReview", settings)
        self.assertIn("let isReviewingExistingSetup: Bool", view_model)
        self.assertIn("createdIdentity = existingIdentity", view_model)
        self.assertIn("guard !isReviewingExistingSetup else { return }", view_model)
        self.assertNotIn("identityManager.renameIdentity", view_model)
        onboarding_view = source(ONBOARDING_VIEW)
        self.assertGreaterEqual(
            onboarding_view.count("isReadOnly: viewModel.isReviewingExistingSetup"),
            2,
        )
        self.assertIn(".disabled(isReadOnly)", identity)
        self.assertGreaterEqual(connectivity.count(".disabled(isReadOnly)"), 2)
        self.assertIn("if viewModel.isReviewingExistingSetup", onboarding_view)
        self.assertIn("isReadOnly: viewModel.isReviewingExistingSetup", onboarding_view)
        background = source(
            ROOT / "Sources/ColumbaApp/Views/Onboarding/BackgroundDeliveryPage.swift"
        )
        self.assertIn('Text("Continue")', background)
        self.assertIn("WelcomePage(onContinue: { viewModel.nextPage() })", onboarding_view)
        self.assertIn("onCancel?()", onboarding_view)
        self.assertIn('Text("Done")', complete)
        self.assertIn('Text("iOS Notification Permission")', complete)
        self.assertIn('Text("Not Allowed")', permissions)

    def test_onboarding_copy_is_translation_ready(self) -> None:
        catalog_path = ROOT / "Sources/ColumbaApp/Resources/Localizable.xcstrings"
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        strings = catalog["strings"]

        required = {
            "Private messaging without a central account",
            "Choose a Display Name",
            "Select one or more. You can change these later.",
            "Message Alerts",
            "Existing identities and messages will not be duplicated. Conversation details and app settings may be updated from this backup.",
            "Review Setup Guide",
            "Reopen onboarding without deleting your identity or messages.",
            "Internet Relay",
            "RNode Radio",
        }
        self.assertTrue(required.issubset(strings))
        self.assertEqual(catalog["sourceLanguage"], "en")

        project = source(ROOT / "Columba.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("Localizable.xcstrings in Resources"), 2)
        self.assertIn("Localizable.xcstrings */ = {isa = PBXFileReference", project)

        welcome = source(ROOT / "Sources/ColumbaApp/Views/Onboarding/WelcomePage.swift")
        permissions = source(PERMISSIONS_PAGE)
        explainer = source(ROOT / "Sources/ColumbaApp/Views/Components/BackgroundVPNExplainer.swift")
        view_model = source(VIEW_MODEL)
        self.assertIn("LocalizedStringKey, icon: String", welcome)
        self.assertIn("notificationRow(_ text: LocalizedStringKey)", permissions)
        self.assertIn("text: String", explainer)
        self.assertIn("String(localized:", explainer)
        self.assertIn('String(localized: "Internet Relay")', view_model)

        migration_view_model = source(MIGRATION_VIEW_MODEL)
        self.assertIn("guard !isImporting else { return }", migration_view_model)
        self.assertIn("isImporting = true", migration_view_model)
        self.assertIn("defer {", migration_view_model)
        self.assertIn("activeImportGeneration = generation", migration_view_model)
        self.assertIn("guard self?.activeImportGeneration == generation else { return }", migration_view_model)
        self.assertIn("activeExportGeneration = generation", migration_view_model)
        self.assertIn("guard self?.activeExportGeneration == generation else { return }", migration_view_model)
        self.assertNotIn("case exportComplete", migration_view_model)
        self.assertLess(
            migration_view_model.index("activeExportGeneration = nil\n            state = .exporting(progress: 1)"),
            migration_view_model.index("return url"),
        )
        self.assertLess(
            migration_view_model.index("activeImportGeneration = nil\n            state = .importComplete"),
            migration_view_model.index("state = .importComplete"),
        )

        identity_manager = source(IDENTITY_MANAGER)
        migration_importer = source(MIGRATION_IMPORTER)
        self.assertIn("func importIdentityRecord(_ local: LocalIdentity) throws", identity_manager)
        self.assertIn("var merged = Self.loadIdentities()", identity_manager)
        self.assertIn("try saveIdentitiesVerified()", identity_manager)
        self.assertIn("try persistIdentitiesVerified(previous)", identity_manager)
        create_body = identity_manager.split("func createIdentity(displayName: String) throws", 1)[1].split(
            "/// Register restored identity metadata", 1
        )[0]
        self.assertLess(
            create_body.index("try persistIdentitiesVerified(previous)"),
            create_body.index("SecItemDelete(query as CFDictionary)"),
        )
        switch_body = identity_manager.split("func switchToIdentity(_ hash: String) throws", 1)[1].split(
            "// MARK: - Rename", 1
        )[0]
        self.assertIn("let previous = identities", switch_body)
        self.assertIn("try saveIdentitiesVerified()", switch_body)
        self.assertIn("identities = previous", switch_body)
        self.assertIn("try data.write(to: url, options: .atomic)", identity_manager)
        self.assertIn("let persisted = try Data(contentsOf: url)", identity_manager)
        self.assertIn("guard persisted == data", identity_manager)
        self.assertIn("try await identityManager.importIdentityRecord(local)", migration_importer)
        self.assertNotIn("addIdentityRecord", migration_importer)
        self.assertIn("identity.hexHash.lowercased()", migration_importer)
        self.assertIn('appName: "lxmf"', migration_importer)
        self.assertIn('aspects: ["delivery"]', migration_importer)
        self.assertIn("seenHashes.insert(identityHash).inserted", migration_importer)
        self.assertLess(
            migration_importer.index("validateIdentityExports(bundle.identities)"),
            migration_importer.index("onProgress(0.1)"),
        )
        self.assertIn('let account = "identity-\\(validated.identityHash)"', migration_importer)
        self.assertLess(
            migration_importer.index("throw error"),
            migration_importer.index("let conversationsByIdentity"),
        )
        self.assertIn("first(where: { $0.export.isActive })?.identityHash", migration_importer)
        self.assertIn("preferredIdentityHash: preferredIdentityHash", migration_importer)
        self.assertIn("completeRestoredOnboarding(", view_model)
        restored_completion = view_model.split("func completeRestoredOnboarding(", 1)[1].split(
            "// MARK: - Onboarding Check", 1
        )[0]
        self.assertNotIn("createOrResumeIdentity", restored_completion)
        self.assertIn("identityManager.switchToIdentity(local.identityHash)", restored_completion)
        self.assertIn("validateRecordOwnerHashes(", migration_importer)
        self.assertIn("canonicalIdentityHashes: canonicalIdentityHashes", migration_importer)
        self.assertIn("var seenInterfaces = repo.interfaces", migration_importer)
        self.assertIn("seenInterfaces.append(entity)", migration_importer)
        self.assertIn("$0.type == entity.type && $0.mode == entity.mode && $0.config == entity.config", migration_importer)
        self.assertIn("validatedInterfaceMode(_ rawMode: String?)", migration_importer)
        self.assertIn("guard let rawMode else { return .full }", migration_importer)
        self.assertIn("throw MigrationInterfaceValidationError.unsupportedMode(rawMode)", migration_importer)
        self.assertLess(
            migration_importer.index("let validatedInterfaceModes"),
            migration_importer.index("onProgress(0.1)"),
        )

        migration_exporter = source(MIGRATION_EXPORTER)
        migration_data = source(MIGRATION_DATA)
        self.assertIn("mode: iface.mode.rawValue", migration_exporter)
        self.assertIn("let mode: String?", migration_data)
        self.assertIn("mode: String? = nil", migration_data)

    def test_selected_interfaces_are_persisted_for_both_hosts(self) -> None:
        text = source(VIEW_MODEL)
        method = text.split("private func createInterfaces(in repo: InterfaceRepository) {", 1)[1]
        self.assertNotIn("COLUMBA_RUNTIME_", method)
        self.assertIn("for interfaceType in selectedInterfaces", method)
        for case in (".auto", ".nearby", ".ble", ".tcp", ".rnode"):
            self.assertIn(f"case {case}:", method)
        self.assertNotIn("MultipeerConfig", method)

    def test_bluetooth_permission_is_explicit_and_app_does_not_restore_a_second_radio(self) -> None:
        permissions = source(PERMISSIONS_PAGE)
        self.assertIn('Text("Bluetooth")', permissions)
        self.assertIn("Button(action: onRequestBluetooth)", permissions)
        self.assertNotIn("SwiftBLEBridge.shared.restoreAtLaunch()", source(APP_ENTRY))

    def test_radio_is_configured_in_the_selected_host(self) -> None:
        self.assertFalse(MODEL_B_BLE_SERVICE.exists())
        self.assertNotIn("syncModelBBLEService", source(APP_SERVICES))
        dispatcher = source(ROOT / "Sources/RNSHost/NodeCommandDispatcher.swift")
        self.assertIn("SwiftBLEBridge.shared", dispatcher)
        self.assertNotIn("recordUserOptIn", source(VIEW_MODEL))

    def test_shipping_interface_creation_is_idempotent(self) -> None:
        view_model = source(VIEW_MODEL)
        method = view_model.split("private func createInterfaces(in repo: InterfaceRepository) {", 1)[1]
        shipping = method
        self.assertIn("ensureInterfaceEnabled(candidate, in: repo)", shipping)
        self.assertIn("disabled.enabled = true", view_model)
        self.assertIn("repo.updateInterface(disabled)", view_model)
        self.assertIn("existing.mode == candidate.mode", view_model)
        self.assertIn("existing.config == candidate.config", view_model)

    def test_skip_and_restore_use_idempotent_interface_seeding(self) -> None:
        view_model = source(VIEW_MODEL)
        skip = view_model.split("func skipOnboarding(", 1)[1].split("// MARK: - Onboarding Check", 1)[0]
        self.assertIn("seedDefaultTcpInterface(in: InterfaceRepository())", skip)
        self.assertNotIn("seedInterfaces(in: InterfaceRepository())", skip)
        self.assertNotIn("addInterface", skip)
        default_seed = view_model.split("func seedDefaultTcpInterface(", 1)[1].split(
            "private func createInterfaces", 1
        )[0]
        self.assertIn("TcpCommunityServer.defaultServer", default_seed)
        self.assertNotIn("selectedInterfaces", default_seed)
        self.assertNotIn("selectedTcpServer", default_seed)


if __name__ == "__main__":
    unittest.main()
