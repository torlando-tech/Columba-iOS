import Foundation

/// Snapshot of what a backend implementation supports, observed by the UI
/// to gate features that are kotlin-only or python-only.
///
/// Structured as a tree (one sub-record per feature area) rather than a
/// flat boolean bag so that grouping forces "which family does this
/// belong to" thinking at the call site, and groups of related
/// capabilities can grow without touching unrelated code.
///
/// Surfaced as an `AsyncSequence<BackendCapabilities>` on the root
/// `RNSBackend` — observable so runtime-mutable capabilities (interface
/// status changes, etc.) propagate to the UI without a re-bind.
///
/// Mirrors `BackendCapabilities.kt` in Columba Android's `rns-api`.
/// Identical shape; the iOS port drops the `@Parcelize` annotation
/// because Swift modules don't cross an AIDL boundary.
public struct BackendCapabilities: Equatable, Sendable {
    public let backendId: BackendID
    public let versions: Versions
    public let interfaces: InterfaceCaps
    public let telemetry: TelemetryCaps
    public let performance: PerformanceCaps

    public init(
        backendId: BackendID,
        versions: Versions,
        interfaces: InterfaceCaps,
        telemetry: TelemetryCaps,
        performance: PerformanceCaps
    ) {
        self.backendId = backendId
        self.versions = versions
        self.interfaces = interfaces
        self.telemetry = telemetry
        self.performance = performance
    }

    /// Versions of the underlying protocol libraries. Co-located with
    /// capability flags so the About screen reads them in one call instead
    /// of four. `nil` means the library isn't shipped on this backend
    /// (e.g., LXST has no canonical Python equivalent today).
    public struct Versions: Equatable, Sendable {
        public let reticulum: String?
        public let lxmf: String?
        public let lxst: String?
        public let bleReticulum: String?

        public init(reticulum: String?, lxmf: String?, lxst: String?, bleReticulum: String?) {
            self.reticulum = reticulum
            self.lxmf = lxmf
            self.lxst = lxst
            self.bleReticulum = bleReticulum
        }
    }

    /// Interface management capabilities. The kotlin backend can
    /// hot-reload RNS interface configs without restarting the protocol
    /// stack; the python backend needs a full restart (~5–10s outage), so
    /// the UI surfaces an explicit "Apply & Restart" button instead of
    /// applying silently.
    ///
    /// `hotReloadInterfaces` is a single boolean rather than a tri-state
    /// because every realistic implementation either applies live or
    /// requires a restart — there is no "unsupported" state where
    /// interface changes have no path to take effect at all.
    public struct InterfaceCaps: Equatable, Sendable {
        public let hotReloadInterfaces: Bool
        public let degradationHint: String?

        public init(hotReloadInterfaces: Bool, degradationHint: String? = nil) {
            self.hotReloadInterfaces = hotReloadInterfaces
            self.degradationHint = degradationHint
        }
    }

    /// Telemetry collector host-mode capabilities. The python backend
    /// ships upstream LXMF's well-tested `FIELD_TELEMETRY_STREAM` encoder;
    /// the kotlin backend uses lxmf-kt's reimplementation. If a parity test
    /// fails, the kotlin flag downgrades to `.experimental` — no UI change
    /// required beyond rendering a "Beta" pill.
    public struct TelemetryCaps: Equatable, Sendable {
        public let collectorHostMode: Support
        public let storeOwnTelemetry: Support
        public let allowedRequestersFilter: Support
        public let degradationHint: String?

        public init(
            collectorHostMode: Support,
            storeOwnTelemetry: Support,
            allowedRequestersFilter: Support,
            degradationHint: String? = nil
        ) {
            self.collectorHostMode = collectorHostMode
            self.storeOwnTelemetry = storeOwnTelemetry
            self.allowedRequestersFilter = allowedRequestersFilter
            self.degradationHint = degradationHint
        }
    }

    /// Performance-tuning capabilities that aren't strictly protocol
    /// concerns. `batteryProfileTuning` adjusts BLE scan intervals,
    /// multicast lock acquisition, and AutoInterface aggressiveness — only
    /// the kotlin backend has the hooks. `sharedInstanceAvailabilityChecks`
    /// lets the UI detect when a co-located rnsd shared instance is
    /// present.
    public struct PerformanceCaps: Equatable, Sendable {
        public let batteryProfileTuning: Support
        public let sharedInstanceAvailabilityChecks: Bool

        public init(batteryProfileTuning: Support, sharedInstanceAvailabilityChecks: Bool) {
            self.batteryProfileTuning = batteryProfileTuning
            self.sharedInstanceAvailabilityChecks = sharedInstanceAvailabilityChecks
        }
    }

    /// Tri-state per-feature support indicator.
    ///
    /// - `full`: feature is implemented and ready for production use.
    /// - `unsupported`: feature is not implemented; UI should hide or
    ///   replace the entry point with an unavailable-notice.
    /// - `experimental`: feature is implemented but not yet
    ///   trust-validated. UI should render with a "Beta" indicator.
    public enum Support: String, Equatable, Sendable {
        case full
        case unsupported
        case experimental
    }

    /// Which backend implementation is bound. The UI uses this for
    /// informational purposes (About screen, debug tooling); behavior
    /// gates should test specific capability flags rather than branching
    /// on backend identity, so the seam can grow new backends without
    /// churning UI code.
    public enum BackendID: String, Equatable, Sendable {
        case pythonEmbedded   // iOS-only: BeeWare Python-Apple-support + canonical RNS
        case swiftNative      // native reticulum-swift / LXMF-swift / LXST-swift
    }

    /// Sentinel snapshot returned before a backend binding has been
    /// established (e.g., from the early seed of an `AsyncSequence`
    /// observer between `RNSBackend` construction and `initialize()`
    /// completing). Every capability is the safe-default; UI code that
    /// gates on a capability before the first real snapshot lands behaves
    /// as though the backend can't honour it, which is correct: there is
    /// no backend.
    public static let unknown: BackendCapabilities = BackendCapabilities(
        backendId: .pythonEmbedded,
        versions: .init(reticulum: nil, lxmf: nil, lxst: nil, bleReticulum: nil),
        interfaces: .init(hotReloadInterfaces: false),
        telemetry: .init(
            collectorHostMode: .unsupported,
            storeOwnTelemetry: .unsupported,
            allowedRequestersFilter: .unsupported
        ),
        performance: .init(
            batteryProfileTuning: .unsupported,
            sharedInstanceAvailabilityChecks: false
        )
    )
}
