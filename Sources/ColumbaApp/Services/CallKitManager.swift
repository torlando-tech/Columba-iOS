//
//  CallKitManager.swift
//  ColumbaApp
//
//  CallKit integration for LXST voice calls. Provides native iOS call UI
//  (lock screen, system call list, audio session management) by bridging
//  CallManager state transitions to CXProvider / CXCallController.
//
//  Guarded with #if os(iOS) since CallKit is iOS-only.
//

import Foundation
import os.log

#if os(iOS)
import CallKit
import AVFoundation

/// Test seam for CallKit invocation.
///
/// Lets `CallManager` collaborate with the system call provider through a
/// protocol the test target can mock. The production conformer is
/// `CallKitManager`; tests inject a recorder. Method names mirror
/// `CallKitManager`'s existing surface so the migration is purely
/// "change the static type of the field".
///
/// Not `@MainActor`-isolated because `CallKitManager` is also not isolated
/// — its CXProviderDelegate callbacks arrive on arbitrary queues, so it
/// dispatches to MainActor only when calling back into CallManager.
@available(iOS 17.0, *)
protocol CallKitReporting: AnyObject {
    func reportIncomingCall(uuid: UUID, peerName: String?, completion: @escaping (Error?) -> Void)
    func updateCallerName(uuid: UUID, name: String)
    func reportOutgoingCall(uuid: UUID)
    func reportCallConnected(uuid: UUID)
    func reportCallEnded(uuid: UUID, reason: CXCallEndedReason)
    func startCall(uuid: UUID, handle: String)
    func answerCall(uuid: UUID)
    func endCall(uuid: UUID)
}

/// Manages CallKit integration for native iOS call handling.
///
/// Responsibilities:
/// - Reports incoming/outgoing calls to the system via CXProvider
/// - Handles CXProviderDelegate callbacks (answer, end, mute)
/// - Manages audio session activation/deactivation
/// - Requests call actions via CXCallController
///
/// This class is NOT @MainActor because CXProviderDelegate callbacks arrive
/// on an arbitrary queue. It dispatches to MainActor when calling back into
/// CallManager.
@available(iOS 17.0, *)
public final class CallKitManager: NSObject, CXProviderDelegate, CallKitReporting {

    // MARK: - Properties

    private let provider: CXProvider
    private let callController: CXCallController
    private let logger = Logger(subsystem: "network.columba.Columba", category: "CallKitManager")

    /// Weak reference back to CallManager for delegate callbacks.
    /// Set after initialization since CallManager creates CallKitManager.
    weak var callManager: CallManager?

    /// The UUID of the currently active call, if any.
    private(set) var activeCallUUID: UUID?

    // MARK: - Initialization

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        // Use a generic ringtone; CallKit handles audio routing
        config.ringtoneSound = nil

        self.provider = CXProvider(configuration: config)
        self.callController = CXCallController()

        super.init()

        provider.setDelegate(self, queue: nil)
        logger.info("CallKitManager initialized")
    }

    deinit {
        provider.invalidate()
    }

    // MARK: - Reporting Calls to the System

    /// Report an incoming call to the system. Shows the native incoming call UI.
    ///
    /// - Parameters:
    ///   - uuid: Unique identifier for this call
    ///   - peerName: Display name for the caller
    ///   - completion: Called with nil on success or an error on failure
    func reportIncomingCall(uuid: UUID, peerName: String?, completion: @escaping (Error?) -> Void) {
        let update = CXCallUpdate()
        update.localizedCallerName = peerName ?? "Unknown Caller"
        update.remoteHandle = CXHandle(type: .generic, value: peerName ?? "unknown")
        update.hasVideo = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = false
        update.supportsDTMF = false

        activeCallUUID = uuid

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error = error {
                DiagLog.log("[CALLKIT] reportIncomingCall FAILED: \(error.localizedDescription)")
                self?.logger.warning("Failed to report incoming call: \(error.localizedDescription)")
                self?.activeCallUUID = nil
            } else {
                DiagLog.log("[CALLKIT] reportIncomingCall OK: \(uuid)")
                self?.logger.info("Reported incoming call: \(uuid)")
            }
            completion(error)
        }
    }

    /// Update the caller name for an active call.
    ///
    /// Used when the caller's identity is resolved after the initial incoming call report.
    ///
    /// - Parameters:
    ///   - uuid: Unique identifier for this call
    ///   - name: Resolved caller name
    func updateCallerName(uuid: UUID, name: String) {
        let update = CXCallUpdate()
        update.localizedCallerName = name
        provider.reportCall(with: uuid, updated: update)
        logger.info("Updated caller name for \(uuid): \(name)")
    }

    /// Report that an outgoing call has started connecting.
    ///
    /// Call this when the user initiates an outgoing call. The system shows
    /// the call UI with a "Calling..." state.
    ///
    /// - Parameter uuid: Unique identifier for this call
    func reportOutgoingCall(uuid: UUID) {
        activeCallUUID = uuid
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
        logger.info("Reported outgoing call started connecting: \(uuid)")
    }

    /// Report that a call has connected (audio is flowing).
    ///
    /// - Parameter uuid: Unique identifier for this call
    func reportCallConnected(uuid: UUID) {
        DiagLog.log("[CALLKIT] reportCallConnected: \(uuid)")
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        logger.info("Reported call connected: \(uuid)")
    }

    /// Report that a call has ended.
    ///
    /// - Parameters:
    ///   - uuid: Unique identifier for this call
    ///   - reason: The CXCallEndedReason describing why the call ended
    func reportCallEnded(uuid: UUID, reason: CXCallEndedReason) {
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        activeCallUUID = nil
        logger.info("Reported call ended: \(uuid), reason: \(reason.rawValue)")
    }

    // MARK: - Requesting Call Actions (User-Initiated)

    /// Request the system to start an outgoing call.
    ///
    /// This goes through CXCallController so the system can coordinate audio
    /// sessions and show the call in the system call log.
    ///
    /// - Parameters:
    ///   - uuid: Unique identifier for this call
    ///   - handle: Display handle for the peer (name or hash)
    func startCall(uuid: UUID, handle: String) {
        let callHandle = CXHandle(type: .generic, value: handle)
        let action = CXStartCallAction(call: uuid, handle: callHandle)
        action.isVideo = false

        let transaction = CXTransaction(action: action)
        callController.request(transaction) { [weak self] error in
            if let error = error {
                self?.logger.warning("Failed to request start call: \(error.localizedDescription)")
            } else {
                self?.logger.info("Requested start call: \(uuid)")
            }
        }
    }

    /// Request the system to answer an incoming call.
    ///
    /// This goes through CXCallController so the system properly activates
    /// the audio session and dismisses the incoming call notification.
    ///
    /// - Parameter uuid: Unique identifier for the call to answer
    func answerCall(uuid: UUID) {
        let action = CXAnswerCallAction(call: uuid)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { [weak self] error in
            if let error = error {
                self?.logger.warning("Failed to request answer call: \(error.localizedDescription)")
                // Fallback: answer directly if CallKit rejects
                Task { @MainActor [weak self] in
                    self?.callManager?.answerFromCallKit()
                }
            } else {
                self?.logger.info("Requested answer call: \(uuid)")
            }
        }
    }

    /// Request the system to end a call.
    ///
    /// - Parameter uuid: Unique identifier for the call to end
    func endCall(uuid: UUID) {
        let action = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { [weak self] error in
            if let error = error {
                self?.logger.warning("Failed to request end call: \(error.localizedDescription)")
            } else {
                self?.logger.info("Requested end call: \(uuid)")
            }
        }
    }

    // MARK: - CXProviderDelegate

    public func providerDidReset(_ provider: CXProvider) {
        DiagLog.log("[CALLKIT] providerDidReset")
        logger.info("Provider did reset")
        activeCallUUID = nil
        // Notify CallManager to clean up any active call state
        Task { @MainActor [weak self] in
            self?.callManager?.handleCallKitReset()
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        DiagLog.log("[CALLKIT] CXStartCallAction: \(action.callUUID)")
        logger.info("CXStartCallAction for: \(action.callUUID)")
        activeCallUUID = action.callUUID

        // Configure audio session before fulfilling
        configureAudioSession()

        // The actual call initiation is done by CallManager before requesting
        // this action, so we just fulfill it.
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        DiagLog.log("[CALLKIT] CXAnswerCallAction: \(action.callUUID)")
        logger.info("CXAnswerCallAction for: \(action.callUUID)")

        // Configure audio session before answering
        configureAudioSession()

        // Dispatch answer to CallManager on MainActor.
        // Use answerFromCallKit() to avoid re-entrant loop back to CallKit.
        Task { @MainActor [weak self] in
            self?.callManager?.answerFromCallKit()
        }

        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        DiagLog.log("[CALLKIT] CXEndCallAction: \(action.callUUID)")
        logger.info("CXEndCallAction for: \(action.callUUID)")

        // Dispatch hangup to CallManager on MainActor
        Task { @MainActor [weak self] in
            self?.callManager?.hangupFromCallKit()
        }

        activeCallUUID = nil
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        DiagLog.log("[CALLKIT] CXSetMutedCallAction: muted=\(action.isMuted)")
        logger.info("CXSetMutedCallAction muted=\(action.isMuted) for: \(action.callUUID)")

        // Sync mute state to CallManager
        Task { @MainActor [weak self] in
            guard let callManager = self?.callManager else { return }
            if callManager.isMuted != action.isMuted {
                callManager.toggleMute()
            }
        }

        action.fulfill()
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        DiagLog.log("[CALLKIT] didActivateAudioSession")
        logger.error("[CALLKIT] didActivateAudioSession — notifying CallManager")
        // Notify CallManager so AudioManager can restart its capture pipeline.
        // For incoming calls, AudioManager.start() runs BEFORE this callback,
        // so the mic input tap gets no data until the session is activated.
        Task { @MainActor [weak self] in
            self?.callManager?.handleAudioSessionActivated()
        }
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        DiagLog.log("[CALLKIT] didDeactivateAudioSession")
        logger.info("Audio session deactivated")
        // Audio session deactivated after call ends.
        deactivateAudioSession()
    }

    // MARK: - Audio Session Management

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Match AudioManager's options exactly to avoid triggering a
            // .categoryChange route notification when AudioManager starts.
            // Speaker routing is handled via overrideOutputAudioPort, not
            // .defaultToSpeaker (which conflicts with .allowBluetoothA2DP).
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true, options: [])
            logger.info("Audio session configured for voice chat")
        } catch {
            logger.warning("Failed to configure audio session: \(error.localizedDescription)")
        }
    }

    private func deactivateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            logger.info("Audio session deactivated")
        } catch {
            logger.warning("Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }
}

#endif
