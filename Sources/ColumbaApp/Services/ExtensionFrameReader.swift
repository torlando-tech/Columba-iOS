//
//  ExtensionFrameReader.swift
//  ColumbaApp
//
//  Reads frames from SharedFrameQueue (written by the Network Extension)
//  and injects them into the transport layer as if they arrived on a local interface.
//
//  Listens for Darwin notifications from the extension to wake and process frames.
//

#if ENABLE_NETWORK_EXTENSION

import Foundation
import RNSAPI
import os.log

/// Reads queued frames from the Network Extension and injects them into transport.
///
/// When the extension receives TCP or Auto data while the app is backgrounded,
/// it writes frames to SharedFrameQueue and posts a Darwin notification.
/// This reader wakes on that notification, reads all queued frames, and delivers
/// them to the appropriate interface delegate (transport).
@available(iOS 17.0, macOS 14.0, *)
public final class ExtensionFrameReader: @unchecked Sendable {

    // MARK: - Properties

    private let frameQueue: SharedFrameQueue
    private let logger = Logger(subsystem: "network.columba.Columba", category: "ExtensionFrameReader")

    /// Callback to inject a TCP frame into transport
    public var onTCPFrameReceived: ((Data) -> Void)?

    /// Callback to inject an Auto frame into transport
    public var onAutoFrameReceived: ((Data) -> Void)?

    // MARK: - Initialization

    public init() {
        self.frameQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier)
    }

    // MARK: - Public API

    /// Start listening for Darwin notifications from the extension.
    public func startListening() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let self_ = Unmanaged<ExtensionFrameReader>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                self_.processQueuedFrames()
            },
            "network.columba.packetReady" as CFString,
            nil,
            .deliverImmediately
        )

        // Also process any frames that accumulated before we started listening
        processQueuedFrames()
    }

    /// Stop listening for Darwin notifications.
    public func stopListening() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center,
            observer,
            CFNotificationName("network.columba.packetReady" as CFString),
            nil
        )
    }

    /// Read all queued frames and deliver to transport.
    public func processQueuedFrames() {
        let frames = frameQueue.readAllAndClear()
        guard !frames.isEmpty else { return }

        logger.info("Processing \(frames.count) queued frame(s) from extension")
        // Bridge diagnostic: frames pulled from the shared queue and about to be
        // injected into transport. Only reached when frames>0 (guard above).
        // NO-PII: frame count only. DiagLog is visible from this module (ColumbaApp).
        DiagLog.log("[BRIDGE-IN] \(frames.count) frame(s) from queue -> transport")

        for frame in frames {
            switch frame.interfaceTag {
            case FrameInterfaceTag.tcp.rawValue:
                onTCPFrameReceived?(frame.data)
            case FrameInterfaceTag.auto.rawValue:
                onAutoFrameReceived?(frame.data)
            default:
                logger.warning("Unknown interface tag: \(frame.interfaceTag)")
            }
        }
    }

    deinit {
        stopListening()
    }
}

#endif
