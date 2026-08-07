from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Sources" / "ColumbaApp"


class BackgroundRefreshWiringContractTests(unittest.TestCase):
    def test_registration_precedes_embedded_python_start(self):
        source = (APP / "App" / "ColumbaApp.swift").read_text()
        registration = source.index("BackgroundPropagationRefreshScheduler.register()")
        python_start = source.index("PythonRuntime.shared.start()")
        self.assertLess(registration, python_start)

    def test_launch_safe_runtime_installs_workflow_outside_root_view_task(self):
        source = (APP / "App" / "ColumbaApp.swift").read_text()
        app_init = source[source.index("struct ColumbaApp: App"):source.index("// MARK: - App Body")]
        root_view = source[source.index("struct RootView: View"):]
        self.assertIn("ColumbaApplicationRuntime.shared.installBackgroundHandler()", app_init)
        self.assertNotIn("BackgroundRefreshTaskCoordinator.shared.installHandler", root_view)

    def test_embedded_backend_start_failure_propagates_to_readiness(self):
        services = (APP / "Services" / "AppServices.swift").read_text()
        start = services[services.index("private func startPythonBackend("):]
        self.assertIn(") async throws {", start[:500])
        self.assertIn("self.backend = nil\n            throw error", start)
        self.assertIn("await backend.stop()", start)
        self.assertIn("self?.backend = nil", start)
        self.assertIn("PropagationNodeRestoreReadiness.validate", start)
        first_start = services.index("private func initializeUnlocked(tcpServerAddress")
        second_start = services.index("private func initializeUnlocked(\n        identity:")
        helper_start = services.index("private func activateInitializationManagers(")
        initialization_paths = (
            services[first_start:second_start],
            services[second_start:helper_start],
        )
        gated_call = (
            "activate: {\n"
            "                self.activateInitializationManagers(propManager)\n"
            "            }"
        )
        for path in initialization_paths:
            self.assertEqual(path.count("InitializationLifecycleActivation.run("), 1)
            self.assertEqual(path.count(gated_call), 1)
            self.assertLess(path.index("startPythonBackend("), path.index(gated_call))
            self.assertNotIn("propManager.startListening()", path)
            self.assertNotIn("propManager.startPeriodicSync()", path)
            self.assertNotIn("announceManager.start()", path)

        self.assertEqual(services.count("activateInitializationManagers(propManager)"), 2)
        helper = services[helper_start:services.index("// MARK: - State Observation")]
        for activation in (
            "propManager.startListening()",
            "propManager.startPeriodicSync()",
            "announceManager.start()",
        ):
            self.assertEqual(helper.count(activation), 1)

    def test_service_initialization_cannot_erase_cold_launch_evidence(self):
        source = (APP / "Services" / "AppServices.swift").read_text()
        self.assertNotIn("DiagLog.clear()", source)

    def test_background_workflow_awaits_shared_initialization_instead_of_polling(self):
        app = (APP / "App" / "ColumbaApp.swift").read_text()
        background = app[
            app.index("private func performBackgroundPropagationSync"):
            app.index("// MARK: - Initialization")
        ]
        self.assertIn("await ensureServicesInitialized()", background)
        self.assertNotIn("for _ in 0..<100", background)

    def test_python_event_drain_starts_only_after_incoming_handler_installation(self):
        app = (APP / "App" / "ColumbaApp.swift").read_text()
        services = (APP / "Services" / "AppServices.swift").read_text()
        delegate_install = app.index("await router.setDelegate(handler)")
        drain_start = app.index("appServices.startPythonEventDrain()")
        self.assertLess(delegate_install, drain_start)

        backend_start = services.index("private func startPythonBackend(")
        drain_method = services.index("func startPythonEventDrain()")
        self.assertNotIn("pythonEventTask = Task", services[backend_start:drain_method])

    def test_scheduling_preserves_an_accepted_pending_request(self):
        source = (APP / "Services" / "BackgroundPropagationSync.swift").read_text()
        schedule = source[
            source.index("static func scheduleFromCurrentSettings") :
            source.index("static func logRuntime")
        ]
        self.assertIn("getPendingTaskRequests", schedule)
        self.assertIn("preserving existing pending request", schedule)
        self.assertNotIn(
            "cancel(taskRequestWithIdentifier: taskIdentifier)\n        guard let delay",
            schedule,
        )

    def test_badge_is_not_cleared_while_durable_unread_rows_remain(self):
        app = (APP / "App" / "ColumbaApp.swift").read_text()
        messaging = (APP / "ViewModels" / "MessagingViewModel.swift").read_text()
        self.assertNotIn("NotificationService.shared.clearBadge()", app)
        self.assertIn("synchronizeBadgeWithDurableUnreadCount", app)
        self.assertIn("synchronizeBadgeWithDurableUnreadCount", messaging)

    def test_built_source_declares_refresh_identifier_and_fetch_mode(self):
        plist = (APP / "Resources" / "Info.plist").read_text()
        self.assertIn("BGTaskSchedulerPermittedIdentifiers", plist)
        self.assertIn("network.columba.Columba.sync", plist)
        self.assertIn("<string>fetch</string>", plist)

    def test_background_sync_uses_immediate_local_notification_and_badge(self):
        notifications = (APP / "Services" / "NotificationService.swift").read_text()
        incoming = (APP / "Services" / "IncomingMessageHandler.swift").read_text()
        self.assertIn("trigger: nil", notifications)
        self.assertIn("content.badge = Self.badgeValue(totalUnreadCount:", notifications)
        self.assertIn("await acquireBadgeMutation()", notifications)
        self.assertIn("messageRepository.totalUnreadCount()", notifications)
        self.assertIn("postNotificationForNewlySyncedMessage", incoming)
        self.assertNotIn("deliveredNotifications().count", notifications)


if __name__ == "__main__":
    unittest.main()
