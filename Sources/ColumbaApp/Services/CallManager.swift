//
//  CallManager.swift
//  ColumbaApp
//
//  Observable bridge between SwiftUI and the LXSTSwift Telephone actor.
//  Manages call state, controls, duration timing, and audio pipeline for the UI layer.
//

import AVFoundation
import Foundation
import LXMFSwift
import LXSTSwift
import ReticulumSwift
import os.log

#if os(iOS)
import CallKit
#endif

/// UI-facing call state (simplified from LXSTSwift's CallState).
enum UICallState: Equatable {
    case idle
    case calling        // Outgoing, waiting for response
    case ringing        // Incoming or remote ringing
    case connecting
    case established
    case ended(String)  // Reason string for display
    case busy
}

/// Observable call manager bridging SwiftUI to the Telephone actor.
///
/// All properties are @MainActor for direct SwiftUI binding. Async work
/// is dispatched to the Telephone actor via Task blocks.
@available(macOS 14.0, iOS 17.0, *)
@Observable
@MainActor
public final class CallManager {
    // MARK: - Observable State

    var callState: UICallState = .idle
    var isMuted: Bool = false
    var isSpeakerOn: Bool = false
    var isPttMode: Bool = false
    var isPttActive: Bool = false
    var callDuration: TimeInterval = 0
    var peerName: String?
    var peerHash: String?
    var isIncoming: Bool = false

    // MARK: - Audio

    /// Audio capture/playback manager. Created when a call is established,
    /// torn down when the call ends.
    private(set) var audioManager: AudioManager?

    /// The active telephony profile for the current call (determines codec/sample rate).
    private(set) var activeProfile: TelephonyProfile = .qualityMedium

    // MARK: - CallKit

    #if os(iOS)
    /// CallKit manager for native iOS call integration (lock screen UI, audio routing).
    /// Created lazily on first use. nil on non-iOS platforms.
    private(set) var callKitManager: CallKitManager?
    #endif

    /// UUID for the currently active call, used by CallKit to track the call.
    private(set) var currentCallUUID: UUID?

    /// Flag to prevent re-entrant hangup when CallKit triggers CXEndCallAction.
    private var isHangingUpFromCallKit = false

    // MARK: - Internal

    private var telephone: Telephone?
    private var transport: ReticuLumTransport?
    private var pathTable: PathTable?
    private var database: LXMFDatabase?
    private var durationTask: Task<Void, Never>?
    private var endedDismissTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.columba.app", category: "CallManager")

    // MARK: - Initialization

    /// Initialize the Telephone actor with identity, transport, and path table.
    ///
    /// This method:
    /// 1. Creates the Telephone actor (which registers its destination with transport)
    /// 2. Registers a destination link callback so incoming links are routed to Telephone
    /// 3. Wires up ringing/established/ended callbacks for UI state updates
    func initialize(identity: Identity, transport: ReticuLumTransport, pathTable: PathTable?, database: LXMFDatabase?) async {
        self.pathTable = pathTable
        self.transport = transport
        self.database = database
        let phone = await Telephone(identity: identity, transport: transport)
        self.telephone = phone

        // Set decoded audio callback so remote audio frames reach AudioManager
        await phone.setDecodedAudioCallback { [weak self] samples, rate, channels in
            await MainActor.run {
                self?.playReceivedAudio(samples)
            }
        }

        // Track negotiated profile so startAudio() uses the right codec parameters.
        // PREFERRED_PROFILE arrives before ESTABLISHED, so activeProfile is correct
        // by the time establishedCallback fires and startAudio() is called.
        await phone.setProfileNegotiatedCallback { [weak self] profile in
            await MainActor.run {
                self?.activeProfile = profile
                self?.logger.error("[CALL] Profile negotiated: \(profile.displayName, privacy: .public)")
            }
        }

        // Register destination link callback with transport so incoming links
        // to the LXST telephony destination are routed to our Telephone actor.
        // Without this, the transport accepts LINKREQUESTs and establishes links
        // but never notifies the Telephone about them.
        let telephonyDest = await phone.destination
        self.telephonyDestination = telephonyDest
        let telephonyDestHash = telephonyDest.hash
        let hexPrefix = telephonyDestHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        logger.error("[CALL] Registering LXST link callback for dest \(hexPrefix, privacy: .public)")

        await transport.registerDestinationLinkCallback(for: telephonyDestHash) { [weak self] (link: Link) async in
            guard let self else { return }
            await MainActor.run {
                self.handleIncomingLink(link)
            }
        }

        await phone.setRingingCallback { [weak self] remoteIdentity in
            await MainActor.run {
                guard let self else { return }
                self.peerHash = remoteIdentity.hexHash
                self.callState = .ringing
                self.logger.error("[CALL] Ringing from: \(remoteIdentity.hexHash, privacy: .public)")

                // Resolve contact name for incoming calls
                if self.isIncoming {
                    self.resolveContactName(remoteIdentity: remoteIdentity)
                }

                // Report outgoing call connecting state to CallKit
                #if os(iOS)
                if !self.isIncoming, let uuid = self.currentCallUUID {
                    self.callKitManager?.reportOutgoingCall(uuid: uuid)
                }
                #endif
            }
        }

        await phone.setEstablishedCallback { [weak self] remoteIdentity in
            await MainActor.run {
                guard let self else { return }
                self.callState = .established
                self.startDurationTimer()
                self.startAudio()
                self.logger.error("[CALL] Established with: \(remoteIdentity.hexHash, privacy: .public)")

                // Report call connected to CallKit
                #if os(iOS)
                if let uuid = self.currentCallUUID {
                    self.callKitManager?.reportCallConnected(uuid: uuid)
                }
                #endif
            }
        }

        await phone.setEndedCallback { [weak self] remoteIdentity, reason in
            await MainActor.run {
                guard let self else { return }
                self.stopAudio()
                self.stopDurationTimer()
                let reasonText: String
                switch reason {
                case .localHangup: reasonText = "Call Ended"
                case .remoteHangup: reasonText = "Call Ended"
                case .rejected: reasonText = "Declined"
                case .busy: reasonText = "Busy"
                case .ringTimeout: reasonText = "No Answer"
                case .connectTimeout: reasonText = "Connection Failed"
                case .linkClosed: reasonText = "Connection Lost"
                }
                if reason == .busy {
                    self.callState = .busy
                } else {
                    self.callState = .ended(reasonText)
                }
                self.logger.error("[CALL] Ended: \(reasonText, privacy: .public)")

                // Report call ended to CallKit
                #if os(iOS)
                if let uuid = self.currentCallUUID {
                    let ckReason = Self.callKitEndReason(from: reason)
                    self.callKitManager?.reportCallEnded(uuid: uuid, reason: ckReason)
                }
                #endif

                // Auto-reset to idle after delay
                self.endedDismissTask?.cancel()
                self.endedDismissTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    self?.resetState()
                }
            }
        }

        // Initialize CallKit on iOS
        #if os(iOS)
        let ckManager = CallKitManager()
        ckManager.callManager = self
        self.callKitManager = ckManager
        logger.info("CallKit integration enabled")
        #endif

        logger.error("[CALL] CallManager initialized")
    }

    // MARK: - Call Actions

    /// Initiate an outgoing call to a destination hash.
    ///
    /// On iOS, this registers the call with CallKit before initiating the
    /// Telephone signaling, so the system shows the call in the native UI.
    func initiateCall(destinationHash: Data, profile: TelephonyProfile = .qualityMedium, peerDisplayName: String?) {
        guard let telephone else {
            logger.warning("Cannot call: Telephone not initialized")
            return
        }

        self.isIncoming = false
        self.peerName = peerDisplayName
        self.peerHash = destinationHash.map { String(format: "%02x", $0) }.joined()
        self.callState = .calling
        self.activeProfile = profile

        // Generate a UUID for CallKit tracking
        let callUUID = UUID()
        self.currentCallUUID = callUUID

        // Register outgoing call with CallKit
        #if os(iOS)
        let handle = peerDisplayName ?? peerHash ?? "unknown"
        callKitManager?.startCall(uuid: callUUID, handle: handle)
        #endif

        Task {
            do {
                // We need the remote identity to call. Look it up from the path table
                // by resolving the destination hash to a known identity.
                let destHex = destinationHash.map { String(format: "%02x", $0) }.joined()
                self.logger.error("[CALL] resolveIdentity for dest \(destHex, privacy: .public)")
                guard let remoteIdentity = await resolveIdentity(for: destinationHash) else {
                    self.logger.error("[CALL] resolveIdentity FAILED — peer not in path table")
                    await MainActor.run {
                        self.callState = .ended("Peer not found")
                        self.endedDismissTask?.cancel()
                        self.endedDismissTask = Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(1.5))
                            guard !Task.isCancelled else { return }
                            self?.resetState()
                        }
                    }
                    return
                }
                self.logger.error("[CALL] resolveIdentity OK, calling Telephone.call()")
                try await telephone.call(remoteIdentity: remoteIdentity, profile: profile)
            } catch {
                await MainActor.run {
                    self.callState = .ended("Call Failed")
                    self.logger.error("[CALL] Call initiation failed: \(error.localizedDescription, privacy: .public)")
                    self.endedDismissTask?.cancel()
                    self.endedDismissTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1.5))
                        guard !Task.isCancelled else { return }
                        self?.resetState()
                    }
                }
            }
        }
    }

    /// Answer an incoming call.
    func answerCall() {
        guard let telephone else { return }
        Task {
            await telephone.answer()
        }
    }

    /// Hang up the current call.
    ///
    /// On iOS, routes through CallKit so the system UI is updated.
    /// If CallKit is not available or the hangup originates from CallKit
    /// (via CXEndCallAction), calls Telephone.hangup() directly.
    func hangup() {
        guard let telephone else { return }

        #if os(iOS)
        // If this hangup was triggered by CallKit's CXEndCallAction, go
        // directly to Telephone to avoid a re-entrant loop.
        if isHangingUpFromCallKit {
            isHangingUpFromCallKit = false
            Task {
                await telephone.hangup()
            }
            return
        }

        // Route through CallKit so the system call UI is dismissed.
        // CXEndCallAction will call back into hangupFromCallKit().
        if let uuid = currentCallUUID {
            callKitManager?.endCall(uuid: uuid)
            return
        }
        #endif

        // Fallback: direct hangup (no CallKit or no UUID)
        Task {
            await telephone.hangup()
        }
    }

    /// Called by CallKitManager when the system requests ending the call
    /// (CXEndCallAction). Performs the actual Telephone hangup without
    /// re-entering CallKit.
    func hangupFromCallKit() {
        guard let telephone else { return }
        isHangingUpFromCallKit = true
        hangup()
    }

    /// Called by CallKitManager when the provider is reset (e.g., system
    /// force-stops all calls). Cleans up any active call state.
    func handleCallKitReset() {
        logger.info("CallKit provider reset — cleaning up call state")
        stopAudio()
        stopDurationTimer()
        endedDismissTask?.cancel()
        currentCallUUID = nil
        if callState != .idle {
            callState = .ended("Call Ended")
            endedDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.resetState()
            }
        }
    }

    /// Handle an incoming link from the transport layer.
    ///
    /// On iOS, this reports the incoming call to CallKit, which shows the
    /// native incoming call UI (including on the lock screen). The Telephone
    /// actor processes the link signaling in parallel.
    func handleIncomingLink(_ link: Link) {
        guard let telephone else { return }
        self.isIncoming = true
        self.callState = .ringing

        // Generate a UUID for CallKit tracking
        let callUUID = UUID()
        self.currentCallUUID = callUUID

        // Report incoming call to CallKit for native UI
        #if os(iOS)
        callKitManager?.reportIncomingCall(uuid: callUUID, peerName: peerName) { [weak self] error in
            if let error = error {
                Task { @MainActor in
                    self?.logger.warning("CallKit rejected incoming call: \(error.localizedDescription)")
                    // If CallKit rejects (e.g., Do Not Disturb), still show in-app UI
                }
            }
        }
        #endif

        Task {
            await telephone.handleIncomingLink(link)
        }
    }

    // MARK: - Telephony Destination

    /// The LXST telephony destination, for announcing to the network.
    ///
    /// Peers must know this destination hash to initiate calls to us.
    /// Cached at initialization since the Telephone actor's destination is actor-isolated.
    /// Returns nil if the Telephone actor is not yet initialized.
    private(set) var telephonyDestination: Destination?

    // MARK: - Controls

    func toggleMute() {
        isMuted.toggle()
        // Mute is handled in the capture callback gate — no AudioManager action needed.
        // When muted, onCapturedFrame still fires but CallManager discards the frames.
        logger.info("Mute toggled: \(self.isMuted)")
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        audioManager?.setSpeakerEnabled(isSpeakerOn)
        logger.info("Speaker toggled: \(self.isSpeakerOn)")
    }

    func togglePttMode() {
        isPttMode.toggle()
        if !isPttMode {
            isPttActive = false
        }
        logger.info("PTT mode toggled: \(self.isPttMode)")
    }

    func setPttActive(_ active: Bool) {
        isPttActive = active
    }

    // MARK: - Shutdown

    func shutdown() async {
        stopAudio()

        // End any active CallKit call before shutting down Telephone
        #if os(iOS)
        if let uuid = currentCallUUID {
            callKitManager?.reportCallEnded(uuid: uuid, reason: .remoteEnded)
        }
        callKitManager = nil
        #endif

        if let telephone {
            await telephone.hangup()
        }
        stopDurationTimer()
        endedDismissTask?.cancel()
        currentCallUUID = nil
        telephone = nil
    }

    // MARK: - Audio Pipeline

    /// Create and start the AudioManager for the active call.
    ///
    /// Called when a call transitions to `.established`. Configures the audio
    /// pipeline based on the active telephony profile and wires up the capture
    /// callback with mute/PTT gating.
    private func startAudio() {
        guard audioManager == nil else { return }

        let manager = AudioManager(profile: activeProfile)
        self.audioManager = manager

        // Wire capture callback with mute/PTT gating
        manager.onCapturedFrame = { [weak self] samples in
            guard let self else { return }

            // Gate: don't send audio if muted
            if self.isMuted { return }

            // Gate: in PTT mode, only send while PTT button is held
            if self.isPttMode && !self.isPttActive { return }

            // Forward PCM samples to Telephone actor for codec encoding and transmission
            Task { await self.telephone?.sendAudioFrame(samples) }
        }

        manager.start(speakerEnabled: isSpeakerOn)

        logger.info("Audio pipeline started for profile: \(self.activeProfile.displayName)")
    }

    /// Stop and tear down the AudioManager.
    ///
    /// Called when a call ends or is torn down.
    private func stopAudio() {
        audioManager?.stop()
        audioManager = nil
        logger.info("Audio pipeline stopped")
    }

    /// Feed decoded PCM audio from the remote peer for playback.
    ///
    /// Called by the Telephone actor (via callback) when decoded audio frames
    /// arrive from the network. Schedules samples for immediate playback.
    ///
    /// TODO: Wire this to Telephone's decoded frame output once the codec
    /// pipeline delivers frames. The Telephone actor should call:
    ///   await callManager.playReceivedAudio(decodedSamples)
    ///
    /// - Parameter samples: Float32 PCM samples at the profile's sample rate
    func playReceivedAudio(_ samples: [Float]) {
        audioManager?.playDecodedAudio(samples)
    }

    // MARK: - Private

    private func startDurationTimer() {
        callDuration = 0
        durationTask?.cancel()
        durationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.callDuration += 1
            }
        }
    }

    private func stopDurationTimer() {
        durationTask?.cancel()
        durationTask = nil
    }

    private func resetState() {
        callState = .idle
        isMuted = false
        isSpeakerOn = false
        isPttMode = false
        isPttActive = false
        callDuration = 0
        peerName = nil
        peerHash = nil
        isIncoming = false
        audioManager = nil
        currentCallUUID = nil
        isHangingUpFromCallKit = false
    }

    /// Resolve a contact name from the database or path table for an incoming caller.
    ///
    /// Tries in order:
    /// 1. Conversation display name from LXMFDatabase (keyed by LXMF delivery hash)
    /// 2. Announce display name from PathTable (keyed by LXMF delivery hash)
    /// 3. Truncated hex hash fallback
    ///
    /// Updates CallKit with the resolved name if available.
    private func resolveContactName(remoteIdentity: Identity) {
        // Compute the LXMF delivery destination hash for this identity
        // (conversations and path entries are keyed by this hash, not the raw identity hash)
        let deliveryHash = Destination.hash(
            identity: remoteIdentity,
            appName: "lxmf",
            aspects: ["delivery"]
        )

        // 1. Try conversation display name from database, then path table announce name
        Task {
            // Database lookup (actor-isolated)
            if let record = try? await database?.getConversation(hash: deliveryHash),
               let name = record.displayName, !name.isEmpty {
                await MainActor.run {
                    if self.peerName == nil || self.peerName?.hasPrefix("Peer ") == true {
                        self.peerName = name
                        #if os(iOS)
                        if self.isIncoming, let uuid = self.currentCallUUID {
                            self.callKitManager?.updateCallerName(uuid: uuid, name: name)
                        }
                        #endif
                    }
                }
                return
            }

            // 2. Try path table announce name
            if let entry = await pathTable?.lookup(destinationHash: deliveryHash),
               let name = entry.displayName, !name.isEmpty {
                await MainActor.run {
                    if self.peerName == nil || self.peerName?.hasPrefix("Peer ") == true {
                        self.peerName = name
                        #if os(iOS)
                        if self.isIncoming, let uuid = self.currentCallUUID {
                            self.callKitManager?.updateCallerName(uuid: uuid, name: name)
                        }
                        #endif
                    }
                }
            }
        }

        // 3. Fallback: truncated hash
        if self.peerName == nil {
            let hexPrefix = remoteIdentity.hexHash.prefix(8).uppercased()
            self.peerName = "Peer " + hexPrefix
        }

        // Update CallKit with resolved name
        #if os(iOS)
        if self.isIncoming, let uuid = self.currentCallUUID, let name = self.peerName {
            callKitManager?.updateCallerName(uuid: uuid, name: name)
        }
        #endif
    }

    /// Resolve a destination hash to a known Identity via the path table.
    ///
    /// Looks up the public keys stored from the peer's announce in the path table,
    /// then constructs a public-key-only Identity from them.
    private func resolveIdentity(for destinationHash: Data) async -> Identity? {
        guard let pathTable else { return nil }
        guard let entry = await pathTable.lookup(destinationHash: destinationHash) else { return nil }
        guard entry.publicKeys.count == 64 else { return nil }
        return try? Identity(publicKeyBytes: entry.publicKeys)
    }

    /// Format call duration as mm:ss.
    var formattedDuration: String {
        let minutes = Int(callDuration) / 60
        let seconds = Int(callDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - CallKit Helpers

    #if os(iOS)
    /// Map a CallEndReason to the corresponding CXCallEndedReason for CallKit.
    private static func callKitEndReason(from reason: CallEndReason) -> CXCallEndedReason {
        switch reason {
        case .localHangup:
            // Shouldn't normally reach here (local hangup goes through
            // CXEndCallAction), but handle it gracefully.
            return .remoteEnded
        case .remoteHangup:
            return .remoteEnded
        case .rejected:
            return .declinedElsewhere
        case .busy:
            return .remoteEnded
        case .ringTimeout:
            return .unanswered
        case .connectTimeout:
            return .failed
        case .linkClosed:
            return .failed
        }
    }
    #endif
}
