//
//  KeyStampHostSeam.swift
//  Columba Shared
//
//  Key-stamp search offload from the Network Extension to the app.
//
//  A link's stamped key uses the exact-target SHA-256 search in
//  `HostKeyStampSearch`, and on iOS the process that runs it decides the rate:
//  the app hits 32.8k rounds/s per core, while the same kernel inside the NE
//  produced 39.4k rounds/s with four workers (one efficiency core's worth).
//  A cost-18 link stamp therefore took ~7s inside the NE and pushed page
//  fetches into the 20s link timeout. This seam lets the NE's Python ask the
//  app for the keypair and only run the search itself when no host answers.
//
//      NE (`KeyStampHostBridge`)      app (`KeyStampHostService`)
//      start  → keyStampN2A (notify N2A)   drain → accept + search
//      poll   ← keyStampA2N (notify A2N)   result ← (accept, result)
//      cancel → keyStampN2A
//
//  Frames are JSON `KeyStampSeamFrame`s on the dedicated `keyStamp*` queues,
//  so the BLE and radio seams keep their own files and locks. Everything here is
//  Foundation-only (no RNSAPI), because the file is compiled into both targets.
//

import Foundation
import SwiftBLEBridge
import os

/// One seam message. `Data` fields ride as base64 inside the seam's JSON, which
/// keeps a 64-byte keypair and a 32-byte target small enough for a single frame.
struct KeyStampSeamFrame: Codable {
    enum Kind: String, Codable {
        /// NE→app: run this search. Carries `material` and `target`.
        case start
        /// app→NE: the search is queued; the NE may stop waiting for a host.
        case accepted
        /// NE→app: stop the search with this id (the link was cancelled).
        case cancel
        /// app→NE: terminal answer. `status` is the C-ABI poll value
        /// (64 = payload length, -2 = cancelled, -3 = failed).
        case result
    }

    var kind: Kind
    var id: UInt64
    var material: Data?
    var target: Data?
    var payload: Data?
    var rounds: UInt64?
    var status: Int32?

    init(
        kind: Kind,
        id: UInt64,
        material: Data? = nil,
        target: Data? = nil,
        payload: Data? = nil,
        rounds: UInt64? = nil,
        status: Int32? = nil
    ) {
        self.kind = kind
        self.id = id
        self.material = material
        self.target = target
        self.payload = payload
        self.rounds = rounds
        self.status = status
    }

    func encoded() -> Data? {
        // A fresh coder per frame: `JSONEncoder` keeps mutable state and the
        // seam is written from the Python thread, the app worker, and test
        // threads at once.
        try? JSONEncoder().encode(self)
    }

    static func decoded(_ data: Data) -> KeyStampSeamFrame? {
        try? JSONDecoder().decode(KeyStampSeamFrame.self, from: data)
    }
}

enum KeyStampSeamNotify {
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    /// Register `handler` for a Darwin notification. The relay is retained here
    /// until `remove`, because the CF callback keeps only a raw pointer.
    static func observe(_ name: String, owner: AnyObject, handler: @escaping @Sendable () -> Void) {
        let relay = KeyStampNotifyRelay(handler: handler)
        let key = ObjectIdentifier(owner)
        relays.withLock { $0[key] = relay }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(relay).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<KeyStampNotifyRelay>.fromOpaque(observer).takeUnretainedValue().run()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    static func remove(_ name: String, owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        guard let relay = relays.withLock({ $0.removeValue(forKey: key) }) else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(relay).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
    }

    private static let relays = OSAllocatedUnfairLock(
        initialState: [ObjectIdentifier: KeyStampNotifyRelay]()
    )
}

/// Holds the handler a Darwin callback reaches through its raw pointer. The
/// notification can arrive on any thread; the handler is already `@Sendable`,
/// so it is invoked directly rather than hopped to a queue.
final class KeyStampNotifyRelay: @unchecked Sendable {
    private let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func run() { handler() }
}

/// NE side: owns in-flight remote jobs and exports them to Python.
///
/// Python polls every 10ms, so nothing here needs a timer: `poll` drains the
/// answer queue on each call. The one blocking wait is the accept window in
/// `start`, which bounds the cost of asking a suspended app.
final class KeyStampHostBridge: @unchecked Sendable {
    private struct JobState {
        var accepted = false
        var cancelled = false
        var result: (status: Int32, payload: Data?, rounds: UInt64)?
    }

    private struct State {
        var nextID: UInt64 = 1
        var jobs: [UInt64: JobState] = [:]
    }

    /// Longest wait for the app to accept a request before the NE falls back to
    /// its own kernel. The app answers before it starts searching, so this only
    /// covers the Darwin notification hop.
    static let acceptWindow: TimeInterval = 0.12

    static let shared = KeyStampHostBridge()

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let requests: SharedFrameQueue
    private let responses: SharedFrameQueue

    /// Queue names are parameters so a test can drive both seam ends over
    /// private files instead of competing with the live app/NE singletons.
    init(
        requestQueueName: String = SharedFrameQueueName.keyStampN2A,
        responseQueueName: String = SharedFrameQueueName.keyStampA2N
    ) {
        requests = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: requestQueueName)
        responses = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: responseQueueName)
    }

    /// False in the app process (which is the host itself and must use its own
    /// kernel). Read on every start; written once by `disableInProcess`.
    private let enabled = OSAllocatedUnfairLock(initialState: true)

    /// Called by the app's `KeyStampHostService.start()`: in the hosting process
    /// the seam would loop back to the same scheduler, so route Python straight
    /// to the local kernel instead.
    func disableInProcess() {
        state.withLock { $0 = State() }
        enabled.withLock { $0 = false }
    }

    func start(material: Data, target: Data) -> UInt64 {
        guard enabled.withLock({ $0 }), target.count == 32 else { return 0 }
        let id = state.withLock { state -> UInt64 in
            let id = state.nextID
            state.nextID = state.nextID == .max ? 1 : state.nextID + 1
            state.jobs[id] = JobState()
            return id
        }
        guard let frame = KeyStampSeamFrame(
            kind: .start, id: id, material: material, target: target
        ).encoded(), requests.append(frame: frame, interfaceTag: FrameInterfaceTag.keyStamp.rawValue)
        else {
            state.withLock { $0.jobs.removeValue(forKey: id) }
            return 0
        }
        KeyStampSeamNotify.post(SharedDefaultsConstants.keyStampRequestNotificationName)

        let deadline = CFAbsoluteTimeGetCurrent() + Self.acceptWindow
        while CFAbsoluteTimeGetCurrent() < deadline {
            if state.withLock({ $0.jobs[id]?.accepted ?? false }) { return id }
            drainResponses()
            Thread.sleep(forTimeInterval: 0.002)
        }
        // No host answered: drop the request and let the caller run the search
        // in-process. A late accept still finds no job and is discarded.
        state.withLock { $0.jobs.removeValue(forKey: id) }
        return 0
    }

    /// Mirrors `NativeStampJob.poll`: 0 running, 64 = payload copied, -2
    /// cancelled, -3 failed, -1 bad argument.
    func poll(
        _ id: UInt64,
        into out: UnsafeMutablePointer<CChar>,
        capacity: Int,
        rounds: inout UInt64
    ) -> Int32 {
        drainResponses()
        let snapshot = state.withLock { state -> (Int32, UInt64, Data?)? in
            guard let job = state.jobs[id] else { return nil }
            if job.cancelled { return (-2, job.result?.rounds ?? 0, nil) }
            guard let result = job.result else { return (0, 0, nil) }
            return (result.status, result.rounds, result.payload)
        }
        guard let snapshot else { return -1 }
        rounds = snapshot.1
        guard snapshot.0 == 64, let payload = snapshot.2 else { return snapshot.0 }
        guard payload.count <= capacity else { return -1 }
        payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(out, base, payload.count) }
        }
        return Int32(payload.count)
    }

    @discardableResult
    func cancel(_ id: UInt64) -> Bool {
        let known = state.withLock { state -> Bool in
            guard var job = state.jobs[id] else { return false }
            job.cancelled = true
            job.result = nil
            state.jobs[id] = job
            return true
        }
        guard known,
              let frame = KeyStampSeamFrame(kind: .cancel, id: id).encoded()
        else { return known }
        requests.append(frame: frame, interfaceTag: FrameInterfaceTag.keyStamp.rawValue)
        KeyStampSeamNotify.post(SharedDefaultsConstants.keyStampRequestNotificationName)
        return true
    }

    @discardableResult
    func release(_ id: UInt64) -> Bool {
        state.withLock { $0.jobs.removeValue(forKey: id) } != nil
    }

    private func drainResponses() {
        for frame in responses.readAllAndClear() where frame.interfaceTag == FrameInterfaceTag.keyStamp.rawValue {
            guard let message = KeyStampSeamFrame.decoded(frame.data) else { continue }
            state.withLock { state in
                guard var job = state.jobs[message.id] else { return }
                switch message.kind {
                case .accepted:
                    job.accepted = true
                case .result:
                    guard !job.cancelled else { return }
                    job.result = (
                        message.status ?? -3,
                        message.payload,
                        message.rounds ?? 0
                    )
                case .start, .cancel:
                    return
                }
                state.jobs[message.id] = job
            }
        }
    }
}

/// App side: answers the NE's key-stamp jobs on a user-initiated queue.
///
/// One search at a time: page fetches are serial and the kernel already spreads
/// each search over the performance cores, so a second concurrent search would
/// only compete for the same cores.
final class KeyStampHostService: @unchecked Sendable {
    final class CancelFlag: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        var isCancelled: Bool { lock.withLock { $0 } }
        func cancel() { lock.withLock { $0 = true } }
    }

    static let shared = KeyStampHostService()

    private let state = OSAllocatedUnfairLock(
        initialState: [UInt64: CancelFlag]()
    )
    private let requests: SharedFrameQueue
    private let responses: SharedFrameQueue
    private let work: DispatchQueue
    private let pollQueue = DispatchQueue(label: "network.columba.keyStampHost.poll")
    private var started = false
    private var pollTimer: DispatchSourceTimer?

    /// Queue names are parameters so a test can drive both seam ends over
    /// private files instead of competing with the live app/NE singletons.
    init(
        requestQueueName: String = SharedFrameQueueName.keyStampN2A,
        responseQueueName: String = SharedFrameQueueName.keyStampA2N,
        label: String = "network.columba.keyStampHost"
    ) {
        requests = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: requestQueueName)
        responses = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: responseQueueName)
        work = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Start answering NE requests. Called once at app launch. `disableLocalBridge`
    /// is on for the real app, whose Python node stamps faster in-process; tests
    /// that drive both seam ends in one process turn it off.
    func start(disableLocalBridge: Bool = true) {
        guard !started else { return }
        started = true
        if disableLocalBridge {
            KeyStampHostBridge.shared.disableInProcess()
        }
        KeyStampSeamNotify.observe(
            SharedDefaultsConstants.keyStampRequestNotificationName, owner: self
        ) { [weak self] in
            self?.drain()
        }
        // A Darwin notification can be coalesced or miss the observer's
        // registration window, and an unanswered request would park the NE's
        // page fetch; poll the queue as a floor under the notify path.
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        pollTimer = timer
        drain()
    }

    private func drain() {
        for frame in requests.readAllAndClear() where frame.interfaceTag == FrameInterfaceTag.keyStamp.rawValue {
            guard let message = KeyStampSeamFrame.decoded(frame.data) else { continue }
            switch message.kind {
            case .start:
                guard let material = message.material, let target = message.target else { continue }
                begin(id: message.id, material: material, target: target)
            case .cancel:
                state.withLock { $0[message.id] }?.cancel()
            case .accepted, .result:
                continue
            }
        }
    }

    private func begin(id: UInt64, material: Data, target: Data) {
        let flag = CancelFlag()
        let accepted = state.withLock { state -> Bool in
            guard state[id] == nil else { return false }
            state[id] = flag
            return true
        }
        guard accepted,
              let ack = KeyStampSeamFrame(kind: .accepted, id: id).encoded()
        else { return }
        responses.append(frame: ack, interfaceTag: FrameInterfaceTag.keyStamp.rawValue)
        KeyStampSeamNotify.post(SharedDefaultsConstants.keyStampResultNotificationName)

        work.async { [self] in
            let answer = HostKeyStampSearch.run(
                material: material,
                targetBytes: target,
                cancelled: { flag.isCancelled }
            )
            let status: Int32
            let payload: Data?
            var rounds: UInt64 = 0
            if let answer {
                status = Int32(answer.payload.count)
                payload = answer.payload
                rounds = answer.rounds
            } else {
                status = flag.isCancelled ? -2 : -3
                payload = nil
            }
            state.withLock { $0.removeValue(forKey: id) }
            guard let frame = KeyStampSeamFrame(
                kind: .result, id: id, payload: payload, rounds: rounds, status: status
            ).encoded() else { return }
            responses.append(frame: frame, interfaceTag: FrameInterfaceTag.keyStamp.rawValue)
            KeyStampSeamNotify.post(SharedDefaultsConstants.keyStampResultNotificationName)
        }
    }
}

// MARK: - C ABI (bound by `app/rns_bridge.py`)

/// Begin a remote key-stamp search. Zero means no host answered; the caller then
/// runs `columba_key_stamp_job_start` in-process.
@_used
@_cdecl("columba_host_key_stamp_job_start")
public func columba_host_key_stamp_job_start(
    _ material: UnsafePointer<CChar>?,
    _ materialLen: Int32,
    _ target: UnsafePointer<CChar>?,
    _ targetLen: Int32
) -> UInt64 {
    guard let material, materialLen >= 0, let target, targetLen == 32 else { return 0 }
    let targetData = Data(bytes: target, count: 32)
    let materialData = Data(bytes: material, count: Int(materialLen))
    return KeyStampHostBridge.shared.start(material: materialData, target: targetData)
}

/// Same contract as `columba_stamp_job_poll`.
@_used
@_cdecl("columba_host_key_stamp_job_poll")
public func columba_host_key_stamp_job_poll(
    _ jobID: UInt64,
    _ outStamp: UnsafeMutablePointer<CChar>,
    _ capacity: Int32,
    _ rounds: UnsafeMutablePointer<UInt64>
) -> Int32 {
    var roundsValue: UInt64 = 0
    let status = KeyStampHostBridge.shared.poll(
        jobID, into: outStamp, capacity: Int(capacity), rounds: &roundsValue
    )
    rounds.pointee = roundsValue
    return status
}

@_used
@_cdecl("columba_host_key_stamp_job_cancel")
public func columba_host_key_stamp_job_cancel(_ jobID: UInt64) -> Int32 {
    KeyStampHostBridge.shared.cancel(jobID) ? 1 : 0
}

@_used
@_cdecl("columba_host_key_stamp_job_release")
public func columba_host_key_stamp_job_release(_ jobID: UInt64) {
    _ = KeyStampHostBridge.shared.release(jobID)
}
