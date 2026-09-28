//
//  ModelBRNodeSessionService.swift
//  ColumbaApp
//
//  App side of the Model B Python RNode session seam. CoreBluetooth can't run in
//  the Network Extension, so the app owns the real CoreBluetooth NUS radio here:
//  the shipping `PythonRNodeBLESessionRegistry` (ReticulumSwift-free, the same
//  owner the in-app Python backend uses). This service wraps it in a
//  `PythonRNodeSessionDriver` and hands it to an `AppGroupRNodeSessionServer`
//  that relays the NE's `columba_rnode_session_*` commands to the radio and the
//  radio's state / data / failure back over the App-Group seam.
//
//  The driver-level abstraction itself lives in Python (`IOSRNodeDriver`, the
//  Android-parity RNode bridge); nothing here imports reticulum-swift.
//
//  Mirrors `ModelBBLEService`. The radio's `open` is issued by the NE's first
//  `columba_rnode_session_open` command (the Python driver issues it during
//  `IOSRNodeInterface` start), so this side only brings up the seam + poller -
//  it does not pre-connect the CB managers.
//

import Foundation

public final class ModelBRNodeSessionService: @unchecked Sendable {

    public static let shared = ModelBRNodeSessionService()

    private init() {}

    /// True when the RNode host should start: an enabled `.rnode` interface
    /// exists in the repository (created via Manage Interfaces / onboarding).
    /// Gated on the interface list, not a standalone flag. `repo` is injectable
    /// for tests.
    static func shouldStart(repo: InterfaceRepository = InterfaceRepository()) -> Bool {
        repo.getEnabledInterfaces().contains { $0.type == .rnode }
    }

    private let lock = NSLock()
    private var server: AppGroupRNodeSessionServer?

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return server != nil }

    /// GATED (A9, RISK 5): re-arm the app-side RNode session seam early at a
    /// background relaunch so iOS CoreBluetooth state restoration (the registry
    /// transports carry per-device restoration identifiers) can service a
    /// configured RNode without waiting for the NE. OFF by default - the seam
    /// is normally started by `startRNodeInterfaceUnlocked` at the first
    /// `.rnode` interface. Flip after verifying on a physical device that the
    /// background wake is serviced and that the mesh + RNode centrals don't
    /// collide on the shared restore identifier.
    public static let rnodeBackgroundRestoreEnabled = false

    /// Construct + start the session server. Idempotent. Brings up the App-Group
    /// seam transport + the poller; the radio session is opened on the NE's first
    /// `columba_rnode_session_open` (the Python driver issues it).
    /// - Parameter onLinkStateChange: UI-facing sink for the real CoreBluetooth link
    ///   state (drives the Settings "connected" badge). The Python driver in the NE
    ///   is the authoritative RNS interface; this is the app-side proxy.
    public func start(onLinkStateChange: ((RNodeSessionLinkState, String?) -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard server == nil else { return }
        let tx = AppGroupRNodeSessionTransport(role: .app)
        let driver = PythonRNodeSessionDriver()
        let srv = AppGroupRNodeSessionServer(
            transport: tx,
            driver: driver,
            log: { DiagLog.log($0) },
            onLinkStateChange: onLinkStateChange
        )
        srv.start()
        self.server = srv
        DiagLog.log("[RNODE] Model B RNode session service started (PythonRNodeBLESessionRegistry relay)")
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        server?.stop()
        server = nil
        DiagLog.log("[RNODE] Model B RNode session service stopped")
    }

    /// Re-arm the session seam at app launch (incl. a background relaunch for a
    /// preserved CoreBluetooth event) so a configured RNode's radio is listening
    /// when the NE's Python driver issues `open`. Idempotent with `start`. Gated
    /// by `rnodeBackgroundRestoreEnabled` at its call site.
    public func restore() {
        guard RNodeSeamConfig.loadFromAppGroup() != nil else { return }
        start()
        DiagLog.log("[RNODE] Model B RNode session restore requested")
    }
}
