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
    /// Caller-side ring-back cadence loop (runs while the callee's phone rings).
    private var ringbackTask: Task<Void, Never>?
    private var ringbackActive = false
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
        // Build the LXST network transport over the Compat RNS layer, then the
        // transport-agnostic Telephone on top of it. The transport owns
        // identity, telephony-destination registration, link lifecycle,
        // encryption, packetization, identify, and incoming-link detection.
        let networkTransport = PythonNetworkTransport(identity: identity, transport: transport, pathTable: pathTable)
        await networkTransport.start()
        let phone = await Telephone.make(transport: networkTransport)
        self.telephone = phone

        // Cache the telephony destination for announcing (peers need this hash
        // to call us). The transport registers it internally; this mirror is
        // just for display / the announce path.
        self.telephonyDestination = Destination(
            identity: identity,
            appName: "lxst",
            aspects: ["telephony"],
            type: .single,
            direction: .in
        )

        // Prepare the CallKit UUID as soon as an inbound link establishes
        // (pre-identify), mirroring the old handleIncomingLink → prepare timing.
        await networkTransport.setIncomingCallStartedHandler { [weak self] in
            await MainActor.run { self?.prepareForIncomingCall() }
        }

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

        // Incoming-link detection now lives in PythonNetworkTransport, which
        // registers the telephony destination and routes an established inbound
        // link to Telephone (via the NetworkTransport seam) + to CallManager
        // (via the incoming-call-started hook wired above).

        await phone.setRingingCallback { [weak self] remoteHash in
            await MainActor.run {
                self?.handleCallerIdentified(remoteHash)
            }
        }

        await phone.setEstablishedCallback { [weak self] remoteHash in
            await MainActor.run {
                guard let self else { return }
                DiagLog.log("[CALL] establishedCallback fired, isIncoming=\(self.isIncoming), profile=\(self.activeProfile.displayName)")
                self.callState = .established
                self.startDurationTimer()
                #if os(iOS)
                self.stopRingback()  // hand off the tone engine to the call audio
                #endif
                self.startAudio()
                DiagLog.log("[CALL] startAudio() done, audioManager=\(self.audioManager != nil)")
                self.logger.error("[CALL] Established with: \(remoteHash.toHex(), privacy: .public)")

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

        await phone.setEndedCallback { [weak self] _, reason in
            await MainActor.run {
                guard let self else { return }
                self.stopDurationTimer()
                #if os(iOS)
                self.stopRingback()  // stop ring-back if the call ended while ringing
                #endif
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

                // Busy: play the caller-side busy tone before tearing down,
                // mirroring Python LXST __play_busy_tone. playBusyTone handles
                // the rest of teardown (stopAudio + CallKit ended + reset) once
                // the tone finishes; returns false if it couldn't bring up
                // output (then fall through to immediate teardown).
                #if os(iOS)
                if reason == .busy, self.playBusyTone() {
                    return
                }
                #endif

                self.stopAudio()

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
                // The transport resolves the delivery hash → identity →
                // telephony destination and establishes the link; if the peer
                // isn't reachable, call() throws and we surface "Call Failed".
                let destHex = destinationHash.map { String(format: "%02x", $0) }.joined()
                self.logger.error("[CALL] calling Telephone.call() for dest \(destHex, privacy: .public)")
                try await telephone.call(destinationHash: destinationHash, profile: profile)
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
    // Incoming-link detection moved to PythonNetworkTransport. It fires
    // `setIncomingCallStartedHandler` → `prepareForIncomingCall()` (below) when
    // an inbound link establishes, and drives Telephone via the NetworkTransport
    // seam. (Was `handleIncomingLink(_ link: Link)`.)

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
    func handleCallerIdentified(_ remoteDeliveryHash: Data) {
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

        self.peerHash = remoteDeliveryHash.toHex()
        self.callState = .ringing
        self.logger.error("[CALL] Ringing from: \(remoteDeliveryHash.toHex(), privacy: .public)")

        if self.isIncoming {
            self.resolveContactName(deliveryHash: remoteDeliveryHash)
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
            // Outgoing call: report connecting state to CallKit, and play the
            // caller-side ring-back tone while the callee's phone rings.
            #if os(iOS)
            self.callKitManager?.reportOutgoingCall(uuid: uuid)
            self.startRingback()
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
        // Smoke-test escape hatch: when COLUMBA_AUTO_ANSWER=1 the test
        // bypasses CallKit's CXAnswerCallAction flow (the env var path
        // calls answerCall() directly without going through CallKit's
        // provider). Without that, CallKit never fires
        // `didActivateAudioSession` and the engine would defer forever.
        // For the sim↔iPhone audio test, start the engine immediately
        // and let AudioManager configure/activate AVAudioSession itself.
        //
        // Simulator carve-out: the iOS Simulator's AVAudioEngine input
        // node has no real hardware behind it (sample rate reports 0Hz)
        // so `installTap` throws an uncaught Obj-C exception and the
        // whole app crashes. The sim never needs to capture mic for the
        // smoke test (it's always the callee receiving frames), so we
        // keep the deferred path there — playback works regardless of
        // whether the engine actually started.
        #if targetEnvironment(simulator)
        let bypassCallKit = false
        #else
        let bypassCallKit = ProcessInfo.processInfo.environment["COLUMBA_AUTO_ANSWER"] == "1"
        #endif
        if audioSessionActivatedByCallKit || bypassCallKit {
            manager.start(speakerEnabled: isSpeakerOn)
            DiagLog.log("[AUDIO] startAudio() engine started immediately (session active=\(audioSessionActivatedByCallKit) bypass=\(bypassCallKit))")
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

    #if os(iOS)
    /// LXST busy-tone duration + frequency (mirrors Python LXST: 4.25 s of
    /// 0.25 s-on / 0.25 s-off at the 382 Hz dial-tone frequency).
    private static let busyToneSeconds: Double = 4.25

    /// Play the caller-side busy tone, then finish teardown. Returns false if
    /// audio output couldn't be brought up (caller falls back to immediate
    /// teardown). Only meaningful for an outgoing call (busy is received by the
    /// caller); needs the CallKit audio session active — which it normally is
    /// by the time an outbound link is up.
    ///
    /// Mirrors LXST `__play_busy_tone`, adapted to our split where audio output
    /// lives in AudioManager. NOTE: `reportCallEnded` deactivates the audio
    /// session, so it is deliberately deferred until after the tone.
    /// Bring up output-only audio for call-progress tones (busy / ring-back) on
    /// a call that hasn't reached the established/startAudio path. Gated on the
    /// CallKit audio session being active (it normally is for an outgoing call
    /// by the time signalling arrives). Returns the manager, or nil if output
    /// can't be started.
    private func ensureToneOutput() -> AudioManager? {
        guard audioSessionActivatedByCallKit else { return nil }
        if audioManager == nil {
            let manager = AudioManager(profile: activeProfile)
            self.audioManager = manager
            manager.start(speakerEnabled: isSpeakerOn)
        }
        return audioManager
    }

    @discardableResult
    private func playBusyTone() -> Bool {
        guard let manager = ensureToneOutput() else { return false }

        let samples = Self.busyTonePCM(sampleRate: manager.sampleRate, channels: manager.channels)
        manager.playDecodedAudio(samples)
        logger.error("[CALL] Playing busy tone (\(Self.busyToneSeconds, privacy: .public)s)")

        // Finish teardown once the tone has played out.
        endedDismissTask?.cancel()
        endedDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.busyToneSeconds + 0.4))
            guard !Task.isCancelled, let self else { return }
            self.stopAudio()
            if let uuid = self.currentCallUUID {
                self.callKitManager?.reportCallEnded(uuid: uuid, reason: .failed)
            }
            self.resetState()
        }
        return true
    }

    /// Generate the busy-tone PCM: a 382 Hz sine gated 0.25 s on / 0.25 s off
    /// for `busyToneSeconds`, interleaved across `channels` at `sampleRate`
    /// (matching what AudioManager.playDecodedAudio expects).
    private static func busyTonePCM(sampleRate: Double, channels: Int) -> [Float] {
        let frequency = TelephonyConstants.dialToneFrequency
        let frames = Int(sampleRate * busyToneSeconds)
        let ch = max(channels, 1)
        let window = 0.5          // 0.5 s beep cycle
        let onThreshold = 0.25    // on for the second half of each cycle
        let gain: Float = 0.2
        let twoPiF = 2.0 * Double.pi * frequency
        var out = [Float](repeating: 0, count: frames * ch)
        for f in 0..<frames {
            let t = Double(f) / sampleRate
            let inWindow = t.truncatingRemainder(dividingBy: window)
            let sample: Float = inWindow > onThreshold ? gain * Float(sin(twoPiF * t)) : 0
            for c in 0..<ch { out[f * ch + c] = sample }
        }
        return out
    }

    /// Start the caller-side ring-back tone (the "ringing" the caller hears
    /// while the callee's phone rings). Mirrors LXST `__activate_dial_tone`:
    /// 382 Hz, ~2 s on / ~5 s off (7 s cadence), looping until the call is
    /// answered or ends. CallKit does NOT provide ring-back for outgoing VoIP
    /// calls, so we render it. Caller-side only (the callee's ring is CallKit's
    /// system ringtone).
    private func startRingback() {
        guard !isIncoming, !ringbackActive else { return }
        guard let manager = ensureToneOutput() else { return }
        ringbackActive = true
        let tone = Self.ringbackTonePCM(sampleRate: manager.sampleRate, channels: manager.channels)
        logger.error("[CALL] Starting ring-back tone")
        ringbackTask?.cancel()
        ringbackTask = Task { @MainActor [weak self] in
            // 7 s cadence: schedule the 2 s tone, then idle (silence) for the
            // remainder before scheduling the next burst.
            while !Task.isCancelled {
                guard let self, self.ringbackActive else { return }
                self.audioManager?.playDecodedAudio(tone)
                try? await Task.sleep(for: .seconds(7))
            }
        }
    }

    /// Stop the ring-back loop. Tears down the tone-only output engine so the
    /// established path recreates it fresh with the negotiated profile + mic
    /// capture (startAudio early-returns if a manager already exists).
    private func stopRingback() {
        ringbackTask?.cancel()
        ringbackTask = nil
        if ringbackActive {
            ringbackActive = false
            stopAudio()
        }
    }

    /// Generate one 2 s ring-back burst: a 382 Hz sine with 10 ms fade in/out
    /// (to avoid clicks), interleaved across `channels` at `sampleRate`.
    private static func ringbackTonePCM(sampleRate: Double, channels: Int) -> [Float] {
        let frequency = TelephonyConstants.dialToneFrequency
        let onSeconds = 2.0
        let frames = Int(sampleRate * onSeconds)
        let ch = max(channels, 1)
        let gain: Float = 0.12
        let twoPiF = 2.0 * Double.pi * frequency
        let fade = max(Int(sampleRate * 0.01), 1)  // 10 ms ramp
        var out = [Float](repeating: 0, count: frames * ch)
        for f in 0..<frames {
            var env: Float = 1
            if f < fade { env = Float(f) / Float(fade) }
            else if f >= frames - fade { env = Float(frames - 1 - f) / Float(fade) }
            let sample = gain * env * Float(sin(twoPiF * Double(f) / sampleRate))
            for c in 0..<ch { out[f * ch + c] = sample }
        }
        return out
    }
    #endif

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
    private func resolveContactName(deliveryHash: Data) {
        // `deliveryHash` is the peer's lxmf.delivery destination hash — the key
        // conversations and path entries are stored under. (The transport
        // computed it from the verified caller identity.)

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
            let hexPrefix = deliveryHash.toHex().prefix(8).uppercased()
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

    // Identity resolution (delivery hash → public-key Identity) moved into
    // PythonNetworkTransport.openOutboundCall, where the telephony destination
    // and link are built.

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
