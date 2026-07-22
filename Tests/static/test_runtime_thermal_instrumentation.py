import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
APP_SERVICES = ROOT / "Sources/ColumbaApp/Services/AppServices.swift"
COMPAT = ROOT / "Sources/RNSAPI/Compat.swift"


class RuntimeThermalInstrumentationContractTests(unittest.TestCase):
    def setUp(self):
        self.app = APP_SERVICES.read_text(encoding="utf-8")
        self.compat = COMPAT.read_text(encoding="utf-8")

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
        # Both initialization entry points clear the diagnostic log and must start
        # a fresh monitoring generation; shutdown must emit a final sample and stop.
        self.assertEqual(
            self.app.count("RuntimeActivityMonitor.shared.start()"),
            2,
        )
        shutdown = self.app.index("public func shutdown() async")
        self.assertIn(
            "RuntimeActivityMonitor.shared.stop()",
            self.app[shutdown:],
        )

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
        perf_line = re.search(r'let line = "\[PERF\].*?\n', monitor)
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
