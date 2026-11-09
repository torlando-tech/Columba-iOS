"""Exercise production sampler persistence and native autorelease lifetimes on macOS.

COLUMBA_NE_SAMPLER_SOURCE selects an unmodified old/new source snapshot for a
red/green comparison. Location/time adapters add native lifetime sentinels, not
an external pool; production Thread.start(), loop and pool scope remain intact.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SWIFT = r'''
import Foundation
import Darwin

// NSObject + objc_autorelease gives an exact native ownership observation:
// ARC cannot release this retained reference until the worker's pool drains.
final class IterationSentinel: NSObject {
    override init() {
        Replay.created += 1
        super.init()
    }
    deinit { Replay.released += 1 }
}

let appGroupIdentifier = "group.network.columba.Columba"
enum Replay {
    static let warmup: Int64 = 3000
    static let total: Int64 = 21000
    static let stride: Int64 = 300
    static var tick: Int64 = 0
    static var root: URL!
    static var count = 0
    static var getterCalls = 0
    static var created = 0
    static var released = 0
    static var waitProbes = 0
    static var containerProbes = 0
    static var checkedIterations = 0
    static var maxOutstanding = 0
    static let ready = DispatchSemaphore(value: 0)
    static let holdWorker = DispatchSemaphore(value: 0)
    struct Point {
        var tick: Int64 = 0
        var bytes: UInt64 = 0
        var blocks: UInt64 = 0
        var footprint: UInt64 = 0
        var status: Int32 = 0
    }
    static let points: UnsafeMutablePointer<Point> = {
        let p = UnsafeMutablePointer<Point>.allocate(capacity: 61)
        p.initialize(repeating: Point(), count: 61)
        return p
    }()
    static func containerURL() -> URL? {
        getterCalls += 1
        if !Thread.isMainThread && tick > 0 {
            containerProbes += 1
            deferRelease()
        }
        // Keep the actual entitlement lookup, but NEVER write its returned path.
        withExtendedLifetime(FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )) {}
        return root
    }
    static func deferRelease() {
        _ = Unmanaged.passRetained(IterationSentinel()).autorelease()
    }
    static func sleep(forTimeInterval ignored: Double) {
        if tick > 0 {
            // This iteration's pool is open, but no new sentinels exist yet.
            // Every previous wait and persistence operation must have drained.
            checkedIterations += 1
            maxOutstanding = max(maxOutstanding, created - released)
        }
        if tick >= warmup && (tick - Int64(warmup)) % Int64(stride) == 0 {
            var stat = malloc_statistics_t()
            malloc_zone_statistics(nil, &stat)
            let vm = MemoryFootprint.sample()
            points[count] = Point(tick: tick, bytes: UInt64(stat.size_in_use),
                blocks: UInt64(stat.blocks_in_use), footprint: vm.footprint, status: vm.status)
            count += 1
        }
        if tick == total {
            NEMemoryTrace.stopSampling()
            ready.signal()
            // Final sample precedes thread termination or any lifetime pool pop.
            // Patched code has already popped the PREVIOUS iteration's pool.
            holdWorker.wait()
            return
        }
        tick += 1
        waitProbes += 1
        deferRelease()
    }
    static func now() -> Clocks.Now {
        Clocks.Now(wallMs: 1_700_000_000_000 + tick * 1000, uptimeMs: tick * 1000)
    }
}

Replay.root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
_ = Replay.points // Allocate the fixed observation buffer before the worker starts.
setenv("COLUMBA_MEMORY_ATTRIBUTION", "0", 1)
NEMemoryTrace.start()
guard Replay.ready.wait(timeout: .now() + 45) == .success else {
    fputs("sampler did not reach final live-thread checkpoint\n", stderr)
    exit(2)
}
let trace = NEMemoryTrace.readAll()
let samples = (0..<Replay.count).map { index -> [String: Any] in
    let p = Replay.points[index]
    return ["tick": p.tick, "bytes": p.bytes, "blocks": p.blocks,
            "phys_footprint": p.footprint, "task_info_kr": p.status]
}
let report: [String: Any] = [
    "samples": samples, "getter_calls": Replay.getterCalls,
    "stopped_tick": Replay.tick, "warmup": Replay.warmup, "stride": Replay.stride,
    "autoreleased_created": Replay.created, "autoreleased_released": Replay.released,
    "wait_probes": Replay.waitProbes, "container_probes": Replay.containerProbes,
    "checked_iterations": Replay.checkedIterations, "max_outstanding": Replay.maxOutstanding,
    "kinds": trace.records.map { Int($0.kind.rawValue) },
    "bucket_uptimes": trace.records.filter { $0.kind == .bucket }.map { $0.uptimeMs },
    "live_uptime": trace.live?.uptimeMs ?? -1,
    "live_kind": trace.live.map { Int($0.kind.rawValue) } ?? -1
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
// The production worker remains blocked in the wait shim until process exit.
'''


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"Production adapter seam changed: {old!r}")
    return source.replace(old, new, 1)


def adapt(source, sampler):
    source = replace_once(source,
        "FileManager.default.containerURL(\n            forSecurityApplicationGroupIdentifier: appGroupIdentifier\n        )",
        "Replay.containerURL()")
    protection = "[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]"
    source = source.replace(protection, "[:]")
    if sampler:
        source = replace_once(source,
            "let attributes: [FileAttributeKey: Any] = [\n            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication\n        ]",
            "let attributes: [FileAttributeKey: Any] = [:]")
        source = replace_once(source, "Thread.sleep(forTimeInterval: sampleIntervalSeconds)",
                              "Replay.sleep(forTimeInterval: sampleIntervalSeconds)")
        source = replace_once(source,
            """        var time = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &time)
        return Now(
            wallMs: Int64(Date().timeIntervalSince1970 * 1000),
            uptimeMs: Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000
        )""", "        return Replay.now()")
    return source


def slope(points, key):
    mean_x = sum(p["tick"] for p in points) / len(points)
    mean_y = sum(p[key] for p in points) / len(points)
    return sum((p["tick"] - mean_x) * (p[key] - mean_y) for p in points) / sum(
        (p["tick"] - mean_x) ** 2 for p in points)


class NESamplerRetention(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"),
                         "Requires macOS Foundation and Swift compiler")
    def test_actual_sampler_iteration_bounds_native_retention(self):
        sampler = Path(os.environ.get("COLUMBA_NE_SAMPLER_SOURCE",
                                      ROOT / "Sources/Shared/NEMemoryTrace.swift"))
        with tempfile.TemporaryDirectory(prefix="ne-sampler-retention-") as directory:
            directory = Path(directory)
            for name, path in (("NEMemoryTrace", sampler), ("ExtensionDiagLog",
                               ROOT / "Sources/Shared/ExtensionDiagLog.swift")):
                (directory / f"{name}.swift").write_text(adapt(path.read_text(), name == "NEMemoryTrace"))
            (directory / "main.swift").write_text(SWIFT)
            executable = directory / "sampler"
            compiled = subprocess.run(["swiftc", "-swift-version", "5", "-O", "-D", "DEBUG",
                str(directory / "NEMemoryTrace.swift"), str(directory / "ExtensionDiagLog.swift"),
                str(directory / "main.swift"), "-o", str(executable)],
                capture_output=True, text=True, timeout=90)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run([str(executable), str(directory / "group")],
                                 capture_output=True, text=True, timeout=60)
            self.assertEqual(run.returncode, 0, run.stderr)
            report = json.loads(run.stdout)
        points = report["samples"]
        self.assertEqual([p["tick"] for p in points],
                         list(range(report["warmup"], report["stopped_tick"] + 1, report["stride"])))
        self.assertTrue(all(p["task_info_kr"] == 0 for p in points), report)
        stopped = report["stopped_tick"]
        self.assertGreaterEqual(report["getter_calls"], stopped // 5 + 2 * (stopped // 60))
        self.assertEqual(report["kinds"][0], 2)  # Actual start() boot marker.
        self.assertTrue(all(kind == 1 for kind in report["kinds"][1:]))
        buckets = report["bucket_uptimes"]
        self.assertGreaterEqual(len(buckets), stopped // 60)
        self.assertTrue(all(a < b for a, b in zip(buckets, buckets[1:])))
        self.assertGreater(buckets[-1], stopped * 1000 - 60_000)
        self.assertEqual(report["live_kind"], 4)
        self.assertEqual(report["live_uptime"], stopped * 1000)
        metrics = {key: slope(points, key) for key in ("bytes", "blocks", "phys_footprint")}
        print(f"NE sampler postwarmup slopes per virtual 1Hz tick: {metrics}")
        # All-zone malloc includes Foundation/runtime caches outside sampler
        # ownership. Keep it diagnostic, not an allocator-dependent leak verdict.
        self.assertEqual(report["checked_iterations"], stopped)
        self.assertEqual(report["wait_probes"], stopped)
        self.assertGreaterEqual(report["container_probes"], stopped // 5 + 2 * (stopped // 60))
        self.assertEqual(report["autoreleased_created"],
                         report["wait_probes"] + report["container_probes"])
        self.assertEqual(report["max_outstanding"], 0, report)
        self.assertEqual(report["autoreleased_released"], report["autoreleased_created"], report)
