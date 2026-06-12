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
    public func start(onLinkStateChange: ((RNodeLinkState) -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard server == nil else { return }
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
}
