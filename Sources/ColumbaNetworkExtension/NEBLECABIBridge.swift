//
//  NEBLECABIBridge.swift
//  ColumbaNetworkExtension
//
//  NE-side wiring for the in-extension mesh BLE radio.
//
//  After Phase 2 of the NE-is-sole-runtime relocation, the real CoreBluetooth
//  radio (`SwiftBLEBridge`, the same SwiftPM package the app links) is compiled
//  into the NE target. Its `columba_ble_*` C-ABI exports
//  (`Sources/SwiftBLEBridge/BleNativeBindings.swift`) are therefore present in
//  the NE dylib, so the unmodified Python `IOSBLEDriver`
//  (`ctypes.CDLL(None) -> columba_ble_*`) now drives the radio IN-PROCESS, with
//  no App-Group seam. This file no longer defines a forwarder or any
//  `columba_ble_*` symbols (that would duplicate the package's). It has exactly
//  two jobs:
//
//    1. `NEPythonBridgeHook` - the single Swift->Python channel for this
//       process. The NE calls the named `rns_bridge.invoke_ble_callback`
//       function through the embedded interpreter, so the driver's registered
//       callback slots fire exactly as they do in the in-app (Model A) path.
//
//    2. `NEBLECallbackInvoker` - the `BleCallbackInvoker` installed on
//       `SwiftBLEBridge.shared`. It translates each `BleCallbackSlot` the radio
//       emits into the `invoke_ble_callback(slot, address, extra)` payload
//       `rns_bridge` expects (byte fields ride as base64 strings so they
//       survive the JSON serialization). Installed once at NE startup, before
//       the Python driver's first `columba_ble_start`, so early connection
//       events are not lost.
//
//  Return codes / event shapes match the Python driver's contract:
//    - commands: 0 = ok, -1 = not running, -2 = bad arg (handled in the
//      package's BleNativeBindings, not here)
//    - events: the `invoke_ble_callback` extra-dict contract in rns_bridge.py
//

import Foundation
import SwiftBLEBridge

/// The single Swift->Python delivery channel for BLE events in the NE process.
/// `PacketTunnelProvider` wires it once at startup (idempotent); a nil hook
/// degrades event delivery to a no-op (commands still reach the radio in-process;
/// the driver just stops receiving async events). Kept in this file (not
/// SwiftBLEBridge, which is a shared package) because it binds to the NE's
/// `NEPythonRNS` interpreter seam, which the package must not depend on.
final class NEPythonBridgeHook: @unchecked Sendable {
    static let shared = NEPythonBridgeHook()
    private var fn: (@Sendable (String, [String: Any]) -> Void)?
    /// Dedicated serial queue for the Swift->Python hop. The BLE callback
    /// invoker (`NEBLECallbackInvoker.invoke`) runs on SwiftBLEBridge's serial
    /// queue; the Python call it forwards to (`NEPythonRNS.invoke`) grabs the
    /// GIL inside `NEPythonRuntime.callBridge`. Hopping that GIL-blocking call
    /// onto THIS queue means the BLE queue is released immediately instead of
    /// being held while it waits for the GIL - which breaks the AB-BA deadlock
    /// (Issue 6) where a Python worker that holds the GIL waits on the BLE
    /// queue (e.g. `columba_ble_send`) while an incoming BLE event makes the
    /// BLE queue wait for the GIL. One serial queue preserves event ordering
    /// (the BLE queue enqueues in order, this queue drains in order).
    private let pythonQueue = DispatchQueue(label: "network.columba.ne.ble.python")
    /// Node-incarnation counter, guarding stale-event discard (iter-3 finding).
    /// Bumped in `discardPendingEvents()` when a node (re)starts. A BLE event
    /// queued against the OLD node must NOT be delivered to the NEW node's
    /// callbacks - e.g. a stale "peer disconnected" arriving after a restart
    /// would drop a peer that is connected on the new node. Guarded by
    /// `genLock` (the counter is read from the BLE queue at enqueue time and
    /// from pythonQueue at run time, so it needs a lock, not just the queue).
    private let genLock = NSLock()
    private var gen = 0

    func setFn(_ f: @escaping @Sendable (String, [String: Any]) -> Void) { fn = f }

    func invoke(fn: String, object: [String: Any]) {
        // Capture the node incarnation at ENQUEUE time. When the hop runs on
        // pythonQueue, deliver only if the incarnation is unchanged - i.e. no
        // stop/restart happened after this event was queued. A mismatch means
        // the event belongs to a previous node and is dropped.
        genLock.lock()
        let submittedGen = gen
        genLock.unlock()
        pythonQueue.async { [self] in
            genLock.lock()
            let currentGen = self.gen
            genLock.unlock()
            if submittedGen != currentGen {
                // Stale: the node restarted after this BLE event was queued.
                // Drop it so it can't reach the new node's callbacks.
                #if DEBUG
                ExtensionDiagLog.log("[BLE-NE-GEN] dropped stale BLE event (gen \(submittedGen) -> \(currentGen)); slot carried in payload")
                #endif
                return
            }
            self.fn?(fn, object)
        }
    }

    /// Invalidate all BLE events still queued against the previous node
    /// incarnation. Call at the start of a node (re)start so a stale event is
    /// never delivered to the new node's callbacks.
    ///
    /// Two steps, and the order is load-bearing:
    ///   1. DRAIN the radio's serial queue (SwiftBLEBridge) so every delegate
    ///      callback from the previous incarnation has finished handing its
    ///      event to `invoke` (which captures the OLD generation). Without this,
    ///      a delegate still in-flight on the radio queue at restart time would
    ///      capture the NEW generation and be delivered as if it were current -
    ///      the exact "old BLE event reaches the new node" window the generation
    ///      counter alone cannot close.
    ///   2. Bump `gen`. Now every pre-restart event that already sat on
    ///      pythonQueue sees a mismatch when it runs and drops itself.
    /// After both steps, the only events that capture the new generation are
    /// genuinely post-restart ones - the invariant is structural, not timing.
    func discardPendingEvents() {
        SwiftBLEBridge.shared.drainQueue()
        genLock.lock()
        gen &+= 1
        let newGen = gen
        genLock.unlock()
        #if DEBUG
        ExtensionDiagLog.log("[BLE-NE-GEN] node (re)start: drained radio queue, generation -> \(newGen); pending BLE events from the previous incarnation will be dropped")
        #endif
    }

    /// Wire event delivery to the embedded Python interpreter: forward each
    /// event to `rns_bridge.invoke_ble_callback` through the NE's public
    /// `NEPythonRNS.invoke` seam (which serializes the kwargs and calls the
    /// named function through the embedded interpreter). Called once at NE
    /// startup (idempotent).
    static func wireToPython() {
        shared.setFn { fn, kwargs in
            NEPythonRNS.shared.invoke(fn, kwargs: kwargs)
        }
    }
}

/// Translates `SwiftBLEBridge`'s `BleCallbackSlot` invocations into the
/// `invoke_ble_callback(slot, address, extra)` payload delivered to Python
/// through `NEPythonBridgeHook`. Argument decoding mirrors the proven app-side
/// invoker (`ModelBBLEService`'s nested `Invoker`); the only difference is the
/// sink: here it is the NE's Python channel instead of the App-Group seam.
///
/// `invoke` runs on SwiftBLEBridge's serial queue, so events are delivered in
/// order. `invokeBool` is the synchronous duplicate-identity check, which is NOT
/// round-tripped to Python (it would block the BLE serial queue on a Python hop);
/// it returns `false` so the radio always accepts and the driver resolves
/// identity/rotation via the async `on_address_changed` path - the same behavior
/// the app's seam invoker had.
final class NEBLECallbackInvoker: BleCallbackInvoker, @unchecked Sendable {
    static let shared = NEBLECallbackInvoker()

    private init() {}

    func invoke(slot: BleCallbackSlot, args: [Any]) {
        #if DEBUG
        // [BLE-NE-DIAG] Event-out channel log (DEBUG only): proves the in-NE
        // radio is emitting events and the invoker is translating them.
        ExtensionDiagLog.log("[BLE-NE-DIAG] event slot=\(slot.rawValue) args=\(args.count)")
        #endif
        let str: (Any?) -> String = { v in
            switch v {
            case let s as String: return s
            case let n as NSNumber: return n.stringValue
            default: return ""
            }
        }
        let int: (Any?) -> Int = { v in
            switch v {
            case let n as Int: return n
            case let n as NSNumber: return n.intValue
            case let d as Double: return Int(d)
            default: return 0
            }
        }
        switch slot {
        case .onDeviceDiscovered:
            // [address, name, rssi, serviceUUIDs]
            let address = args.count > 0 ? str(args[0]) : ""
            let name = args.count > 1 ? str(args[1]) : ""
            let rssi = args.count > 2 ? int(args[2]) : 0
            let serviceUUIDs = args.count > 3 ? (args[3] as? [String] ?? []) : []
            NEPythonBridgeHook.shared.invoke(
                fn: "invoke_ble_callback",
                object: [
                    "slot": slot.rawValue,
                    "address": address,
                    "extra": ["name": name, "rssi": rssi, "service_uuids": serviceUUIDs],
                ]
            )
        case .onDeviceConnected:
            // [address, peerIdentity]
            let address = args.count > 0 ? str(args[0]) : ""
            let identity = args.count > 1 ? (args[1] as? Data) : nil
            var extra: [String: Any] = [:]
            if let identity { extra["identity_b64"] = identity.base64EncodedString() }
            NEPythonBridgeHook.shared.invoke(
                fn: "invoke_ble_callback",
                object: ["slot": slot.rawValue, "address": address, "extra": extra]
            )
        case .onDeviceDisconnected:
            // [address]
            let address = args.count > 0 ? str(args[0]) : ""
            NEPythonBridgeHook.shared.invoke(
                fn: "invoke_ble_callback",
                object: ["slot": slot.rawValue, "address": address, "extra": [:]]
            )
        case .onDataReceived:
            // [address, value]
            let address = args.count > 0 ? str(args[0]) : ""
            let data = args.count > 1 ? (args[1] as? Data ?? Data()) : Data()
            NEPythonBridgeHook.shared.invoke(
                fn: "invoke_ble_callback",
                object: [
                    "slot": slot.rawValue,
                    "address": address,
                    "extra": ["data_b64": data.base64EncodedString()],
                ]
            )
        case .onMtuNegotiated:
            // [address, mtu]
            let address = args.count > 0 ? str(args[0]) : ""
            let mtu = args.count > 1 ? int(args[1]) : 0
            NEPythonBridgeHook.shared.invoke(
                fn: "invoke_ble_callback",
                object: [
                    "slot": slot.rawValue,
                    "address": address,
                    "extra": ["mtu": mtu],
                ]
            )
        case .onIdentityReceived:
            // [address, identityHex]
            let address = args.count > 0 ? str(args[0]) : ""
            let identityHex = args.count > 1 ? str(args[1]) : ""
            NEPythonBridgeHook.shared.invoke(
                fn: "invoke_ble_callback",
                object: [
                    "slot": slot.rawValue,
                    "address": address,
                    "extra": ["identity_hex": identityHex],
                ]
            )
        case .onAddressChanged:
            // [oldAddress, address, identityHex]
            let oldAddress = args.count > 0 ? str(args[0]) : ""
            let newAddress = args.count > 1 ? str(args[1]) : ""
            let identityHash = args.count > 2 ? str(args[2]) : ""
            NEPythonBridgeHook.shared.invoke(
                fn: "invoke_ble_callback",
                object: [
                    "slot": slot.rawValue,
                    "address": newAddress,
                    "extra": [
                        "old_address": oldAddress,
                        "new_address": newAddress,
                        "identity_hash": identityHash,
                    ],
                ]
            )
        case .onDuplicateIdentityDetected:
            // Synchronous bool check - not round-tripped (see class docs).
            break
        case .onError:
            // [severity, message]
            let severity: String = args.count > 0 ? str(args[0]) : "info"
            // Radio status text (the radio routes its info messages through
            // this slot too, severity "info"); only warnings/errors are logged.
            let detail: String = args.count > 1 ? str(args[1]) : ""
            if severity != "info" {
                ExtensionDiagLog.log("[BLE-NE-ERR] severity=\(severity) msg=\(detail)")
            }
            NEPythonBridgeHook.shared.invoke(
                fn: "invoke_ble_callback",
                object: [
                    "slot": slot.rawValue,
                    "address": "",
                    "extra": ["severity": severity, "message": detail],
                ]
            )
        }
    }

    /// Synchronous duplicate-identity check. Not round-tripped to Python (would
    /// block the BLE serial queue on a Python hop). Return false so the radio
    /// always accepts; the driver resolves rotation via async on_address_changed.
    func invokeBool(slot: BleCallbackSlot, args: [Any]) -> Bool { false }
}

extension NEBLECallbackInvoker {
    /// Install the invoker on the in-extension radio + force-link the package's
    /// `columba_ble_*` C-ABI into the NE dylib. Idempotent. Called once at NE
    /// startup (after `NEPythonBridgeHook.wireToPython()`), before the Python
    /// driver issues its first `columba_ble_start`, so the radio's event
    /// callback is live from the first connection.
    static func install() {
        // Force the package's BleNativeBindings out of the static archive so the
        // `@_cdecl columba_ble_*` exports (driven by the NE's Python driver via
        // CDLL(None)) are present in this dylib.
        columbaBLEForceLinkNativeBindings()
        SwiftBLEBridge.shared.setCallbackInvoker(NEBLECallbackInvoker.shared)
        ExtensionDiagLog.log("[BLE-NE] in-process radio callback invoker installed (no seam)")
        #if DEBUG
        // [BLE-NE-DIAG] Periodic radio-state probe (DEBUG only): log the
        // radio's own view of itself (started + connected peers + peer
        // details) every 15s for a bounded 12-iteration window. If the radio
        // is silently failing to advertise or a peer bonds but never produces
        // events, this is the first signal.
        Task {
            let b = SwiftBLEBridge.shared
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                let peers = b.getConnectedPeers()
                let details = b.getConnectionDetails()
                ExtensionDiagLog.log("[BLE-NE-DIAG] started=\(b.isStarted) peers=\(peers.count) detail=\(details.count)")
            }
        }
        #endif
    }
}
