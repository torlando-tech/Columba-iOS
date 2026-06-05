//
//  AppGroupBLESeamTransport.swift
//  Shared
//
//  Production `BLESeamTransport` for the Model B BLE seam. Rides two dedicated
//  App-Group `SharedFrameQueue`s (so the BLE control/data stream never intermixes
//  with `AppGroupBridgeInterface`'s radio-frame a2e/e2a), each woken by its own
//  Darwin notification — the same proven file-lock + notify mechanism the rest of
//  Model B uses.
//
//      role .networkExtension :  send → bleSeamN2A (notify N2A) ; inbound ← bleSeamA2N (observe A2N)
//      role .app              :  send → bleSeamA2N (notify A2N) ; inbound ← bleSeamN2A (observe N2A)
//
//  Pure Foundation/CoreFoundation (no ReticulumSwift), so it's unit-testable with
//  two instances in one process looping back through temp-dir-backed queues.
//

import Foundation

public final class AppGroupBLESeamTransport: BLESeamTransport, @unchecked Sendable {

    public enum Role { case networkExtension, app }

    private let sendQueue: SharedFrameQueue
    private let inboundQueue: SharedFrameQueue
    private let sendNotification: String
    private let inboundNotification: String

    private let _inbound: AsyncStream<BLEDriverSeamMessage>
    private let inboundCont: AsyncStream<BLEDriverSeamMessage>.Continuation
    private var observerRegistered = false

    public init(role: Role, appGroupIdentifier: String = appGroupIdentifier) {
        switch role {
        case .networkExtension:
            sendQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: SharedFrameQueueName.bleSeamN2A)
            inboundQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: SharedFrameQueueName.bleSeamA2N)
            sendNotification = SharedDefaultsConstants.bleSeamN2ANotificationName
            inboundNotification = SharedDefaultsConstants.bleSeamA2NNotificationName
        case .app:
            sendQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: SharedFrameQueueName.bleSeamA2N)
            inboundQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: SharedFrameQueueName.bleSeamN2A)
            sendNotification = SharedDefaultsConstants.bleSeamA2NNotificationName
            inboundNotification = SharedDefaultsConstants.bleSeamN2ANotificationName
        }
        (_inbound, inboundCont) = AsyncStream.makeStream(of: BLEDriverSeamMessage.self)
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
                Unmanaged<AppGroupBLESeamTransport>.fromOpaque(observer)
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

    // MARK: BLESeamTransport

    public func send(_ message: BLEDriverSeamMessage) {
        sendQueue.append(frame: message.encode(), interfaceTag: FrameInterfaceTag.bleControl.rawValue)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(sendNotification as CFString),
            nil, nil, true
        )
    }

    public var inbound: AsyncStream<BLEDriverSeamMessage> { _inbound }

    /// Drain the inbound queue immediately, bypassing the Darwin-notification
    /// wakeup. Belt-and-suspenders for a missed notification (and the
    /// deterministic hook unit tests drive instead of run-loop timing). Returns
    /// the messages drained (also yielded to `inbound`).
    @discardableResult
    public func drainNow() -> [BLEDriverSeamMessage] { drainInbound() }

    // MARK: Internals

    @discardableResult
    private func drainInbound() -> [BLEDriverSeamMessage] {
        var drained: [BLEDriverSeamMessage] = []
        for frame in inboundQueue.readAllAndClear() {
            guard frame.interfaceTag == FrameInterfaceTag.bleControl.rawValue,
                  let message = try? BLEDriverSeamMessage(decoding: frame.data) else { continue }
            inboundCont.yield(message)
            drained.append(message)
        }
        return drained
    }
}
