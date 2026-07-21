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
    def test_connectivity_page_is_flavor_specific(self) -> None:
        text = source(CONNECTIVITY_PAGE)
        self.assertIn("@Binding var selectedInterfaces: Set<OnboardingInterfaceType>", text)
        conditional = re.search(
            r"(?ms)#if COLUMBA_RUNTIME_MODEL_B\s+(?P<model_b>.*?)"
            r"#else\s+(?P<shipping>.*?)#endif",
            text,
        )
        self.assertIsNotNone(conditional, "connectivity UI must branch by runtime flavor")
        assert conditional is not None
        model_b = conditional.group("model_b")
        shipping = conditional.group("shipping")
        self.assertIn('Text("Choose a relay")', model_b)
        self.assertNotIn("OnboardingInterfaceType.allCases", model_b)
        self.assertIn('Text("How will you connect?")', shipping)
        self.assertIn("OnboardingInterfaceType.allCases.filter { $0 != .nearby }", shipping)
        self.assertNotIn("ForEach(OnboardingInterfaceType.allCases,", shipping)
        self.assertIn("interfaceCard(type)", shipping)
        self.assertIn("if selectedInterfaces.contains(.tcp)", shipping)
        self.assertIn("selectedInterfaces.insert(type)", text)
        self.assertIn("selectedInterfaces.remove(type)", text)
        self.assertIn("if type == .ble", text)
        self.assertNotIn("if type == .rnode", text)

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

        restore_parent = text.split("OnboardingRestoreSheet(viewModel: vm)", 1)[1].split(
            "#endif", 1
        )[0]
        self.assertNotIn("try?", restore_parent)
        self.assertLess(
            restore_parent.index("try await viewModel.completeRestoredOnboarding"),
            restore_parent.index("showRestoreSheet = false"),
        )
        self.assertLess(
            restore_parent.index("showRestoreSheet = false"),
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
        self.assertIn("app settings may be updated", restore)
        self.assertNotIn("Your traffic isn't sent to any server", background)

        self.assertIn("Review Setup Guide", settings)
        self.assertIn("existingIdentity: existingIdentity", settings)
        self.assertIn("onCancel: { showOnboardingReview = false }", settings)
        self.assertIn("let isReviewingExistingSetup: Bool", view_model)
        self.assertIn("createdIdentity = existingIdentity", view_model)
        self.assertIn("identityManager.renameIdentity", view_model)

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
        self.assertEqual(project.count("Localizable.xcstrings in Resources"), 4)
        self.assertIn("Localizable.xcstrings */ = {isa = PBXFileReference", project)

        welcome = source(ROOT / "Sources/ColumbaApp/Views/Onboarding/WelcomePage.swift")
        permissions = source(PERMISSIONS_PAGE)
        explainer = source(ROOT / "Sources/ColumbaApp/Views/Components/BackgroundVPNExplainer.swift")
        view_model = source(VIEW_MODEL)
        self.assertIn("LocalizedStringKey, icon: String", welcome)
        self.assertIn("notificationRow(_ text: LocalizedStringKey)", permissions)
        self.assertIn("text: LocalizedStringKey", explainer)
        self.assertIn('String(localized: "Internet Relay")', view_model)

        migration_view_model = source(MIGRATION_VIEW_MODEL)
        self.assertIn("guard !isImporting else { return }", migration_view_model)
        self.assertIn("isImporting = true", migration_view_model)
        self.assertIn("defer {", migration_view_model)
        self.assertIn("activeImportGeneration = generation", migration_view_model)
        self.assertIn("guard self?.activeImportGeneration == generation else { return }", migration_view_model)
        self.assertIn("activeExportGeneration = generation", migration_view_model)
        self.assertIn("guard self?.activeExportGeneration == generation else { return }", migration_view_model)
        self.assertLess(
            migration_view_model.index("activeExportGeneration = nil\n            state = .exportComplete"),
            migration_view_model.index("state = .exportComplete"),
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

    def test_shipping_interfaces_are_persisted_but_model_b_only_seeds_relay(self) -> None:
        text = source(VIEW_MODEL)
        self.assertIn("var selectedInterfaces: Set<OnboardingInterfaceType> = [.tcp]", text)
        method = text.split("private func createInterfaces(in repo: InterfaceRepository) {", 1)[1]
        conditional = re.search(
            r"(?ms)#if COLUMBA_RUNTIME_MODEL_B\s+(?P<model_b>.*?)"
            r"#else\s+(?P<shipping>.*?)#endif",
            method,
        )
        self.assertIsNotNone(conditional, "interface persistence must branch by runtime flavor")
        assert conditional is not None
        model_b = conditional.group("model_b")
        shipping = conditional.group("shipping")
        self.assertIn("selectedTcpServer ?? TcpCommunityServer.defaultServer", model_b)
        self.assertNotIn("for interfaceType in selectedInterfaces", model_b)
        self.assertIn("for interfaceType in selectedInterfaces", shipping)
        for case in (".auto", ".nearby", ".ble", ".tcp", ".rnode"):
            self.assertIn(f"case {case}:", shipping)
        nearby = shipping.split("case .nearby:", 1)[1].split("case .ble:", 1)[0]
        self.assertIn("candidate = nil", nearby)
        self.assertNotIn("MultipeerConfig", shipping)

    def test_bluetooth_permission_is_explicit_and_model_b_card_is_not_shipping_ui(self) -> None:
        permissions = source(PERMISSIONS_PAGE)
        self.assertRegex(
            permissions,
            r"(?s)#if COLUMBA_RUNTIME_MODEL_B\s+"
            r"// Bluetooth permission card.*?Text\(\"Bluetooth\"\).*?#endif",
        )

        app = source(APP_ENTRY)
        restore = "SwiftBLEBridge.shared.restoreAtLaunch()"
        self.assertEqual(1, app.count(restore))
        restore_offset = app.index(restore)
        guard_offset = app.rfind("if ", 0, restore_offset)
        guard = app[guard_offset:restore_offset]
        self.assertIn("getEnabledInterfaces()", guard)
        self.assertIn(".ble", guard)

    def test_model_b_ble_service_requires_explicit_opt_in(self) -> None:
        service = source(MODEL_B_BLE_SERVICE)
        view_model = source(VIEW_MODEL)
        app_services = source(APP_SERVICES)
        settings = source(SETTINGS_VIEW)

        self.assertIn('userOptInKey = "model_b_ble_user_opt_in"', service)
        self.assertIn("recordUserOptIn()", view_model)
        self.assertIn("ModelBBLEService.isUserOptedIn", view_model)
        self.assertIn("shouldStart(in:", service)
        self.assertNotIn("CBCentralManager.authorization", service)
        self.assertIn("ModelBBLEService.recordUserOptIn()", settings)
        self.assertIn("ModelBBLEService.clearUserOptIn()", settings)
        self.assertIn('Text("Bluetooth Mesh")', settings)
        start = "ModelBBLEService.shared.start(identityHash: identity.hash)"
        self.assertEqual(1, app_services.count(start))
        start_offset = app_services.index(start)
        guard_offset = app_services.rfind("if ", 0, start_offset)
        guard = app_services[guard_offset:start_offset]
        self.assertIn("ModelBBLEService.shouldStart", guard)
        shutdown = app_services.split("public func shutdown() async {", 1)[1].split(
            "// MARK:", 1
        )[0]
        self.assertIn("ModelBBLEService.shared.stop()", shutdown)

    def test_shipping_interface_creation_is_idempotent(self) -> None:
        view_model = source(VIEW_MODEL)
        method = view_model.split("private func createInterfaces(in repo: InterfaceRepository) {", 1)[1]
        shipping = method.split("#else", 1)[1].split("#endif", 1)[0]
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
