//
//  ModelBRNodeService.swift
//  ColumbaApp
//
//  App side of the Model B RNode seam. CoreBluetooth can't run in the Network
//  Extension, so the app hosts the REAL reticulum-swift `BLETransport` (the RNode NUS
//  radio) via an `AppGroupRNodeServer` that bridges it to the NE's `RNodeInterface`
//  over the App-Group (the NE drives connect/send/disconnect via the seam; this side
//  runs the radio + forwards received bytes + state back).
//
//  Parallels `ModelBBLEService`. The server lazily creates the `BLETransport` on the
//  NE's first `connect` command, so this just needs to be running whenever the RNode
//  is enabled. Under Model B this REPLACES the legacy `SwiftRNodeBridge` + the
//  app-local `RNodeInterface` as the app's RNode CoreBluetooth owner.
//

import Foundation

public final class ModelBRNodeService: @unchecked Sendable {

    public static let shared = ModelBRNodeService()
    private init() {}

    private let lock = NSLock()
    private var wire: AppGroupRNodeSeamWire?
    private var server: AppGroupRNodeServer?

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return server != nil }

    /// Construct + start the App-Group RNode server. Idempotent. The server begins
    /// observing the seam and creates the real `BLETransport` on the NE's first
    /// `connect` command.
    /// GATED (A9, RISK 5): drives `restore()` at App launch. OFF until background-relaunch
    /// behavior + the shared CoreBluetooth restore identifier (mesh vs RNode central) are
    /// verified on a physical device. Flip to true after that verification.
    public static let rnodeBackgroundRestoreEnabled = false

    public func start(onLinkStateChange: ((RNodeLinkState, String?) -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let srv = server {
            // Already running (e.g. an App-launch restore started us before AppServices
            // could supply the callback) — (re)wire the callback so link-state updates
            // still reach the UI, then return. Without this the guarded early-return would
            // silently drop the callback on the second start().
            if onLinkStateChange != nil { srv.onLinkStateChange = onLinkStateChange }
            return
        }
        let w = AppGroupRNodeSeamWire(role: .app)
        let srv = AppGroupRNodeServer(wire: w, log: { DiagLog.log($0) })
        srv.onLinkStateChange = onLinkStateChange
        srv.start()
        self.wire = w
        self.server = srv
        DiagLog.log("[RNODE] Model B RNode service started (AppGroupRNodeServer)")
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        server?.stop()
        wire = nil
        server = nil
        DiagLog.log("[RNODE] Model B RNode service stopped")
    }

    /// Re-materialize the RNode radio at app launch (incl. a background relaunch for a
    /// preserved CoreBluetooth event) from the persisted device name, so iOS honors state
    /// restoration and a configured RNode reconnects without waiting for the NE. Idempotent
    /// with `connectRadio`'s per-deviceName cache — the NE's later `.connect` reuses the
    /// same central. Call site is GATED (see `rnodeBackgroundRestoreEnabled`).
    public func restore() {
        guard let deviceName = RNodeSeamConfig.loadFromAppGroup()?.deviceName,
              !deviceName.isEmpty else { return }
        start()  // ensure the server is observing the seam (callback wired later by AppServices)
        lock.lock(); let srv = server; lock.unlock()
        srv?.restoreRadio(deviceName: deviceName)
        DiagLog.log("[RNODE] Model B RNode radio restore requested for '\(deviceName)'")
    }
}
