//
//  AppGroupRNodeSeamWire.swift
//  Shared
//
//  Production `RNodeSeamWire` for the Model B RNode serial seam. Rides two dedicated
//  App-Group `SharedFrameQueue`s (separate from the BLE seam + the radio-frame a2e/e2a
//  queues), each woken by its own Darwin notification — the same file-lock + notify
//  mechanism the rest of Model B uses.
//
//      role .networkExtension : send → rnodeSeamN2A (notify N2A) ; inbound ← rnodeSeamA2N (observe A2N)
//      role .app              : send → rnodeSeamA2N (notify A2N) ; inbound ← rnodeSeamN2A (observe N2A)
//
//  Pure Foundation/CoreFoundation (no ReticulumSwift), so it's unit-testable with two
//  instances in one process looping back through temp-dir-backed queues. Mirrors
//  `AppGroupBLESeamTransport`.
//

import Foundation

public final class AppGroupRNodeSeamWire: RNodeSeamWire, @unchecked Sendable {

    public enum Role { case networkExtension, app }

    private let sendQueue: SharedFrameQueue
    private let inboundQueue: SharedFrameQueue
    private let sendNotification: String
    private let inboundNotification: String

    private let _inbound: AsyncStream<RNodeSeamMessage>
    private let inboundCont: AsyncStream<RNodeSeamMessage>.Continuation
    private var observerRegistered = false

    public init(role: Role, appGroupIdentifier: String = appGroupIdentifier) {
        switch role {
        case .networkExtension:
            sendQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: SharedFrameQueueName.rnodeSeamN2A)
            inboundQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: SharedFrameQueueName.rnodeSeamA2N)
            sendNotification = SharedDefaultsConstants.rnodeSeamN2ANotificationName
            inboundNotification = SharedDefaultsConstants.rnodeSeamA2NNotificationName
        case .app:
            sendQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: SharedFrameQueueName.rnodeSeamA2N)
            inboundQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: SharedFrameQueueName.rnodeSeamN2A)
            sendNotification = SharedDefaultsConstants.rnodeSeamA2NNotificationName
            inboundNotification = SharedDefaultsConstants.rnodeSeamN2ANotificationName
        }
        (_inbound, inboundCont) = AsyncStream.makeStream(of: RNodeSeamMessage.self)
    }

    /// Begin observing the inbound queue. Call once after construction. (Separate
    /// from `init` so `self` is fully initialized before the C callback can fire.)
    public func start() {
        guard !observerRegistered else { return }
        observerRegistered = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<AppGroupRNodeSeamWire>.fromOpaque(observer)
                    .takeUnretainedValue()
                    .drainInbound()
            },
            inboundNotification as CFString,
            nil,
            .deliverImmediately
        )
        // Drain anything queued before the observer was registered.
        drainInbound()
    }

    public func stop() {
        guard observerRegistered else { return }
        observerRegistered = false
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(inboundNotification as CFString),
            nil
        )
        inboundCont.finish()
    }

    // MARK: RNodeSeamWire

    public func send(_ message: RNodeSeamMessage) {
        guard sendQueue.append(frame: message.encode(), interfaceTag: FrameInterfaceTag.rnodeControl.rawValue) else {
            ExtensionDiagLog.log("[RNODE] seam wire: append failed — dropped \(message), skipping wakeup")
            return
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(sendNotification as CFString),
            nil, nil, true
        )
    }

    public var inbound: AsyncStream<RNodeSeamMessage> { _inbound }

    /// Drain the inbound queue immediately, bypassing the Darwin-notification wakeup.
    /// Belt-and-suspenders for a missed notification (and the deterministic unit tests).
    @discardableResult
    public func drainNow() -> [RNodeSeamMessage] { drainInbound() }

    // MARK: Internals

    @discardableResult
    private func drainInbound() -> [RNodeSeamMessage] {
        var drained: [RNodeSeamMessage] = []
        for frame in inboundQueue.readAllAndClear() {
            guard frame.interfaceTag == FrameInterfaceTag.rnodeControl.rawValue,
                  let message = try? RNodeSeamMessage(decoding: frame.data) else { continue }
            inboundCont.yield(message)
            drained.append(message)
        }
        return drained
    }
}
