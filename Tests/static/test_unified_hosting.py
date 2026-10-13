"""Execute the production host seam without requiring an iOS runtime."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class UnifiedHostingContracts(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler unavailable")
    def test_production_command_storage_and_ownership_contracts(self):
        sources = [
            "Sources/Shared/ProxyIPC.swift",
            "Sources/Shared/OutboxEntry.swift",
            "Sources/Shared/NodeHostingMode.swift",
            "Sources/Shared/NodeStateMigration.swift",
            "Sources/RNSHost/NodeProcessLease.swift",
            "Sources/RNSHost/NodePythonBundleLayout.swift",
            "Tests/host-contracts/main.swift",
        ]
        with tempfile.TemporaryDirectory() as directory:
            executable = str(Path(directory) / "host-contracts")
            subprocess.run(["swiftc", *(str(ROOT / s) for s in sources), "-o", executable], check=True, capture_output=True, text=True)
            result = subprocess.run([executable], check=True, capture_output=True, text=True)
            self.assertIn("Host contracts passed", result.stdout)

    def test_extension_omits_app_only_background_modes(self):
        import plistlib
        extension = plistlib.loads((ROOT / 'Sources/ColumbaNetworkExtension/Info.plist').read_bytes())
        self.assertNotIn('UIBackgroundModes', extension)
        app = plistlib.loads((ROOT / 'Sources/ColumbaApp/Resources/Info.plist').read_bytes())
        self.assertIn('bluetooth-central', app['UIBackgroundModes'])
        self.assertIn('bluetooth-peripheral', app['UIBackgroundModes'])

    def test_discovery_entry_uses_shared_backend_and_navigation(self):
        source = (ROOT / 'Sources/ColumbaApp/Views/Settings/InterfaceManagementScreen.swift').read_text()
        entry = source.split('private var discoveryEntryCard:')[1].split('} label:')[0]
        self.assertIn('onOpenDiscoveredInterfaces()', entry)
        summary = source.split('private func refreshDiscoverySummary()')[1].split('guard let snapshot')[0]
        self.assertIn('await appServices.backend?.core.discovery()', summary)

    def test_transport_toggle_restarts_node_and_reports_deferred_changes(self):
        source = (ROOT / 'Sources/ColumbaApp/Views/Settings/SettingsView.swift').read_text()
        toggle = source.split('private func transportModeCard')[1].split('// MARK: - Background Transport Card')[0]
        self.assertIn('await appServices.restartPythonBackend()', toggle)
        self.assertIn('case .requiresRelaunch:', toggle)
        self.assertNotIn('setTransportEnabled(', toggle)

    def test_periodic_retrieval_is_owned_by_shared_node(self):
        source = (ROOT / 'Sources/RNSHost/PythonNodeEngine.swift').read_text()
        self.assertIn('if restarting { armPropagationSync() }', source)
        self.assertIn('propagationSyncTask?.cancel()', source)
        worker = source.split('private func performScheduledPropagationSync')[1].split('@discardableResult')[0]
        self.assertIn('guard !Task.isCancelled, isRunning', worker)
        self.assertIn('PropagationSeamConfig.loadFromAppGroup()', worker)
        self.assertIn('schedule.shouldSync(config: config, now: Date())', worker)
        self.assertIn('propagationSync(timeout: 20.0)', worker)
        self.assertNotIn('call("set_propagation_node"', worker)
        self.assertIn('publishSuccessfulResult(Self.dict(from: result))', source)
        dispatcher = (ROOT / 'Sources/RNSHost/NodeCommandDispatcher.swift').read_text()
        self.assertIn('engine.propagationSync(timeout: timeout)', dispatcher)

    def test_simulator_install_has_only_simctl_arguments(self):
        workflow = (ROOT / '.github/workflows/tests.yml').read_text()
        installs = [line for line in workflow.splitlines() if 'simctl install' in line]
        self.assertTrue(installs)
        for line in installs:
            self.assertNotIn('--allow-empty-simulator-entitlements', line)
        self.assertIn('"$SHIPPING_APP" --allow-empty-simulator-entitlements', workflow)

    def test_sync_history_refreshes_visible_and_resumed_settings(self):
        manager = (ROOT / 'Sources/ColumbaApp/Services/PropagationNodeManager.swift').read_text()
        preferences = manager.split('public func savePreferences()')[1].split('private func publishPropagationSeam')[0]
        self.assertNotIn('setLastSyncTimestamp', preferences)
        view = (ROOT / 'Sources/ColumbaApp/Views/Settings/SettingsView.swift').read_text()
        self.assertIn('NotificationObserver.propagationSyncStateChangedInApp', view)
        self.assertIn('if phase == .active { viewModel?.refreshSyncState() }', view)
        model = (ROOT / 'Sources/ColumbaApp/ViewModels/SettingsViewModel.swift').read_text()
        refresh = model.split('public func refreshSyncState()')[1].split('/// Copy identity')[0]
        self.assertIn('propManager.refreshLastSyncTime()', refresh)

    def test_shared_payload_anchor_is_set_before_python_initialization(self):
        source = (ROOT / 'Sources/RNSHost/PythonNodeRuntime.swift').read_text()
        self.assertIn('NodePythonBundleLayout.resourceBundleURL(for: Bundle.main.bundleURL)', source)
        self.assertLess(source.index('ColumbaNEPy_PyConfig_SetExecutable'), source.index('PyConfig_Read(&config)'))
        self.assertNotIn('Bundle.main.resourcePath', source)

    def test_cloud_checks_the_archived_distribution_layout(self):
        import os
        hook = ROOT / 'ci_scripts/ci_post_xcodebuild.sh'
        source = hook.read_text()
        self.assertIn('verify-flavor-artifact.py" unified', source)
        self.assertIn('codesign --verify --deep --strict', source)
        self.assertIn('$CI_ARCHIVE_PATH/Products/Applications/ColumbaApp.app', source)
        environment = os.environ.copy()
        environment.pop('CI_ARCHIVE_PATH', None)
        subprocess.run(['bash', str(hook)], env=environment, check=True, capture_output=True)
        environment['CI_ARCHIVE_PATH'] = '/nonexistent/Columba.xcarchive'
        result = subprocess.run(['bash', str(hook)], env=environment, capture_output=True)
        self.assertNotEqual(result.returncode, 0, 'missing archive must not silently pass validation')
