//
//  CallManager.swift
//  ColumbaApp
//
//  Observable bridge between SwiftUI and the LXSTSwift Telephone actor.
//  Manages call state, controls, duration timing, and audio pipeline for the UI layer.
//

import AVFoundation
import Foundation
import RNSAPI
import LXSTSwift
import RNSAPI
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

    /// Debug diagnostic text shown on the call screen during development.
    var debugAudioInfo: String = ""
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
    /// CallKit reporter for native iOS call integration (lock screen UI, audio routing).
    /// Production type is `CallKitManager`; tests inject a mock conforming to
    /// `CallKitReporting`. Created lazily on first use. nil on non-iOS platforms.
    var callKitManager: (any CallKitReporting)?
    #endif

    /// UUID for the currently active call, used by CallKit to track the call.
    /// Internally settable so tests can pre-stage a UUID without going through
    /// the full `prepareForIncomingCall` / `call` flow.
    var currentCallUUID: UUID?

    /// Flag to prevent re-entrant hangup when CallKit triggers CXEndCallAction.
    private var isHangingUpFromCallKit = false

    /// Flag to prevent re-entrant answer when CallKit triggers CXAnswerCallAction.
    private var isAnsweringFromCallKit = false

    /// Set to true when CallKit fires `didActivateAudioSession`.
    /// For outgoing calls, this is set early (during CXStartCallAction).
    /// For incoming calls, this is set after the user answers.
    /// Used by `startAudio()` to decide whether to start the engine immediately
    /// or defer until the session is activated.
    private var audioSessionActivatedByCallKit = false

    // MARK: - Internal

    private var telephone: Telephone?
    private var transport: ReticulumTransport?
    private var pathTable: PathTable?
    private var database: LXMFDatabase?
    private var durationTask: Task<Void, Never>?
    private var endedDismissTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "network.columba.Columba", category: "CallManager")

    // MARK: - Initialization

    /// Initialize the Telephone actor with identity, transport, and path table.
    ///
    /// This method:
    /// 1. Creates the Telephone actor (which registers its destination with transport)
    /// 2. Registers a destination link callback so incoming links are routed to Telephone
    /// 3. Wires up ringing/established/ended callbacks for UI state updates
    func initialize(identity: Identity, transport: ReticulumTransport, pathTable: PathTable?, database: LXMFDatabase?) async {
        self.pathTable = pathTable
        self.transport = transport
        self.database = database
        let phone = await Telephone(identity: identity, transport: transport)
        self.telephone = phone

        // Wire diagnostic logging
        await phone.setDiagnostic { msg in DiagLog.log(msg) }

        // Set decoded audio callback so remote audio frames reach AudioManager
        await phone.setDecodedAudioCallback { [weak self] samples, rate, channels in
            await MainActor.run {
                guard let self else { return }
                if self.playReceivedCount == 0 {
                    DiagLog.log("[AUDIO_RX] First decoded frame: \(samples.count) samples, rate=\(rate), ch=\(channels), audioManager=\(self.audioManager != nil)")
                }
                self.playReceivedAudio(samples)
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
            // This callback fires BEFORE the link is fully established (pre-LRRTT).
            // Only configure the link here — do NOT send data (no encryption keys yet).
            // Set the link established callback to handle the incoming call once
            // the link is active and we can safely send AVAILABLE/RINGING signals.
            await link.setLinkEstablishedCallback { [weak self] (establishedLink: Link) async in
                guard let self else { return }
                await MainActor.run {
                    self.handleIncomingLink(establishedLink)
                }
            }
        }

        await phone.setRingingCallback { [weak self] remoteIdentity in
            await MainActor.run {
                self?.handleCallerIdentified(remoteIdentity)
            }
        }

        await phone.setEstablishedCallback { [weak self] remoteIdentity in
            await MainActor.run {
                guard let self else { return }
                DiagLog.log("[CALL] establishedCallback fired, isIncoming=\(self.isIncoming), profile=\(self.activeProfile.displayName)")
                self.callState = .established
                self.startDurationTimer()
                self.startAudio()
                DiagLog.log("[CALL] startAudio() done, audioManager=\(self.audioManager != nil)")
                self.logger.error("[CALL] Established with: \(remoteIdentity.hexHash, privacy: .public)")

                // Report call connected to CallKit (outgoing calls ONLY).
                // For incoming calls, CallKit already considers the call connected
                // after CXAnswerCallAction is fulfilled. Calling reportOutgoingCall()
                // for an incoming UUID confuses CallKit and can trigger CXEndCallAction.
                #if os(iOS)
                if !self.isIncoming, let uuid = self.currentCallUUID {
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
    ///
    /// On iOS, routes through CallKit so the system properly activates the
    /// audio session and dismisses its incoming call UI. If the answer
    /// originates from CallKit (via CXAnswerCallAction), calls Telephone
    /// directly to avoid a re-entrant loop.
    func answerCall() {
        guard let telephone else { return }

        #if os(iOS)
        // If this answer was triggered by CallKit's CXAnswerCallAction, go
        // directly to Telephone to avoid a re-entrant loop.
        if isAnsweringFromCallKit {
            isAnsweringFromCallKit = false
            logger.error("[CALL] answerCall (from CallKit) — calling telephone.answer()")
            Task {
                await telephone.answer()
            }
            return
        }

        // Route through CallKit so the system activates the audio session
        // and dismisses the incoming call notification.
        // CXAnswerCallAction will call back into answerFromCallKit().
        if let uuid = currentCallUUID {
            logger.error("[CALL] answerCall — routing through CallKit")
            callKitManager?.answerCall(uuid: uuid)
            return
        }
        #endif

        // Fallback: direct answer (no CallKit or no UUID)
        logger.error("[CALL] answerCall (direct) — calling telephone.answer()")
        Task {
            await telephone.answer()
        }
    }

    /// Called by CallKitManager when the system requests answering the call
    /// (CXAnswerCallAction). Performs the actual Telephone answer without
    /// re-entering CallKit.
    func answerFromCallKit() {
        isAnsweringFromCallKit = true
        answerCall()
    }

    /// Hang up the current call.
    ///
    /// On iOS, routes through CallKit so the system UI is updated.
    /// If CallKit is not available or the hangup originates from CallKit
    /// (via CXEndCallAction), calls Telephone.hangup() directly.
    func hangup() {
        guard let telephone else { return }
        DiagLog.log("[CALL] hangup() called, isHangingUpFromCallKit=\(isHangingUpFromCallKit), callState=\(String(describing: callState))")

        #if os(iOS)
        // If this hangup was triggered by CallKit's CXEndCallAction, go
        // directly to Telephone to avoid a re-entrant loop.
        if isHangingUpFromCallKit {
            isHangingUpFromCallKit = false
            DiagLog.log("[CALL] hangup() via CallKit path")
            Task {
                await telephone.hangup()
            }
            return
        }

        // Route through CallKit so the system call UI is dismissed.
        // CXEndCallAction will call back into hangupFromCallKit().
        if let uuid = currentCallUUID {
            DiagLog.log("[CALL] hangup() routing through CallKit")
            callKitManager?.endCall(uuid: uuid)
            return
        }
        #endif

        // Fallback: direct hangup (no CallKit or no UUID)
        DiagLog.log("[CALL] hangup() direct (no CallKit)")
        Task {
            await telephone.hangup()
        }
    }

    /// Called by CallKitManager when the system requests ending the call
    /// (CXEndCallAction). Performs the actual Telephone hangup without
    /// re-entering CallKit.
    func hangupFromCallKit() {
        guard telephone != nil else { return }
        DiagLog.log("[CALL] hangupFromCallKit() triggered")
        isHangingUpFromCallKit = true
        hangup()
    }

    /// Called by CallKitManager when the audio session is activated by the system.
    ///
    /// For **outgoing** calls this fires early (during CXStartCallAction), before
    /// AudioManager exists — we just set the flag for later.
    ///
    /// For **incoming** calls this fires AFTER startAudio() has created the
    /// AudioManager but deferred starting the engine. We start it now that
    /// the session is truly active.
    func handleAudioSessionActivated() {
        audioSessionActivatedByCallKit = true
        DiagLog.log("[CALL] handleAudioSessionActivated, audioManager=\(audioManager != nil), isActive=\(audioManager?.isActive ?? false)")

        if let manager = audioManager, !manager.isActive {
            // Deferred start: AudioManager was created but not started (incoming call).
            // Now that CallKit activated the session, start the engine.
            DiagLog.log("[AUDIO] Starting deferred AudioManager now that session is active")
            manager.start(speakerEnabled: isSpeakerOn)
        } else if let manager = audioManager, manager.isActive {
            // Already running — restart capture in case session changed
            manager.handleAudioSessionActivated()
        }
    }

    /// Called by CallKitManager when the provider is reset (e.g., system
    /// force-stops all calls). Cleans up any active call state.
    func handleCallKitReset() {
        DiagLog.log("[CALL] handleCallKitReset() triggered")
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
    /// Per the LXST protocol, link establishment alone is NOT a call —
    /// it's just "we have a secure pipe". The Telephone actor takes over
    /// from here, sends `STATUS_AVAILABLE`, and waits for the caller to
    /// `link.identify(...)`. CallKit is invoked only after that
    /// identification completes (see `handleCallerIdentified`), so
    /// scanners / probes / aborted dials that open a link without
    /// identifying don't surface as phantom "Unknown" calls.
    func handleIncomingLink(_ link: Link) {
        guard let telephone else {
            DiagLog.log("[CALL] handleIncomingLink: telephone is nil!")
            return
        }
        DiagLog.log("[CALL] handleIncomingLink: starting incoming call setup (deferring CallKit until caller identifies)")
        prepareForIncomingCall()

        Task {
            await telephone.handleIncomingLink(link)
        }
    }

    /// Reset call state for an incoming link before the caller identifies.
    ///
    /// Allocates the call UUID up front so the post-identify path
    /// (`handleCallerIdentified`) can hand it to CallKit. CallKit itself
    /// is NOT invoked here — that's the whole point of separating this
    /// step from the protocol-correct ringing trigger.
    ///
    /// Also clears `peerName`/`peerHash` from any previous call so that
    /// when a fresh inbound link arrives within the 1.5 s
    /// `endedDismissTask` window (before `resetState()` runs), a stale
    /// resolved name doesn't survive into the new call.
    /// `resolveContactName`'s "skip if already set" guard would otherwise
    /// keep the previous caller's name pinned across the new call's
    /// lookups.
    func prepareForIncomingCall() {
        self.isIncoming = true
        self.callState = .connecting
        self.currentCallUUID = UUID()
        self.peerName = nil
        self.peerHash = nil
    }

    /// Run the post-identify ringing flow: update UI state, resolve the
    /// caller's display name, and report the call to CallKit.
    ///
    /// Wired from `LXSTSwift.Telephone.setRingingCallback`, which fires
    /// only after the LXST `STATUS_AVAILABLE` → `link.identify(...)` →
    /// `handleCallerIdentified` exchange completes inside the Telephone
    /// actor. By that point the caller's `Identity` is verified and we
    /// have a real peer to ring on.
    ///
    /// Outgoing calls reach this with `isIncoming == false` and report
    /// the connecting state via `reportOutgoingCall`.
    func handleCallerIdentified(_ remoteIdentity: Identity) {
        // Bail BEFORE mutating call state if the call was reset between
        // prepareForIncomingCall (or the outgoing-call setup) and
        // identify completing — e.g. an abort or remote hangup raced
        // the LXST identify exchange. Setting `callState = .ringing`
        // here without a UUID would leave the in-app UI stuck on
        // ringing with no CallKit registration to dismiss it through.
        guard let uuid = self.currentCallUUID else {
            self.logger.warning(
                "[CALL] handleCallerIdentified: no currentCallUUID — call was reset before identify completed, skipping (isIncoming=\(self.isIncoming, privacy: .public))"
            )
            return
        }

        self.peerHash = remoteIdentity.hexHash
        self.callState = .ringing
        self.logger.error("[CALL] Ringing from: \(remoteIdentity.hexHash, privacy: .public)")

        if self.isIncoming {
            self.resolveContactName(remoteIdentity: remoteIdentity)
            // Surface the incoming call to the system now that the caller
            // is verified. `resolveContactName` has populated `peerName`
            // synchronously with the `"Peer XXXXXXXX"` truncated-hash
            // fallback — the actual contact name from the DB / path
            // table arrives later via an async task that calls
            // `updateCallerName` after the UUID is registered with
            // CallKit (i.e. after this `reportIncomingCall` lands).
            #if os(iOS)
            self.callKitManager?.reportIncomingCall(uuid: uuid, peerName: peerName) { [weak self] error in
                if let error = error {
                    Task { @MainActor in
                        self?.logger.warning("CallKit rejected incoming call: \(error.localizedDescription)")
                    }
                }
            }
            #endif
            // Sim-to-sim smoke-test escape hatch: when the
            // `COLUMBA_AUTO_ANSWER=1` env var is set, auto-answer the
            // incoming call as soon as the caller is verified, so the
            // commit-5 audio round-trip test can drive past RINGING
            // without needing the simulator window to be foregrounded
            // (sim2 is usually backgrounded behind sim1 during the test,
            // and `simctl openurl` only delivers URLs to the frontmost
            // simulator).
            if ProcessInfo.processInfo.environment["COLUMBA_AUTO_ANSWER"] == "1" {
                self.logger.error("[CALL] COLUMBA_AUTO_ANSWER=1 — auto-answering")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    self?.answerCall()
                }
            }
        } else {
            // Outgoing call: report connecting state to CallKit
            #if os(iOS)
            self.callKitManager?.reportOutgoingCall(uuid: uuid)
            #endif
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
    ///
    /// For **outgoing** calls, `didActivateAudioSession` has already fired by this
    /// point, so the engine starts immediately with an active audio session.
    ///
    /// For **incoming** calls, `didActivateAudioSession` hasn't fired yet — CallKit
    /// activates the session asynchronously after CXAnswerCallAction. We create
    /// the AudioManager and wire callbacks, but defer `start()` until
    /// `handleAudioSessionActivated()` fires. This ensures the mic works because
    /// the engine starts with an already-active session (same as outgoing).
    private func startAudio() {
        guard audioManager == nil else {
            DiagLog.log("[AUDIO] startAudio() skipped — already active")
            return
        }
        DiagLog.log("[AUDIO] startAudio() creating AudioManager with profile=\(activeProfile.displayName), sessionActive=\(audioSessionActivatedByCallKit)")

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

        #if os(iOS)
        if audioSessionActivatedByCallKit {
            // Session already active (outgoing calls, or rare fast incoming activation).
            // Start engine immediately — mic will work.
            manager.start(speakerEnabled: isSpeakerOn)
            DiagLog.log("[AUDIO] startAudio() engine started immediately (session already active)")
        } else {
            // Incoming call: CallKit hasn't activated the session yet.
            // Defer engine start to handleAudioSessionActivated().
            DiagLog.log("[AUDIO] startAudio() deferring engine start until didActivateAudioSession")
        }
        #else
        manager.start(speakerEnabled: isSpeakerOn)
        #endif

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
    private var playReceivedCount = 0
    func playReceivedAudio(_ samples: [Float]) {
        playReceivedCount += 1

        // Compute peak for diagnostics
        let peak = samples.reduce(Float(0)) { Swift.max($0, abs($1)) }

        if playReceivedCount == 1 || playReceivedCount % 50 == 0 {
            let am = audioManager
            let engRunning = am?.engine?.isRunning ?? false
            let playerPlaying = am?.playerNode?.isPlaying ?? false
            logger.error("[CALL] playReceivedAudio #\(self.playReceivedCount, privacy: .public): \(samples.count, privacy: .public) samples, peak=\(peak, privacy: .public), audioManager=\(am != nil, privacy: .public) engRunning=\(engRunning, privacy: .public) playerPlaying=\(playerPlaying, privacy: .public) profile=\(self.activeProfile.displayName, privacy: .public) ch=\(self.activeProfile.opusProfile?.channels ?? -1, privacy: .public)")
        }

        // Update debug overlay every 10th frame
        if playReceivedCount == 1 || playReceivedCount % 10 == 0 {
            let st = OpusCodec.lastSelfTestResult
            let di = OpusCodec.lastDecodeInfo
            let pi = AudioPipeline.lastPipelineInfo
            var lines: [String] = []
            lines.append("RX#\(playReceivedCount) fpeak=\(String(format: "%.4f", peak)) n=\(samples.count)")
            if !di.isEmpty { lines.append(di) }
            lines.append("dec=\(OpusCodec.totalDecodes) maxPk=\(OpusCodec.maxPeakInt16)")
            if !pi.isEmpty { lines.append(pi) }
            if !st.isEmpty { lines.append(st) }
            lines.append("profile=\(activeProfile.displayName)")
            debugAudioInfo = lines.joined(separator: "\n")
        }

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
        isAnsweringFromCallKit = false
        audioSessionActivatedByCallKit = false
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
            // Database lookup (actor-isolated). `displayName` is a non-optional
            // String in the Compat layer; empty string is the "no name" sentinel.
            if let record = try? await database?.getConversation(hash: deliveryHash),
               !record.displayName.isEmpty {
                let name = record.displayName
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

            // 2. Try path table announce name (non-optional String, empty == none).
            if let entry = await pathTable?.lookup(destinationHash: deliveryHash),
               !entry.displayName.isEmpty {
                let name = entry.displayName
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

        // Note: no synchronous CallKit update here. For incoming calls
        // this method runs *before* `reportIncomingCall` registers the
        // UUID with CallKit, so any `updateCallerName` call would be
        // dropped. The fallback `peerName` set above is passed straight
        // into `reportIncomingCall`, and the async DB / path-table tasks
        // above call `updateCallerName` themselves once they resolve a
        // real display name (by which time the UUID is registered).
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
