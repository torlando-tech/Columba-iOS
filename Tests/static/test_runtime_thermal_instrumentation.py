import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
APP_SERVICES = ROOT / "Sources/ColumbaApp/Services/AppServices.swift"
COMPAT = ROOT / "Sources/RNSAPI/Compat.swift"
PROJECT = ROOT / "Columba.xcodeproj/project.pbxproj"


class RuntimeThermalInstrumentationContractTests(unittest.TestCase):
    def setUp(self):
        self.app = APP_SERVICES.read_text(encoding="utf-8")
        self.compat = COMPAT.read_text(encoding="utf-8")
        self.project = PROJECT.read_text(encoding="utf-8")

    def test_monitor_samples_cpu_and_thermal_state_at_low_frequency(self):
        self.assertIn("final class RuntimeActivityMonitor", self.app)
        self.assertIn("ProcessInfo.thermalStateDidChangeNotification", self.app)
        self.assertIn("getrusage(RUSAGE_SELF", self.app)
        self.assertIn("timer.schedule(deadline: .now() + 15, repeating: 15)", self.app)
        self.assertRegex(
            self.app,
            r'\[PERF\].*thermal=.*cpu_pct=.*announce_total=.*path_writes=',
        )

    def test_monitor_lifecycle_tracks_runtime_lifecycle(self):
        # Every initialization/reconnect operation gets an independent lease.
        # Failure releases only the operation lease; success retains at most one
        # instance lease, shutdown releases it, and reconnect reacquires.
        self.assertIn("func acquire() -> Lease", self.app)
        self.assertIn("func release(_ lease: Lease)", self.app)
        self.assertIn("private let runtimeActivityMonitorLeaseHolder = RuntimeActivityMonitorLeaseHolder()", self.app)
        self.assertIn("private func retainRuntimeActivityMonitorLease", self.app)
        self.assertEqual(
            self.app.count("let monitorLease = RuntimeActivityMonitor.shared.acquire()"),
            3,
        )
        self.assertEqual(
            self.app.count("retainRuntimeActivityMonitorLease(monitorLease)"),
            3,
        )
        self.assertEqual(
            self.app.count("RuntimeActivityMonitor.shared.release(monitorLease)"),
            3,
        )
        self.assertEqual(self.app.count("\n        initializationSucceeded = true\n"), 2)
        self.assertIn("reinitializationSucceeded = true", self.app)
        self.assertIn("deinit {", self.app)
        self.assertIn("RuntimeActivityMonitor.shared.release(lease)", self.app)
        self.assertIn("private var activeGeneration: UInt64?", self.app)
        self.assertIn('emitSample(reason: "periodic", generation: generation)', self.app)
        self.assertIn('emitSample(reason: "thermal_change", generation: generation)', self.app)
        shutdown = self.app.index("public func shutdown() async")
        shutdown_body = self.app[shutdown:]
        self.assertIn("releaseRuntimeActivityMonitorLease()", shutdown_body)

    def test_app_services_lifecycle_operations_are_serialized(self):
        self.assertIn("private var lifecycleOperationActive = false", self.app)
        self.assertIn("private var lifecycleOperationWaiters: [CheckedContinuation<Void, Never>] = []", self.app)
        self.assertIn("func withLifecycleOperation", self.app)
        gated_public_signatures = [
            "public func initialize(tcpServerAddress:",
            "public func initialize(identity:",
            "public func switchIdentity(",
            "public func applyInterfaceChanges()",
            "public func startAutoInterface(",
            "public func stopAutoInterface()",
            "public func startBLEInterface()",
            "public func stopBLEInterface()",
            "public func startMPCInterface()",
            "public func stopMPCInterface()",
            "public func startRNodeInterface(",
            "public func stopRNodeInterface()",
            "public func disconnectBLEPeer(",
            "public func shutdown()",
            "public func connectTCPInterface(",
            "public func stopTCPInterface(entityId:",
            "public func stopTCPInterface()",
            "public func reconnectTCPOnly(",
            "public func reconnect(tcpServerAddress:",
        ]
        for signature in gated_public_signatures:
            start = self.app.index(signature)
            self.assertIn("withLifecycleOperation", self.app[start:start + 700], signature)

        guarded_start_signatures = [
            "public func startAutoInterface(",
            "public func startBLEInterface()",
            "public func startMPCInterface()",
            "public func startRNodeInterface(",
            "public func connectTCPInterface(",
            "public func reconnectTCPOnly(",
        ]
        for signature in guarded_start_signatures:
            start = self.app.index(signature)
            self.assertIn(
                "requireActiveRuntimeForInterfaceMutation()",
                self.app[start:start + 700],
                signature,
            )

        self.assertIn("private func shutdownUnlocked() async", self.app)
        self.assertIn("private func reconnectUnlocked(tcpServerAddress: String) async throws", self.app)
        self.assertIn("private func switchIdentityUnlocked", self.app)
        reconnect_start = self.app.index("private func reconnectUnlocked")
        reconnect_end = self.app.index("private func reinitializeConnection", reconnect_start)
        reconnect = self.app[reconnect_start:reconnect_end]
        self.assertIn("await shutdownUnlocked()", reconnect)
        self.assertNotIn("await shutdown()", reconnect)
        switch_start = self.app.index("private func switchIdentityUnlocked")
        switch_end = self.app.index("// MARK: - State Observation", switch_start)
        switch = self.app[switch_start:switch_end]
        self.assertIn("await shutdownUnlocked()", switch)
        self.assertIn("try await initializeUnlocked(", switch)
        self.assertNotIn("await shutdown()", switch)
        self.assertNotIn("try await initialize(identity:", switch)

        shutdown_start = self.app.index("private func shutdownUnlocked() async")
        shutdown_end = self.app.index("public func connectTCPInterface(", shutdown_start)
        shutdown = self.app[shutdown_start:shutdown_end]
        for nested_public_call in [
            "await stopTCPInterface()",
            "await stopRNodeInterface()",
            "await stopBLEInterface()",
            "await stopAutoInterface()",
        ]:
            self.assertNotIn(nested_public_call, shutdown)

        self.assertIn("private func applyInterfaceChangesUnlocked() async", self.app)
        self.assertIn("private func startAutoInterfaceUnlocked", self.app)
        self.assertIn("private func startBLEInterfaceUnlocked", self.app)
        self.assertIn("private func startMPCInterfaceUnlocked", self.app)
        self.assertIn("private func startRNodeInterfaceUnlocked", self.app)
        self.assertIn("private func connectTCPInterfaceUnlocked", self.app)

    def test_lease_regressions_are_wired_into_both_native_test_targets(self):
        self.assertTrue((ROOT / "Tests/ColumbaAppTests/RuntimeActivityMonitorLeaseTests.swift").is_file())
        self.assertEqual(
            self.project.count("RuntimeActivityMonitorLeaseTests.swift in Sources"),
            4,
        )

    def test_last_lease_release_invalidates_callbacks_before_final_sample(self):
        stop_start = self.app.index("func release(_ lease: Lease)")
        stop_end = self.app.index("func recordAnnounce", stop_start)
        stop = self.app[stop_start:stop_end]
        self.assertIn("activeLeases.remove(lease)", stop)
        self.assertIn("guard activeLeases.isEmpty", stop)
        self.assertIn("activeGeneration = nil", stop)
        self.assertIn("timer.setEventHandler {}", stop)
        self.assertIn("timer.cancel()", stop)
        self.assertIn("NotificationCenter.default.removeObserver(observer)", stop)
        self.assertIn("DiagLog.log(finalLine)", stop)
        self.assertLess(stop.index("timer.cancel()"), stop.index("DiagLog.log(finalLine)"))
        self.assertLess(
            stop.index("NotificationCenter.default.removeObserver(observer)"),
            stop.index("DiagLog.log(finalLine)"),
        )
        emit_start = self.app.index("private func emitSample(")
        emit_end = self.app.index("private func makeSampleLineLocked", emit_start)
        emit = self.app[emit_start:emit_end]
        self.assertLess(emit.index("DiagLog.log(line)"), emit.rindex("lock.unlock()"))

    def test_announce_sources_are_aggregated_without_raw_interface_logging(self):
        self.assertRegex(
            self.app,
            r"recordAnnounce\(\s*interfaceName: interfaceName,\s*"
            r"configuredType: configuredType\s*\)",
        )
        self.assertIn("expectedSectionName(for: $0) == interfaceName", self.app)
        monitor_start = self.app.index("final class RuntimeActivityMonitor")
        monitor_end = self.app.index("// MARK: -", monitor_start)
        monitor = self.app[monitor_start:monitor_end]
        for category in ("announce_tcp", "announce_ble", "announce_auto", "announce_other"):
            self.assertIn(category, monitor)
        perf_line = re.search(r'(?:let line = |return )"\[PERF\].*?\n', monitor)
        self.assertIsNotNone(perf_line)
        assert perf_line is not None
        self.assertNotIn("interfaceName", perf_line.group(0))

    def test_path_table_reports_exact_sqlite_persistence_duration(self):
        insert_start = self.compat.index("public func insert(_ entry: PathEntry)")
        insert_end = self.compat.index("/// Stream of path-table updates", insert_start)
        insert = self.compat[insert_start:insert_end]
        self.assertIn("PathInsertMetrics", insert)
        self.assertIn("persistStart", insert)
        self.assertIn("persist(entry)", insert)
        self.assertIn("persistenceDurationMilliseconds", insert)
        self.assertRegex(
            self.app,
            r"recordPathTableWrite\(\s*durationMilliseconds:\s*"
            r"metrics\.persistenceDurationMilliseconds\s*\)",
        )


if __name__ == "__main__":
    unittest.main()
