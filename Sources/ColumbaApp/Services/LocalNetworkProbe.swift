//
//  LocalNetworkProbe.swift
//  ColumbaApp
//
//  Triggers the iOS Local Network permission prompt (if it has not been shown
//  yet) and reports the outcome, so a denied / never-prompted state is visible
//  instead of silently dead.
//
//  Background: Columba's Auto Discovery interface talks over raw IPv6 link-local
//  multicast from the embedded Python (RNS). iOS 14+ gates local-network access
//  behind a one-shot permission, but the system only raises the prompt when the
//  app actually performs a local-network operation through a path the OS can
//  intercept. A raw-socket multicast join can fail to trigger the prompt at all
//  (the "0 interfaces, never prompted, silently dead" dead-end). There is also
//  no public API to *read* the current Local Network authorization state.
//
//  This probe uses the composite technique that reliably (a) raises the prompt
//  and (b) determines the answer:
//    1. Start an `NWBrowser` for a declared Bonjour service type. Browsing is
//       the OS-recognized local-network operation that makes the system show the
//       prompt when the permission is still undetermined.
//    2. Concurrently publish an `NSNetService` of the same type. Its
//       `netServiceDidPublish` delegate callback fires only when access is
//       granted, giving us a positive grant signal (the browser reaching `.ready`
//       alone is not a reliable grant confirmation on every iOS version).
//    3. If the user denies, the `NWBrowser` transitions to `.waiting(error)` -
//       that is our denial signal.
//
//  The service type MUST be listed in `Info.plist` `NSBonjourServices`, or the
//  browser silently fails to trigger the prompt. See `LocalNetworkProbe
//  .probeServiceType` and the matching plist entry.
//
//  The probe is discovery-only: it publishes a single static, ephemeral service
//  name carrying no user data, stopped as soon as the outcome is known. It does
//  NOT require the multicast entitlement (that is a separate, still-off concern
//  for RNS's raw sockets).
//

import Foundation
import Network

/// The outcome of a Local Network permission probe.
public enum LocalNetworkPermission: String, Equatable, Sendable {
    /// Access is granted (previously allowed, or the user just allowed it).
    case granted
    /// Access is denied (the user denied the prompt, or a prior decision denied it).
    case denied
    /// No definitive signal within the probe window. Callers should fail-open
    /// (attempt the local operation anyway) rather than assume denial.
    case unknown
}

/// Coarse Local Network health for the Auto Discovery interface, surfaced in
/// the Manage Interfaces UI. Derived from the permission outcome and the
/// AutoInterface's live adopted-interface count.
public enum LocalNetworkHealthState: Equatable, Sendable {
    /// Local Network access is granted AND the AutoInterface has adopted at
    /// least one system interface - discovery is healthy.
    case healthy
    /// Access is granted but the AutoInterface adopted zero interfaces (the
    /// cold-start-before-link-local case). Carrier re-adopt is armed; the UI
    /// shows a transient "reconnecting" note rather than a hard error.
    case noCarrier
    /// The user denied Local Network access (or it was denied earlier). The
    /// UI shows a warning with an Open Settings action. This is the state that
    /// was previously invisible - the interface silently failed to bind.
    case denied
    /// No AutoInterface is enabled, so Local Network state is not applicable.
    case notConfigured
}

/// Triggers the Local Network permission prompt and reports the result.
///
/// Usage: `let result = await LocalNetworkProbe().probe()`. Each call is
/// self-contained and short-lived (a few seconds at most); the browser and
/// service are torn down before the continuation resumes. Idempotent - re-
/// probing after the prompt has already been answered simply re-confirms the
/// current state without showing the prompt again.
///
/// Thread safety: every state mutation and callback (NWBrowser state handler
/// on `.main`, NSNetService delegate on the main run loop, dispatch work items
/// on main) runs on the main queue, so the instance is serialized without a
/// lock and safe to hand across executors. Hence `@unchecked Sendable`.
public final class LocalNetworkProbe: NSObject, NetServiceDelegate, @unchecked Sendable {

    /// Bonjour service type used to trigger + confirm Local Network access.
    /// Declared in `Info.plist` `NSBonjourServices`. Distinct from the real
    /// `_reticulum._tcp` protocol type so the probe never advertises a service
    /// that a real peer could mistake for a Reticulum endpoint.
    public static let probeServiceType = "_columba-lnp._tcp"
    public static let probeDomain = "local."
    private static let probeName = "columba-lnp-probe"

    private var browser: NWBrowser?
    private var netService: NetService?
    private var continuation: CheckedContinuation<LocalNetworkPermission, Never>?
    private var timeoutItem: DispatchWorkItem?
    private var readyGraceItem: DispatchWorkItem?
    private var resolved = false

    public override init() {
        super.init()
    }

    /// Trigger the prompt (if undetermined) and report the outcome.
    ///
    /// - Parameter timeout: Fail-open window. If neither a grant nor a denial
    ///   signal arrives within this long, returns `.unknown` (callers attempt
    ///   the operation anyway). Defaults to 10s, which comfortably covers the
    ///   time a user takes to answer the system prompt.
    public func probe(timeout: TimeInterval = 10) async -> LocalNetworkPermission {
        await withCheckedContinuation { (cont: CheckedContinuation<LocalNetworkPermission, Never>) in
            self.continuation = cont
            self.resolved = false
            // All state mutation + callback handling runs on the main queue
            // (NWBrowser state handler on `.main`; NSNetService delegate on the
            // main run loop; work items on main), so `self` is serialized
            // without an actor.
            DispatchQueue.main.async {
                self.begin(timeout: timeout)
            }
        }
    }

    // MARK: - Probe lifecycle (main queue)

    private func begin(timeout: TimeInterval) {
        // 1. Trigger: browsing a declared type is the operation that makes the
        //    OS raise the Local Network prompt when the permission is
        //    undetermined.
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(Self.probeServiceType, Self.probeDomain), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .waiting(let error):
                    // .waiting WITHOUT an error means the system prompt is
                    // still on screen (or not yet raised) - keep waiting.
                    // .waiting WITH an error is a (prior) denial: the browse
                    // cannot proceed.
                    if error != nil {
                        self.finish(.denied)
                    }
                case .ready:
                    // The prompt was answered "Allow" (or already granted). The
                    // publish callback is the authoritative grant confirmation;
                    // give it a short grace, then trust the browser if the
                    // callback is slow.
                    self.finish(.granted, afterGrace: 1.5)
                case .failed, .cancelled, .shuttingDown, .setup:
                    break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser

        // 2. Confirmation: publish fires `netServiceDidPublish` only when access
        //    is actually granted.
        let service = NetService(domain: Self.probeDomain, type: Self.probeServiceType, name: Self.probeName)
        service.delegate = self
        self.netService = service
        service.publish()

        // 3. Fail-open timeout.
        let item = DispatchWorkItem { [weak self] in self?.finish(.unknown) }
        self.timeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    private func finish(_ result: LocalNetworkPermission, afterGrace: TimeInterval? = nil) {
        guard !resolved else { return }
        if let grace = afterGrace {
            // Defer the grant a short window so an imminent `netServiceDidPublish`
            // (or a `.waiting(error)` denial) can land first.
            let item = DispatchWorkItem { [weak self] in self?.finish(.granted) }
            self.readyGraceItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: item)
            return
        }
        resolved = true
        timeoutItem?.cancel()
        timeoutItem = nil
        readyGraceItem?.cancel()
        readyGraceItem = nil
        browser?.cancel()
        browser = nil
        netService?.stop()
        netService = nil
        let cont = continuation
        continuation = nil
        cont?.resume(returning: result)
    }

    // MARK: - NetServiceDelegate (main run loop)

    public func netServiceDidPublish(_ netService: NetService) {
        DispatchQueue.main.async { [weak self] in
            self?.finish(.granted)
        }
    }

    // `didNotPublish` is not a definitive denial (it can be a transient bind
    // hiccup); the browser state and the timeout are the authoritative signals,
    // so we intentionally do not resolve from it.
}
