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
//    3. If the user denies, the `NWBrowser` transitions to `.waiting` with
//       the Bonjour `kDNSServiceErr_PolicyDenied` (-65570) error - that
//       specific error is our denial signal (per Apple TN3179). Other
//       waiting errors are transient, not denials.
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
    /// Domain/zone for the probe, the DEFAULT local zone. `NWBrowser` takes
    /// the zone NAME (nil = the default "local" zone) and `NetService` takes
    /// "" for the default domain. Passing the literal "local." (a zone
    /// string) to `NetService` is an NSException -> SIGABRT on publish, which
    /// crashed the app on first device launch (iOS 26.6, 2026-09-13).
    public static let probeDomain = ""
    private static let probeName = "columba-lnp-probe"

    /// `kDNSServiceErr_PolicyDenied` from dns_sd.h (-65570). Per Apple
    /// TN3179 this is the only Bonjour error that means Local Network
    /// permission is denied; every other waiting error (no usable path,
    /// DNS hiccup, carrier down) is transient and must NOT be read as a
    /// denial.
    private static let policyDeniedCode = -65570

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
        //    undetermined. nil domain = the default local zone.
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.probeServiceType, domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.handleBrowserState(state)
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

    // MARK: - Browser state (main queue)

    /// Interpret an NWBrowser state transition for the probe.
    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .waiting(let error):
            // `.waiting` always carries an `NWError` (the payload is
            // non-optional). Only the Bonjour
            // `kDNSServiceErr_PolicyDenied` (-65570) means the Local Network
            // permission was denied (TN3179). Every other error - no usable
            // network path, transient DNS state, the browser still waiting on
            // the prompt - is NOT a denial: a device that cold-starts with no
            // usable carrier must stay pending (the timeout resolves it as
            // `.unknown`, i.e. fail-open) rather than being marked denied,
            // which would suppress carrier re-adopt and wrongly point the user
            // at the Local Network permission in Settings.
            if Self.isPolicyDenied(error) {
                self.finish(.denied)
            }
        case .ready:
            // The prompt was answered "Allow" (or already granted). The
            // publish callback is the authoritative grant confirmation; give
            // it a short grace, then trust the browser if it is slow.
            self.finish(.granted, afterGrace: 1.5)
        case .failed, .cancelled, .setup:
            break
        }
    }

    /// Whether a `NWBrowser` waiting error is the Local Network
    /// policy-denial signal (Bonjour `kDNSServiceErr_PolicyDenied`, -65570,
    /// surfaced as `NWError.dns` per Apple TN3179). Everything else is a
    /// transient transport/DNS state, not a permission denial.
    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error {
            return Int(code) == policyDeniedCode
        }
        return false
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
