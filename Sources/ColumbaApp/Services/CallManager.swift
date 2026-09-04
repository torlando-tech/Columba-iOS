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
    #if COLUMBA_RUNTIME_PYTHON
    private var networkTransport: PythonNetworkTransport?
    #endif
    private var transport: ReticulumTransport?
    private var pathTable: PathTable?
    private var database: LXMFDatabase?
    private var durationTask: Task<Void, Never>?
    private var endedDismissTask: Task<Void, Never>?
    /// Caller-side ring-back cadence loop (runs while the callee's phone rings).
    private var ringbackTask: Task<Void, Never>?
    private var ringbackActive = false
    private let logger = Logger(subsystem: "network.columba.Columba", category: "CallManager")

    // MARK: - Call history (issue #167)

    /// History writer. Nil in Model B runtime / before AppServices wires it → all
    /// history writes no-op (feature is additive, never blocks a call).
    ///
    /// Both CallManager and CallHistoryRepository live in the SAME ColumbaApp
    /// target, so CallManager holds the CONCRETE actor directly (no protocol
    /// needed). Its write methods are `async throws`; CallManager enqueues them
    /// onto an ordered per-attempt chain (`historyWriteChain`) from its
    /// @MainActor callbacks — a history write must never block or fail a call,
    /// yet a call's writes must land in lifecycle order (insert → milestones →
    /// end), so an end can't outrun its insert.
    var callHistoryRepository: CallHistoryRepository?
    /// Hex of the active local identity, set at init for identity-scoped writes.
    /// (Internal, not private, so lifecycle tests can seed it without the full
    /// `initialize()` transport stack.)
    var localIdentityHashHex: String?
    /// The attempt id for the in-flight call (nil when idle).
    private(set) var currentCallAttemptId: String?
    /// Serialized history-write chain: every write for the current call attempt
    /// is appended here and executes in FIFO order. A new attempt starts a new
    /// chain (only one call is in flight at a time). This is what makes
    /// `recordEnd` observe the row `insertAttempt` created — the lifecycle
    /// callbacks fire independently and can be arbitrarily close together.
    private var historyWriteChain: Task<Void, Never>?
    /// The in-flight `initiateCall` task (Python-runtime only). Shutdown
    /// CANCELS it (deliberately does not await it — a task stuck in a
    /// non-cancellable network await would hang teardown; the `isShutDown`
    /// latch carries the guarantee instead): it can be suspended at an
    /// `await` (destination resolution / prepareOutboundCall / an in-flight
    /// telephone.call) and would otherwise resume after the drain and start a
    /// fresh history attempt on a torn-down manager. (private(set) so
    /// lifecycle tests can assert it is cleared on shutdown.)
    private(set) var outgoingCallTask: Task<Void, Never>?
    /// Set (synchronously, on the main actor) at the very start of
    /// `shutdown()`. Suspended `initiateCall` tasks re-check it after each
    /// suspension point and abort before touching call state or the history
    /// store, so nothing can create a write chain after the drain. THIS latch
    /// — not the (bounded) task await — is what carries the "no fresh attempt
    /// after shutdown" guarantee: it is set before any suspension, and every
    /// write path observes it. (private(set) so lifecycle tests can assert
    /// the latch engaged on shutdown.)
    private(set) var isShutDown = false
    private var callAttemptStartedAt: Date?
    private var peerDisplayNameSnapshot: String?
    /// Whether the in-flight call reached the connection milestone
    /// (establishedCallback fired). Drives the `wasConnected` outcome rule.
    /// Reset in beginCallAttempt / resetState.
    private var didConnect: Bool = false
    /// Observable: the attempt id of the live call, so the Voice list can mark the
    /// matching record "In progress". Nil when idle.
    public private(set) var activeCallAttemptId: String?

    /// Start tracking one call attempt in the history store.
    ///
    /// `peerHash` is set before this is called on BOTH paths (outgoing:
    /// `initiateCall`, incoming: `handleCallerIdentified`), so it is non-nil
    /// here; a blank/absent hash is never valid for a stored record, so it is
    /// stored as an empty string rather than force-unwrapped (no crash).
    /// The write seeds the per-attempt ordered chain: a history write must
    /// never block or fail a call, and a nil repository (Model B / pre-wiring)
    /// is a silent no-op.
    ///
    /// Refuses to start once the instance is shut down (`isShutDown`): a task
    /// that was suspended at a network await and resumes AFTER `shutdown()`
    /// must not be able to create a fresh attempt against the repository
    /// AppServices has closed. This is the single point every attempt is born
    /// from (outgoing + incoming), so it is the authoritative "no fresh
    /// attempt after shutdown" gate. (Internal, not private, so lifecycle
    /// tests can exercise the gate directly.)
    func beginCallAttempt(direction: CallHistoryDirection, peerDisplayName: String?) {
        guard let hex = localIdentityHashHex else { return }
        guard !isShutDown else {
            logger.info("[CALL] beginCallAttempt refused: manager already shut down")
            return
        }
        let id = UUID().uuidString
        currentCallAttemptId = id
        activeCallAttemptId = id
        callAttemptStartedAt = Date()
        didConnect = false
        peerDisplayNameSnapshot = peerDisplayName
        let remoteHash = peerHash ?? ""
        let profileCode = Int(activeProfile.rawValue)
        // All values are captured by value (like the other write sites), so
        // the Task only holds the repo for the duration of the write. A NEW
        // attempt always gets a FRESH chain: only one call is in flight at a
        // time, and any leftover (completed) chain from the previous attempt
        // is discarded — nothing from it is still pending, because every
        // terminal path (ended / failed / reset) finalizes before clearing.
        let repo = callHistoryRepository
        historyWriteChain = Task {
            guard let repo else { return }
            try? await repo.insertAttempt(
                callAttemptId: id, localIdentityHash: hex,
                remoteIdentityHash: remoteHash,
                direction: direction, peerDisplayNameSnapshot: peerDisplayName,
                codecProfileCode: profileCode, attemptedAt: Date())
        }
    }

    /// Enqueue one history write on the current attempt's ordered chain
    /// (FIFO: insert → milestones → end), creating the chain if
    /// `beginCallAttempt` hasn't seeded one yet.
    ///
    /// Each step awaits the previous, so a call's writes always land in
    /// lifecycle order — in particular the terminal `recordEnd` always runs
    /// AFTER the `insertAttempt` row exists. The writes run detached from the
    /// caller (a history write must never block a call); a nil repository
    /// (Model B / pre-wiring) is a silent no-op.
    private func enqueueHistoryWrite(_ body: @escaping @Sendable () async -> Void) {
        if let existing = historyWriteChain {
            historyWriteChain = Task { await existing.value; await body() }
        } else {
            historyWriteChain = Task { await body() }
        }
    }

    // MARK: - Initialization

    /// Initialize the Telephone actor with identity, transport, and path table.
    ///
    /// This method:
    /// 1. Creates the Telephone actor (which registers its destination with transport)
    /// 2. Registers a destination link callback so incoming links are routed to Telephone
    /// 3. Wires up ringing/established/ended callbacks for UI state updates
    func initialize(identity: Identity, transport: ReticulumTransport, pathTable: PathTable?, database: LXMFDatabase?) async {
        #if COLUMBA_RUNTIME_PYTHON
        self.localIdentityHashHex = identity.hexHash
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
        self.networkTransport = networkTransport

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
                // Outgoing-only: our own call started ringing on the far end.
                // (For incoming, handleCallerIdentified above begins the attempt;
                // the isIncoming==false guard keeps this from double-recording.)
                if let id = self?.currentCallAttemptId, self?.isIncoming == false,
                   let repo = self?.callHistoryRepository {
                    self?.enqueueHistoryWrite {
                        try? await repo.recordRinging(id, at: Date())
                    }
                }
            }
        }

        await phone.setEstablishedCallback { [weak self] remoteHash in
            await MainActor.run {
                guard let self else { return }
                DiagLog.log("[CALL] establishedCallback fired, isIncoming=\(self.isIncoming), profile=\(self.activeProfile.displayName)")
                self.callState = .established
                // Connection milestone reached — the wasConnected outcome rule
                // (CallHistoryFormatting.outcome) reads didConnect to decide
                // .connectedEnded vs the not-connected outcomes.
                self.didConnect = true
                if let id = self.currentCallAttemptId {
                    let repo = self.callHistoryRepository
                    self.enqueueHistoryWrite {
                        guard let repo else { return }
                        try? await repo.recordConnected(id, at: Date())
                    }
                }
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
                // Finalize the call-history record. didConnect is the load-bearing
                // argument: it is what makes a connected call finalize as
                // .connectedEnded even when the local user hangs up.
                if let id = self.currentCallAttemptId {
                    let direction: CallHistoryDirection = self.isIncoming ? .incoming : .outgoing
                    let outcome = CallHistoryFormatting.outcome(direction: direction,
                                                                wasConnected: self.didConnect,
                                                                reason: reason)
                    let repo = self.callHistoryRepository
                    self.enqueueHistoryWrite {
                        guard let repo else { return }
                        try? await repo.recordEnd(id, at: Date(), outcome: outcome)
                    }
                    self.currentCallAttemptId = nil
                    self.activeCallAttemptId = nil
                }
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
        #elseif COLUMBA_RUNTIME_MODEL_B
        // Model B excludes PythonNetworkTransport. Its app process is a thin
        // ProxyRnsBackend client and must not recreate a local RNS node.
        self.pathTable = pathTable
        self.transport = transport
        self.database = database
        logger.info("[CALL] unavailable in Model B app runtime")
        #endif
    }

    // MARK: - Call Actions

    /// Initiate an outgoing call from either an lxmf.delivery conversation or
    /// an independently announced lxst.telephony node.
    ///
    /// Resolution happens before CallKit starts: LXSTSwift and the backend see
    /// only the canonical telephony destination hash.
    func initiateCall(destinationHash: Data, profile: TelephonyProfile = .qualityMedium, peerDisplayName: String?) {
        #if COLUMBA_RUNTIME_PYTHON
        guard let telephone, let networkTransport else {
            logger.warning("Cannot call: Telephone not initialized")
            return
        }

        let task = Task {
            guard let target = await resolveTelephonyTarget(from: destinationHash) else {
                self.failOutgoingCall("Telephony identity unavailable")
                return
            }
            // An identity switch / app shutdown may have happened while the
            // resolution above was suspended: abort before touching call
            // state or the history store.
            if self.isShutDown || Task.isCancelled {
                self.logger.info("[CALL] initiateCall aborted after resolve (shutdown/cancelled)")
                return
            }
            await networkTransport.prepareOutboundCall(target)
            // Same gate after prepare: a shutdown that raced it must not
            // start a call attempt on a torn-down manager (whose repository
            // AppServices is about to close).
            if self.isShutDown || Task.isCancelled {
                self.logger.info("[CALL] initiateCall aborted after prepare (shutdown/cancelled)")
                return
            }

            self.isIncoming = false
            self.peerName = peerDisplayName
            self.peerHash = target.destinationHash.toHex()
            self.callState = .calling
            self.activeProfile = profile
            // Begin the history attempt AFTER activeProfile is set so the
            // captured codecProfileCode is the outgoing default, not a stale
            // value from a previous call. peerHash is already set above.
            // (No suspension point between the gate after prepareOutboundCall
            // and here, so nothing can interleave: if a shutdown landed,
            // gate 2 above already returned.)
            self.beginCallAttempt(direction: .outgoing, peerDisplayName: peerDisplayName)

            let callUUID = UUID()
            self.currentCallUUID = callUUID
            #if os(iOS)
            let handle = peerDisplayName ?? self.peerHash ?? "unknown"
            self.callKitManager?.startCall(uuid: callUUID, handle: handle)
            #endif

            do {
                // backend.openLink actively requests and awaits this exact
                // telephony path before reporting it unreachable.
                let destHex = target.destinationHash.toHex()
                self.logger.error("[CALL] calling Telephone.call() for telephony dest \(destHex, privacy: .public)")
                try await telephone.call(destinationHash: target.destinationHash, profile: profile)
            } catch {
                self.logger.error("[CALL] Call initiation failed: \(error.localizedDescription, privacy: .public)")
                self.failOutgoingCall("Call Failed")
            }
        }
        // Track the task so shutdown() can cancel + await it (it may be
        // suspended at a network await when the app tears down).
        self.outgoingCallTask = task
        #else
        logger.warning("Cannot call: telephony is unavailable in Model B app runtime")
        #endif
    }

    #if COLUMBA_RUNTIME_PYTHON
    /// Resolve a direct telephony announce or derive the telephony destination
    /// from any sibling announce carrying the same 64-byte public identity.
    /// A cached sibling telephony row is preferred but never required.
    private func resolveTelephonyTarget(from sourceHash: Data) async -> TelephonyCallTarget? {
        guard let pathTable,
              let source = await pathTable.lookup(destinationHash: sourceHash),
              source.publicKeys.count == 64,
              let remoteIdentity = try? Identity(publicKeyBytes: source.publicKeys) else {
            return nil
        }

        let derivedHash = Destination.hash(
            identity: remoteIdentity,
            appName: "lxst",
            aspects: ["telephony"]
        )

        if source.destinationAspect == .lxstTelephony {
            guard sourceHash == derivedHash else { return nil }
            return TelephonyCallTarget(destinationHash: sourceHash, publicKeys: source.publicKeys)
        }

        // Android-style cross-link: one row per destination, joined by the
        // shared public identity. Only accept a sibling whose hash verifies.
        if let sibling = await pathTable.allEntries().first(where: {
            $0.destinationAspect == .lxstTelephony
                && $0.publicKeys == source.publicKeys
                && $0.destinationHash == derivedHash
        }) {
            return TelephonyCallTarget(destinationHash: sibling.destinationHash, publicKeys: sibling.publicKeys)
        }

        // Missing local telephony cache is not a reachability verdict. Stage the
        // verified identity and let backend.openLink request the derived path.
        return TelephonyCallTarget(destinationHash: derivedHash, publicKeys: source.publicKeys)
    }

    /// Pre-connect setup failure terminalizer. (Internal, not private, so
    /// lifecycle tests can exercise its write-gating directly.)
    func failOutgoingCall(_ reason: String) {
        // Pre-connect setup failure (identity unavailable / telephone.call threw),
        // so wasConnected is false and .failed is the reduced outcome.
        if let id = currentCallAttemptId {
            let repo = callHistoryRepository
            enqueueHistoryWrite {
                guard let repo else { return }
                try? await repo.recordEnd(id, at: Date(), outcome: .failed)
            }
            currentCallAttemptId = nil
            activeCallAttemptId = nil
        }
        callState = .ended(reason)
        endedDismissTask?.cancel()
        endedDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.resetState()
        }
    }
    #endif

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

        // Outgoing ringback may have been requested before CallKit activated
        // the audio session: handleCallerIdentified -> startRingback ->
        // ensureToneOutput returns nil while the session is inactive, so
        // ringbackActive stays false and the caller hears silence. Now that
        // the session is live, start it. startRingback() re-guards on
        // !isIncoming/!ringbackActive, and we gate on .ringing so we never
        // (re)start a tone after the call has connected or ended.
        if !isIncoming, callState == .ringing, !ringbackActive {
            DiagLog.log("[AUDIO] Session active while outgoing call ringing — starting deferred ringback")
            startRingback()
        }
    }

    /// Called by CallKitManager when the provider is reset (e.g., system
    /// force-stops all calls). Cleans up any active call state.
    func handleCallKitReset() {
        DiagLog.log("[CALL] handleCallKitReset() triggered")
        logger.info("CallKit provider reset — cleaning up call state")
        stopAudio()
        // Cancel ringback and clear ringbackActive — otherwise a reset during a
        // ringing outgoing call leaves the flag set and startRingback()'s
        // `guard !ringbackActive` suppresses ringback on every later call.
        stopRingback()
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
        // Begin the incoming history attempt now that the remote hash is known
        // (identify arrives after prepareForIncomingCall). Guard on nil so a
        // second identify callback can't start a second attempt for one call.
        // peerDisplayName is nil here: resolveContactName runs AFTER this point
        // (and asynchronously), so the snapshot can't hold the resolved name —
        // the Voice list (Task 4) enriches display names from the conversations
        // table. This nil is the best-effort fallback column, not the UI name.
        if currentCallAttemptId == nil {
            beginCallAttempt(direction: .incoming, peerDisplayName: nil)
        }

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
            #if DEBUG
            if ProcessInfo.processInfo.environment["COLUMBA_AUTO_ANSWER"] == "1" {
                self.logger.error("[CALL] COLUMBA_AUTO_ANSWER=1 — auto-answering")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    self?.answerCall()
                }
            }
            #endif
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
        // FIRST and synchronously (no await before this): mark the manager
        // torn-down. Suspended `initiateCall` tasks re-check this flag after
        // each suspension point and abort before touching call state or the
        // history store, so none of them can resume and create a fresh
        // attempt + write chain after the drain below. (The instance is not
        // reused after shutdown — AppServices nils it and recreates one per
        // identity — so the flag is one-way.)
        isShutDown = true
        stopAudio()

        // Finalize the active call-history attempt DETERMINISTICALLY, before
        // the hangup, and clear the attempt id so the (asynchronous) end
        // callback for that hangup can never enqueue a terminal write after
        // us. AppServices closes this manager's repository immediately after
        // shutdown() returns (identity switch), so the write must be in
        // flight before that — it cannot rely on the callback landing first.
        // CallManager is @MainActor and the end callback's enqueue runs on
        // the main actor too, so this clear is race-free with the callback:
        // whichever runs first wins, the other observes a nil id, and at most
        // ONE terminal write per attempt is ever enqueued. The outcome matches
        // what the end callback would record for a local hangup
        // (connectedEnded / declinedLocal / cancelledLocal).
        if let id = currentCallAttemptId {
            let direction: CallHistoryDirection = isIncoming ? .incoming : .outgoing
            let outcome = CallHistoryFormatting.outcome(direction: direction,
                                                        wasConnected: didConnect,
                                                        reason: .localHangup)
            let repo = callHistoryRepository
            enqueueHistoryWrite {
                guard let repo else { return }
                try? await repo.recordEnd(id, at: Date(), outcome: outcome)
            }
            currentCallAttemptId = nil
            activeCallAttemptId = nil
        }

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

        // Cancel + release any in-flight initiateCall task. It may be
        // suspended at a network await (destination resolution /
        // prepareOutboundCall / an in-flight telephone.call). Cancellation
        // stops its work; the `isShutDown` latch above is what CARRIES the
        // "no fresh attempt" guarantee (the task's gates abort before
        // beginCallAttempt on resumption). We deliberately do NOT await it:
        // a task stuck in a non-cancellable await would hang the app's
        // teardown, and the latch already makes a post-drain attempt
        // impossible, so observing the task finish buys nothing.
        #if COLUMBA_RUNTIME_PYTHON
        if let task = outgoingCallTask {
            task.cancel()
            outgoingCallTask = nil
        }
        #endif

        // Drain the call-history write chain BEFORE returning. The queue is
        // CLOSED at this point: the pre-hangup finalization above cleared the
        // attempt id (the end-callback, milestone, and fail paths all gate
        // their writes on it), and telephone is nil, so nothing new can be
        // enqueued. Awaiting each queued chain to completion is therefore
        // deterministic — no sleep-based idle heuristic — and the pending
        // finalization always lands before AppServices closes the repository.
        while let chain = historyWriteChain {
            historyWriteChain = nil
            await chain.value
        }
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
        // Real-device DEBUG only: the COLUMBA_AUTO_ANSWER test hook starts the
        // audio engine outside CallKit's session lifecycle, so it must never
        // ship; the simulator always defers (no real mic hardware). Both
        // simulator and release builds therefore force bypassCallKit false.
        #if DEBUG && !targetEnvironment(simulator)
        let bypassCallKit = ProcessInfo.processInfo.environment["COLUMBA_AUTO_ANSWER"] == "1"
        #else
        let bypassCallKit = false
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
    /// Wired from `Telephone.setDecodedAudioCallback` — fires when decoded audio
    /// frames arrive from the network. Schedules samples for immediate playback.
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
        stopRingback()  // clear ringbackActive so a later call's ringback isn't suppressed
        callState = .idle
        // Clear in-flight call-history attempt state so a stale id never lingers.
        // Finalize the record FIRST if a call is still active: a reset that
        // reaches here without a terminal callback (e.g. a CallKit provider
        // reset) must not strand the row — it is recorded as `interrupted`
        // (connected) or `notConnected` (not) with an end time, so the Voice
        // list can never show a dead call as "in progress" forever.
        if let id = currentCallAttemptId {
            let wasConnected = didConnect
            let outcome: CallOutcome = wasConnected ? .interrupted : .notConnected
            let repo = callHistoryRepository
            enqueueHistoryWrite {
                guard let repo else { return }
                try? await repo.recordEnd(id, at: Date(), outcome: outcome)
            }
        }
        currentCallAttemptId = nil
        activeCallAttemptId = nil
        callAttemptStartedAt = nil
        didConnect = false
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
