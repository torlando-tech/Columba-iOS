//
//  AppGroupRNodeSessionTransport.swift
//  Shared
//
//  Production `RNodeSessionSeamWire` for the Model B Python RNode session seam.
//  Rides two dedicated App-Group `SharedFrameQueue`s (so the session control/data
//  stream never intermixes with the reticulum-swift RNode seam or the BLE seam),
//  each woken by its own Darwin notification - the same proven file-lock + notify
//  mechanism the rest of Model B uses.
//
//      role .networkExtension :  send → rnodeSessionSeamN2A (notify N2A) ; inbound ← rnodeSessionSeamA2N (observe A2N)
//      role .app              :  send → rnodeSessionSeamA2N (notify A2N) ; inbound ← rnodeSessionSeamN2A (observe N2A)
//
//  Pure Foundation/CoreFoundation (no ReticulumSwift), so it's unit-testable with
//  two instances in one process looping back through temp-dir-backed queues.
//

import Foundation

public final class AppGroupRNodeSessionTransport: RNodeSessionSeamWire, @unchecked Sendable {

    public enum Role { case networkExtension, app }

    private let sendQueue: SharedFrameQueue
    private let inboundQueue: SharedFrameQueue
    private let sendNotification: String
    private let inboundNotification: String

    private let _inbound: AsyncStream<RNodeSessionSeamMessage>
    private let inboundCont: AsyncStream<RNodeSessionSeamMessage>.Continuation
    private var observerRegistered = false

    public init(role: Role, appGroupIdentifier: String = appGroupIdentifier) {
        switch role {
        case .networkExtension:
            sendQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: SharedFrameQueueName.rnodeSessionSeamN2A)
            inboundQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: SharedFrameQueueName.rnodeSessionSeamA2N)
            sendNotification = SharedDefaultsConstants.rnodeSessionSeamN2ANotificationName
            inboundNotification = SharedDefaultsConstants.rnodeSessionSeamA2NNotificationName
        case .app:
            sendQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: SharedFrameQueueName.rnodeSessionSeamA2N)
            inboundQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier, name: SharedFrameQueueName.rnodeSessionSeamN2A)
            sendNotification = SharedDefaultsConstants.rnodeSessionSeamA2NNotificationName
            inboundNotification = SharedDefaultsConstants.rnodeSessionSeamN2ANotificationName
        }
        (_inbound, inboundCont) = AsyncStream.makeStream(of: RNodeSessionSeamMessage.self)
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
                Unmanaged<AppGroupRNodeSessionTransport>.fromOpaque(observer)
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

    // MARK: RNodeSessionSeamWire

    public func send(_ message: RNodeSessionSeamMessage) {
        sendQueue.append(frame: message.encode(), interfaceTag: FrameInterfaceTag.rnodeControl.rawValue)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(sendNotification as CFString),
            nil, nil, true
        )
    }

    public var inbound: AsyncStream<RNodeSessionSeamMessage> { _inbound }

    /// Drain the inbound queue immediately, bypassing the Darwin-notification
    /// wakeup. Belt-and-suspenders for a missed notification (and the
    /// deterministic hook unit tests drive instead of run-loop timing). Returns
    /// the messages drained (also yielded to `inbound`).
    @discardableResult
    public func drainNow() -> [RNodeSessionSeamMessage] { drainInbound() }

    // MARK: Internals

    @discardableResult
    private func drainInbound() -> [RNodeSessionSeamMessage] {
        var drained: [RNodeSessionSeamMessage] = []
        for frame in inboundQueue.readAllAndClear() {
            guard frame.interfaceTag == FrameInterfaceTag.rnodeControl.rawValue,
                  let message = try? RNodeSessionSeamMessage(decoding: frame.data) else { continue }
            inboundCont.yield(message)
            drained.append(message)
        }
        return drained
    }
}
