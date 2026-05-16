import Foundation

/// Minimum-viable Python-backed RNS backend for iOS. Wraps `PythonBridge`
/// (the raw CPython embedding) and exposes the small surface Columba's
/// existing AppServices/LXMRouter call into:
///
/// - `start(...)` boots Reticulum + LXMRouter under embedded CPython.
/// - `sendOpportunistic(destHashHex:content:)` posts opportunistic LXMF
///   messages via Python's `LXMF.LXMRouter.handle_outbound`.
/// - `events` is an `AsyncStream<PythonBridge.Event>` that yields announce
///   and inbound-message events drained from the Python-side queue every
///   200ms. The first `events` subscription starts the drain loop.
///
/// This is the iOS analogue of Columba Android's
/// `rns-backend-py/PythonRnsBackend.kt`, collapsed into a single class
/// for the first-light milestone. Sub-protocol split (`core/lxmf/...`)
/// is deferred until basic round-trip is verified.
@available(iOS 17.0, macOS 14.0, *)
public final class PythonRNSBackend: @unchecked Sendable {
    public struct StartParams: Sendable {
        public let configDir: String
        public let identityPath: String
        public let displayName: String
        public let identityBytes: Data?

        public init(
            configDir: String,
            identityPath: String,
            displayName: String,
            identityBytes: Data? = nil
        ) {
            self.configDir = configDir
            self.identityPath = identityPath
            self.displayName = displayName
            self.identityBytes = identityBytes
        }
    }

    private let bridge = PythonBridge()
    private var eventDrainTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<PythonBridge.Event>.Continuation?

    public private(set) var localInfo: PythonBridge.LocalInfo?

    /// Stream of announce/inbound/state events from Python. First subscription
    /// implicitly starts the drain loop.
    public lazy var events: AsyncStream<PythonBridge.Event> = {
        AsyncStream { continuation in
            self.eventContinuation = continuation
            self.startDrainLoop()
            continuation.onTermination = { _ in
                self.eventDrainTask?.cancel()
                self.eventDrainTask = nil
            }
        }
    }()

    public init() {}

    @discardableResult
    public func start(_ params: StartParams) async throws -> PythonBridge.LocalInfo {
        let info = try await bridge.start(
            configDir: params.configDir,
            identityPath: params.identityPath,
            displayName: params.displayName,
            identityBytes: params.identityBytes
        )
        self.localInfo = info
        _ = self.events  // ensure drain loop running even with no subscriber
        return info
    }

    public func stop() async {
        eventDrainTask?.cancel()
        eventDrainTask = nil
        do { try await bridge.stop() } catch {}
        localInfo = nil
    }

    public func sendOpportunistic(destHashHex: String, content: String) async throws -> PythonBridge.SendOutcome {
        try await bridge.sendOpportunistic(destHashHex: destHashHex, content: content)
    }

    /// Single-shot status probe — proxies `bridge.status()` so AppServices can
    /// log RNS Transport state (interface list, online flags, traffic counters)
    /// for smoke-test diagnosis. Returns `nil` if the JSON round-trip fails
    /// (Python error, decode error, or the bridge hasn't started yet).
    public func statusSnapshot() async -> PythonBridge.StatusSnapshot? {
        await bridge.status()
    }

    private func startDrainLoop() {
        guard eventDrainTask == nil else { return }
        eventDrainTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let events = await self.bridge.drainEvents()
                for event in events {
                    self.eventContinuation?.yield(event)
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
        }
    }
}
