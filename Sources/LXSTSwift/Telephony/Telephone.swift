// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  Telephone.swift
//  LXSTSwift
//
//  Main telephony actor matching Python LXST Primitives/Telephony.py.
//  Manages call signaling over Reticulum Links.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lxst.swift", category: "Telephone")

/// Telephony actor for LXST voice calls over Reticulum links.
///
/// Manages the full call lifecycle: destination registration, incoming/outgoing
/// call setup, signal exchange, and teardown. Audio pipelines are stubbed —
/// this actor handles only signaling.
///
/// Matches Python `Telephone` class in `Primitives/Telephony.py`.
public actor Telephone {

    // MARK: - Properties

    /// Local identity for this telephone endpoint.
    public let identity: Identity

    /// Transport instance for sending/receiving packets.
    private let transport: ReticulumTransport

    /// RNS destination for incoming calls: (identity, IN, SINGLE, "lxst", "telephony").
    public let destination: Destination

    /// Current call state.
    public private(set) var callState: CallState = .idle

    /// Active call link (nil when idle).
    private var activeCall: Link?

    /// Whether this is an incoming or outgoing call.
    private var isIncoming: Bool = false

    /// Active telephony profile for the current call.
    private var activeProfile: TelephonyProfile?

    /// Remote peer's identity (after identification).
    private var remoteIdentity: Identity?

    // MARK: - Audio Pipeline

    /// Audio processing pipeline for encoding/decoding audio frames.
    private var audioPipeline: AudioPipeline?

    /// Link source for receiving remote audio frames.
    private var linkSource: LinkSource?

    /// Active codec for the current call.
    private var codec: (any AudioCodec)?

    /// Callback for delivering decoded PCM audio to the UI layer.
    private var decodedAudioCallback: (@Sendable ([Float], Int, Int) async -> Void)?

    /// Callback fired when the remote peer's preferred profile is negotiated.
    private var profileNegotiatedCallback: (@Sendable (TelephonyProfile) async -> Void)?

    /// Frame send counter for diagnostics.
    private var sentFrameCount: Int = 0

    /// Frame receive counter for diagnostics.
    private var receivedFrameCount: Int = 0

    // MARK: - Configuration

    /// Caller filtering. Python Telephony.py:123-124
    public var allowed: CallerFilter = .allowAll

    /// Ring timeout duration. Python Telephony.py:115
    public var ringTime: TimeInterval = TelephonyConstants.ringTime

    /// Outgoing call wait timeout. Python Telephony.py:116
    public var waitTime: TimeInterval = TelephonyConstants.waitTime

    /// Connect timeout. Python Telephony.py:117
    public var connectTimeout: TimeInterval = TelephonyConstants.connectTime

    // MARK: - Callbacks

    /// Called when an incoming call starts ringing.
    private var ringingCallback: (@Sendable (Identity) async -> Void)?

    /// Called when a call is established.
    private var establishedCallback: (@Sendable (Identity) async -> Void)?

    /// Called when a call ends.
    private var endedCallback: (@Sendable (Identity?, CallEndReason) async -> Void)?

    /// Diagnostic logging callback (set by app layer).
    public var onDiagnostic: (@Sendable (String) -> Void)?

    // MARK: - Timers

    /// Ring timeout task.
    private var ringTimeoutTask: Task<Void, Never>?

    /// Connect timeout task.
    private var connectTimeoutTask: Task<Void, Never>?

    /// If true, answer() was called before the Telephone reached .ringing state.
    /// handleCallerIdentified will auto-answer when it transitions to .ringing.
    private var pendingAnswer: Bool = false

    // MARK: - Initialization

    /// Create a new Telephone endpoint.
    ///
    /// Registers an RNS destination `(identity, IN, SINGLE, "lxst", "telephony")`
    /// for incoming calls and sets up the link established callback.
    ///
    /// - Parameters:
    ///   - identity: Local identity for this endpoint
    ///   - transport: Transport for sending/receiving
    public init(identity: Identity, transport: ReticulumTransport) async {
        self.identity = identity
        self.transport = transport

        // Create destination matching Python: Destination(identity, IN, SINGLE, APP_NAME, PRIMITIVE_NAME)
        self.destination = Destination(
            identity: identity,
            appName: TelephonyConstants.appName,
            aspects: [TelephonyConstants.primitiveName],
            type: .single,
            direction: .in
        )

        // Register destination with transport for incoming links
        await transport.registerDestination(destination)

        let destHex = self.destination.hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        logger.info("[TELEPHONE] Listening on \(destHex, privacy: .public)")
    }

    // MARK: - Callback Setters

    public func setRingingCallback(_ callback: @escaping @Sendable (Identity) async -> Void) {
        self.ringingCallback = callback
    }

    public func setEstablishedCallback(_ callback: @escaping @Sendable (Identity) async -> Void) {
        self.establishedCallback = callback
    }

    public func setEndedCallback(_ callback: @escaping @Sendable (Identity?, CallEndReason) async -> Void) {
        self.endedCallback = callback
    }

    /// Set callback fired when the remote sends a preferred profile signal.
    ///
    /// Called as soon as the remote's profile is known, before the call is established.
    /// Use this to configure the local audio pipeline (AudioManager) with the right
    /// codec parameters before `establishedCallback` fires.
    public func setProfileNegotiatedCallback(
        _ callback: (@Sendable (TelephonyProfile) async -> Void)?
    ) {
        self.profileNegotiatedCallback = callback
    }

    /// Set callback for receiving decoded PCM audio frames from the remote peer.
    ///
    /// Called by CallManager to receive audio for playback. Parameters:
    /// - samples: Float32 PCM samples (-1.0 to 1.0)
    /// - sampleRate: Sample rate in Hz
    /// - channels: Number of audio channels
    public func setDecodedAudioCallback(
        _ callback: @escaping @Sendable ([Float], Int, Int) async -> Void
    ) {
        self.decodedAudioCallback = callback
    }

    /// Set diagnostic logging callback.
    public func setDiagnostic(_ callback: @escaping @Sendable (String) -> Void) {
        self.onDiagnostic = callback
    }

    // MARK: - Audio Frame Send/Receive

    /// Send captured audio samples to the remote peer.
    ///
    /// Encodes the samples with the active codec and sends over the link.
    /// Called by CallManager with mic-captured PCM float samples.
    ///
    /// - Parameter samples: Float32 PCM samples from the microphone
    public func sendAudioFrame(_ samples: [Float]) async {
        guard callState == .established,
              activeCall != nil,
              let pipeline = audioPipeline,
              let codec = codec else {
            // Log why we're dropping the frame (first few only)
            if sentFrameCount == 0 {
                onDiagnostic?("[TEL] sendAudioFrame DROPPED: state=\(String(describing: callState)), link=\(activeCall != nil), pipeline=\(audioPipeline != nil), codec=\(codec != nil)")
            }
            return
        }

        sentFrameCount += 1
        if sentFrameCount == 1 || sentFrameCount % 50 == 0 {
            onDiagnostic?("[TEL] TX frame #\(sentFrameCount): \(samples.count) samples")
            logger.debug("[TELEPHONE] Sending frame #\(self.sentFrameCount, privacy: .public), samples=\(samples.count, privacy: .public)")
        }
        await pipeline.processCapture(samples, codec: codec)
    }

    // MARK: - Incoming Call Handling

    /// Handle an incoming link established event.
    ///
    /// Python `__incoming_link_established`: If busy, send BUSY and teardown.
    /// Otherwise, send AVAILABLE and wait for identification.
    ///
    /// - Parameter link: The newly established incoming link
    public func handleIncomingLink(_ link: Link) async {
        // Check if already in a call
        if activeCall != nil || callState != .idle {
            logger.warning("[TELEPHONE] Incoming call, but line busy — signalling BUSY")
            await sendSignal(.busy, on: link)
            await link.close()
            return
        }

        isIncoming = true

        // Set packet callback for signalling
        await link.setPacketCallback { [weak self] data, packet in
            await self?.handlePacket(data: data, packet: packet)
        }

        // Notify when caller closes the link (remote hangup or network failure)
        await link.setCloseCallback { [weak self] reason in
            await self?.handleLinkClosed(reason: reason)
        }

        // Set identify callback to receive caller identity
        await link.setIdentifyCallbacks(TelephoneIdentifyHandler(telephone: self))

        // Store link and send AVAILABLE
        activeCall = link
        transitionState(to: .available)
        await sendSignal(.available, on: link)
        logger.info("[TELEPHONE] Sent AVAILABLE to incoming link")
    }

    /// Handle caller identification (LINKIDENTIFY received).
    ///
    /// Python `__caller_identified`: Check if allowed, send RINGING, start timer.
    ///
    /// - Parameters:
    ///   - link: The link that identified
    ///   - identity: The caller's verified identity
    func handleCallerIdentified(_ remoteId: Identity) async {
        guard let link = activeCall else { return }

        // Check if caller is allowed
        if !isAllowed(remoteId) {
            logger.warning("[TELEPHONE] Caller \(remoteId.hash.prefix(4).map { String(format: "%02x", $0) }.joined(), privacy: .public) not allowed, BUSY")
            await sendSignal(.busy, on: link)
            await link.close()
            resetCallState()
            return
        }

        remoteIdentity = remoteId
        transitionState(to: .ringing)
        await sendSignal(.ringing, on: link)
        logger.info("[TELEPHONE] Sent RINGING")

        // If user already tapped answer before we reached .ringing, auto-answer now
        if pendingAnswer {
            pendingAnswer = false
            logger.info("[TELEPHONE] Pending answer detected, auto-answering")
            await answer()
            return
        }

        // Notify callback
        await ringingCallback?(remoteId)

        // Start ring timeout
        startRingTimeout()
    }

    // MARK: - Answer / Hangup

    /// Answer an incoming ringing call.
    ///
    /// Python `answer()`: send CONNECTING, open pipelines, send ESTABLISHED.
    public func answer() async {
        // If not yet in .ringing (e.g., still waiting for LINKIDENTIFY),
        // set a flag so handleCallerIdentified will auto-answer.
        if callState != .ringing && isIncoming && activeCall != nil {
            logger.info("[TELEPHONE] answer() called in state \(String(describing: self.callState)), deferring until .ringing")
            pendingAnswer = true
            return
        }

        guard callState == .ringing, let link = activeCall, isIncoming else {
            logger.warning("[TELEPHONE] Cannot answer: state=\(String(describing: self.callState))")
            return
        }

        cancelTimers()
        onDiagnostic?("[TEL] answer(): sending CONNECTING, profile=\(String(describing: activeProfile?.displayName))")
        transitionState(to: .connecting)
        await sendSignal(.connecting, on: link)

        await startAudioPipeline()
        onDiagnostic?("[TEL] answer(): pipeline started, linkSource=\(linkSource != nil), codec=\(String(describing: codec?.codecType))")

        transitionState(to: .established)
        await sendSignal(.established, on: link)
        onDiagnostic?("[TEL] answer(): sent ESTABLISHED, calling establishedCallback")
        logger.info("[TELEPHONE] Call ESTABLISHED (incoming)")

        if let remote = remoteIdentity {
            await establishedCallback?(remote)
            onDiagnostic?("[TEL] answer(): establishedCallback done")
        }
    }

    /// Hang up the active call.
    ///
    /// Python `hangup()`: If ringing and incoming, send REJECTED. Teardown link.
    public func hangup() async {
        guard let link = activeCall else { return }
        onDiagnostic?("[TEL] hangup(): callState=\(String(describing: callState)), frames=\(receivedFrameCount)")

        cancelTimers()
        await stopAudioPipeline()

        // If ringing and incoming, send REJECTED
        if isIncoming && callState == .ringing {
            await sendSignal(.rejected, on: link)
        }

        // Clear close callback before closing so we don't get a spurious handleLinkClosed
        await link.setCloseCallback(nil)

        let linkState = await link.state
        if linkState.isEstablished {
            await link.close()
        }

        let reason: CallEndReason = .localHangup
        let remote = remoteIdentity
        resetCallState()
        transitionState(to: .ended(reason))
        await endedCallback?(remote, reason)
        transitionState(to: .idle)
    }

    // MARK: - Outgoing Call

    /// Initiate an outgoing call.
    ///
    /// Python `call()`: Create link, wait for AVAILABLE, identify, negotiate.
    ///
    /// - Parameters:
    ///   - remoteIdentity: Identity of the person to call
    ///   - profile: Preferred telephony profile (default: QUALITY_MEDIUM)
    public func call(remoteIdentity: Identity, profile: TelephonyProfile = .qualityMedium) async throws {
        guard callState == .idle, activeCall == nil else {
            throw LXSTError.alreadyInCall
        }

        isIncoming = false
        activeProfile = profile
        self.remoteIdentity = remoteIdentity  // Store so establishedCallback fires on ESTABLISHED
        transitionState(to: .calling)
        logger.info("[TELEPHONE] call() entered, creating destination")

        // Create outbound destination
        let callDest = Destination(
            identity: remoteIdentity,
            appName: TelephonyConstants.appName,
            aspects: [TelephonyConstants.primitiveName],
            type: .single,
            direction: .out
        )
        let destHex = callDest.hash.map { String(format: "%02x", $0) }.joined()
        logger.debug("[TELEPHONE] callDest hash=\(destHex, privacy: .public)")

        // Ensure a path to the telephony destination exists.
        // If not cached, this sends a PATH REQUEST and waits up to 10s for a response.
        // Without a path, the relay can't route our LINKREQUEST to the remote peer.
        logger.info("[TELEPHONE] Awaiting path to telephony destination...")
        let pathFound = await transport.awaitPath(for: callDest.hash, timeout: 10.0)
        logger.info("[TELEPHONE] Path found: \(pathFound, privacy: .public)")

        // Use transport.initiateLink() which:
        //   1. Checks the path (throws noPathAvailable if still missing)
        //   2. Creates the Link and registers it in pendingLinks
        //   3. Sends the LINKREQUEST — so LINKPROOF is matched correctly when it arrives
        let link = try await transport.initiateLink(to: callDest, identity: identity)
        activeCall = link
        logger.info("[TELEPHONE] Link initiated, setting packet callback")

        // Set packet callback for DATA signalling packets (arrives after link is established)
        await link.setPacketCallback { [weak self] data, packet in
            await self?.handlePacket(data: data, packet: packet)
        }

        // Notify when remote closes the link (remote hangup or network failure)
        await link.setCloseCallback { [weak self] reason in
            await self?.handleLinkClosed(reason: reason)
        }

        // Start connect timeout
        startConnectTimeout()

        logger.info("[TELEPHONE] Outgoing call initiated")
    }

    // MARK: - Signal Handling

    /// Handle received packet data on the active call link.
    ///
    /// Python `signalling_received()`: Dispatch signals.
    private func handlePacket(data: Data, packet: Packet) async {
        let first4 = data.prefix(4).map { String(format: "%02x", $0) }.joined()
        if receivedFrameCount == 0 {
            onDiagnostic?("[TEL] handlePacket first: \(data.count) bytes, first4=\(first4)")
        }
        logger.debug("[TELEPHONE] handlePacket: \(data.count, privacy: .public) bytes, first4=\(first4, privacy: .public)")
        guard let parsed = try? LXSTWireFormat.unpack(data) else {
            onDiagnostic?("[TEL] unpack FAILED: \(data.count) bytes, first4=\(first4)")
            logger.error("[TELEPHONE] unpack FAILED for \(data.count, privacy: .public) bytes, first4=\(first4, privacy: .public)")
            return
        }

        switch parsed {
        case .signals(let signals):
            for signal in signals {
                await handleSignal(signal)
            }
        case .mixed(let signals, _, _):
            for signal in signals {
                await handleSignal(signal)
            }
            // Also route the audio frame portion to the pipeline.
            await routeAudioFrame(data: data, packet: packet)
        case .frame:
            await routeAudioFrame(data: data, packet: packet)
        }
    }

    /// Route an audio frame packet to the link source for decoding.
    ///
    /// Auto-starts the audio pipeline if CONNECTING/ESTABLISHED were never received
    /// (Android's Chaquopy bridge doesn't reliably deliver those signals).
    private func routeAudioFrame(data: Data, packet: Packet) async {
        receivedFrameCount += 1
        if receivedFrameCount == 1 || receivedFrameCount % 100 == 0 {
            onDiagnostic?("[TEL] audioFrame #\(receivedFrameCount): \(data.count)B, linkSource=\(linkSource != nil)")
            logger.debug("[TELEPHONE] Received audio frame #\(self.receivedFrameCount, privacy: .public), bytes=\(data.count, privacy: .public)")
        }
        if linkSource == nil {
            guard callState != .idle else {
                logger.warning("[TELEPHONE] Dropping stray audio frame received after hangup (callState=idle)")
                return
            }
            logger.warning("[TELEPHONE] Auto-starting audio pipeline on first frame (CONNECTING not received)")
            await startAudioPipeline()
            cancelTimers()
            transitionState(to: .established)
            if let remote = remoteIdentity {
                await establishedCallback?(remote)
            }
        }
        if let source = linkSource {
            await source.handlePacket(data: data, packet: packet)
        } else {
            logger.error("[TELEPHONE] Received audio frame but linkSource still nil after auto-start!")
        }
    }

    /// Handle a single signal value.
    ///
    /// Python `signalling_received()` lines 683-729.
    private func handleSignal(_ signal: UInt) async {
        guard let link = activeCall else { return }

        // Check for preferred profile signal (>= 0xFF)
        if let profile = LXSTWireFormat.extractPreferredProfile(from: signal) {
            activeProfile = profile
            onDiagnostic?("[TEL] PREFERRED_PROFILE: \(profile.displayName)")
            logger.info("[TELEPHONE] Remote preferred profile: \(profile.displayName, privacy: .public)")
            await profileNegotiatedCallback?(profile)
            return
        }

        guard let signalCode = LXSTWireFormat.extractSignal(from: signal) else { return }

        switch signalCode {
        case .busy:
            onDiagnostic?("[TEL] signal: BUSY")
            logger.info("[TELEPHONE] Remote is BUSY")
            cancelTimers()
            let remote = remoteIdentity
            await link.close()
            resetCallState()
            transitionState(to: .ended(.busy))
            await endedCallback?(remote, .busy)
            transitionState(to: .idle)

        case .rejected:
            onDiagnostic?("[TEL] signal: REJECTED")
            logger.info("[TELEPHONE] Remote REJECTED call")
            cancelTimers()
            let remote = remoteIdentity
            await link.close()
            resetCallState()
            transitionState(to: .ended(.rejected))
            await endedCallback?(remote, .rejected)
            transitionState(to: .idle)

        case .available:
            // Callee is available — send identification
            logger.info("[TELEPHONE] Remote AVAILABLE, identifying...")
            transitionState(to: .available)
            try? await link.identify(identity: identity)

        case .ringing:
            // Callee is ringing — send preferred profile
            logger.info("[TELEPHONE] Remote is RINGING")
            transitionState(to: .ringing)
            if let profile = activeProfile {
                await sendPreferredProfile(profile, on: link)
            }
            if let remote = remoteIdentity {
                await ringingCallback?(remote)
            }

        case .connecting:
            // Callee answered, setting up pipelines
            logger.info("[TELEPHONE] Remote CONNECTING")
            transitionState(to: .connecting)
            cancelTimers()
            await startAudioPipeline()

        case .established:
            // Call fully established
            if !isIncoming {
                logger.info("[TELEPHONE] Call ESTABLISHED (outgoing)")
                transitionState(to: .established)
                cancelTimers()
                if let remote = remoteIdentity {
                    await establishedCallback?(remote)
                }
            }

        case .calling:
            break
        }
    }

    // MARK: - Signal Sending

    /// Send a signal over a link.
    private func sendSignal(_ signal: LXSTSignal, on link: Link) async {
        let data = LXSTWireFormat.packSignal(signal)
        await sendData(data, on: link)
    }

    /// Send a preferred profile signal.
    private func sendPreferredProfile(_ profile: TelephonyProfile, on link: Link) async {
        let data = LXSTWireFormat.packPreferredProfile(profile)
        await sendData(data, on: link)
    }

    /// Send raw data as a link DATA packet (context 0x00).
    ///
    /// Python `RNS.Link.send(data)` wraps the bytes in an RNS.Packet with the
    /// link's session key applied, so on iOS this just hands the plaintext to
    /// the Compat `Link.sendBytes(_:)` hook — AppServices installed that hook
    /// to forward through `PythonRNSBackend.linkSend(linkId:data:)`.
    private var sendDataCount: Int = 0
    private func sendData(_ data: Data, on link: Link) async {
        sendDataCount += 1
        do {
            try await link.sendBytes(data)
            if sendDataCount <= 3 || sendDataCount % 50 == 0 {
                onDiagnostic?("[TEL] sendData #\(sendDataCount): \(data.count)B")
            }
        } catch {
            onDiagnostic?("[TEL] sendData FAILED #\(sendDataCount): \(error)")
            logger.error("[TELEPHONE] Failed to send data: \(error)")
        }
    }

    // MARK: - Link Closed Handler

    /// Handle link closure (remote hangup or network failure).
    func handleLinkClosed(reason: TeardownReason) async {
        guard activeCall != nil else { return }
        onDiagnostic?("[TEL] handleLinkClosed: reason=\(reason), callState=\(String(describing: callState)), frames=\(receivedFrameCount)")

        cancelTimers()
        await stopAudioPipeline()
        let remote = remoteIdentity
        let endReason: CallEndReason = (reason == .destinationClosed) ? .remoteHangup : .linkClosed
        resetCallState()
        transitionState(to: .ended(endReason))
        await endedCallback?(remote, endReason)
        transitionState(to: .idle)
    }

    // MARK: - Audio Pipeline Management

    /// Create and start the audio pipeline for the current call.
    ///
    /// Creates the codec from the active profile (tries Opus/Codec2 first,
    /// falls back to NullCodec), sets up the AudioPipeline and LinkSource,
    /// and wires callbacks for encoding/decoding audio.
    private func startAudioPipeline() async {
        let profile = activeProfile ?? .qualityMedium

        // Create codec: try real codec first, fall back to NullCodec
        let activeCodec: any AudioCodec
        switch profile.codecType {
        case .opus:
            if let opusProfile = profile.opusProfile,
               let opus = try? OpusCodec(profile: opusProfile) {
                activeCodec = opus
                logger.info("[TELEPHONE] Using OpusCodec: \(opusProfile.sampleRate)Hz, \(opusProfile.channels)ch, \(profile.frameTimeMs)ms")
            } else {
                activeCodec = NullCodec()
                logger.error("[TELEPHONE] OpusCodec creation FAILED — falling back to NullCodec")
            }
        case .codec2:
            if let c2Mode = profile.codec2Mode,
               let c2 = try? Codec2Codec(mode: c2Mode) {
                activeCodec = c2
                logger.info("[TELEPHONE] Using Codec2Codec: mode=\(String(describing: c2Mode))")
            } else {
                activeCodec = NullCodec()
                logger.error("[TELEPHONE] Codec2Codec creation FAILED — falling back to NullCodec")
            }
        default:
            activeCodec = NullCodec()
            logger.info("[TELEPHONE] Using NullCodec for profile \(profile.displayName)")
        }
        self.codec = activeCodec

        // Create pipeline
        let pipelineConfig = AudioPipeline.Config(profile: profile)
        let pipeline = AudioPipeline(config: pipelineConfig)
        self.audioPipeline = pipeline

        // Create link source for receiving remote audio
        let source = LinkSource()
        self.linkSource = source

        // Wire link source frame callback → pipeline decode → decoded samples callback
        let codecRef = activeCodec
        await source.setFrameCallback { [weak pipeline] codecType, audioData in
            guard let pipeline = pipeline else { return }
            await pipeline.processReceived(audioData, codec: codecRef)
        }

        // Wire pipeline encoded frame callback → pack → send over link
        await pipeline.setEncodedFrameCallback { [weak self] codecType, encodedData in
            guard let self = self else { return }
            let packed = LXSTWireFormat.packFrame(codecType: codecType, encodedAudio: encodedData)
            if let link = await self.activeCall {
                await self.sendData(packed, on: link)
            }
        }

        // Wire pipeline decoded samples callback → forward to UI
        await pipeline.setDecodedSamplesCallback { [weak self] samples, rate, channels in
            guard let self = self else { return }
            await self.decodedAudioCallback?(samples, rate, channels)
        }

        // Start components
        await pipeline.start(codec: activeCodec)
        await source.start()

        logger.info("[TELEPHONE] Audio pipeline started: codec=\(String(describing: activeCodec.codecType)), profile=\(profile.displayName)")
    }

    /// Stop and tear down the audio pipeline.
    private func stopAudioPipeline() async {
        await audioPipeline?.stop()
        await linkSource?.stop()
        audioPipeline = nil
        linkSource = nil
        codec = nil
    }

    // MARK: - State Management

    private func transitionState(to newState: CallState) {
        callState = newState
    }

    private func resetCallState() {
        activeCall = nil
        remoteIdentity = nil
        isIncoming = false
        activeProfile = nil
        pendingAnswer = false
        sentFrameCount = 0
        receivedFrameCount = 0
    }

    // MARK: - Caller Filtering

    private func isAllowed(_ remoteId: Identity) -> Bool {
        switch allowed {
        case .allowAll:
            return true
        case .allowNone:
            return false
        case .allowList(let hashes):
            return hashes.contains(remoteId.hash)
        }
    }

    // MARK: - Timers

    private func startRingTimeout() {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.ringTime ?? 60))
            guard !Task.isCancelled else { return }
            await self?.handleRingTimeout()
        }
    }

    private func startConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.waitTime ?? 70))
            guard !Task.isCancelled else { return }
            await self?.handleConnectTimeout()
        }
    }

    private func cancelTimers() {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    private func handleRingTimeout() async {
        guard callState == .ringing else { return }
        logger.warning("[TELEPHONE] Ring timeout")
        let remote = remoteIdentity
        if let link = activeCall {
            await link.close()
        }
        resetCallState()
        transitionState(to: .ended(.ringTimeout))
        await endedCallback?(remote, .ringTimeout)
        transitionState(to: .idle)
    }

    private func handleConnectTimeout() async {
        guard callState == .calling || callState == .available else { return }
        logger.warning("[TELEPHONE] Connect timeout")
        let remote = remoteIdentity
        if let link = activeCall {
            await link.close()
        }
        resetCallState()
        transitionState(to: .ended(.connectTimeout))
        await endedCallback?(remote, .connectTimeout)
        transitionState(to: .idle)
    }
}

// MARK: - Caller Filter

/// Caller filtering configuration.
public enum CallerFilter: Sendable {
    /// Allow all callers. Python Telephony.py:123
    case allowAll
    /// Allow no callers. Python Telephony.py:124
    case allowNone
    /// Allow only specific identity hashes.
    case allowList([Data])
}

// MARK: - Identity Callback Handler

/// Bridge between Link's IdentifyCallbacks and Telephone actor.
final class TelephoneIdentifyHandler: IdentifyCallbacks, @unchecked Sendable {
    private weak var telephone: Telephone?

    init(telephone: Telephone) {
        self.telephone = telephone
    }

    func remoteIdentified(_ identity: Identity) async {
        await telephone?.handleCallerIdentified(identity)
    }
}
