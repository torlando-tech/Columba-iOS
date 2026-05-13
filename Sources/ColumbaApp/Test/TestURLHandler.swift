//
//  TestURLHandler.swift
//  ColumbaApp
//
//  Debug-only URL-scheme dispatcher for the iOS phone harness.
//
//  The Android side uses an explicit BroadcastReceiver. iOS doesn't have
//  a runtime-broadcast surface, so we register a sibling URL scheme
//  (`lxma-test://`) and route inside the existing `.onOpenURL { … }` in
//  `ColumbaApp.swift` to this dispatcher.
//
//  Wrapped in `#if DEBUG` so the entire dispatcher is compiled out of
//  release builds. The release Info.plist also does NOT register
//  `lxma-test` (see Resources/Info.plist) — the scheme is added at
//  runtime in handleURL() only when DEBUG is set, by way of the URL
//  handler itself being a no-op compile-out. iOS won't route to this
//  handler in release because:
//    1. The scheme isn't in CFBundleURLSchemes (no system route).
//    2. Even if a misconfigured plist included it, this whole file is
//       not compiled, so nothing in the app binary handles the scheme.
//

#if DEBUG

import Foundation
import os.log
import LXMFSwift
#if ENABLE_NETWORK_EXTENSION
import NetworkExtension
#endif

/// Top-level dispatcher invoked from `ColumbaApp.swift`'s `.onOpenURL`.
///
/// Returns `true` if the URL was a `lxma-test://` action that this
/// handler consumed (the caller should NOT also feed the URL into the
/// production deeplink path); `false` for any URL we don't recognize so
/// the production handler still runs.
@MainActor
public enum TestURLHandler {

    /// Bind to live AppServices (called once, from RootView's task block
    /// when the test surface is enabled and AppServices is initialized).
    /// Wires the [TestController]'s closures to the real `AppServices`
    /// + router + interfaces + path table.
    public static func bind(appServices: AppServices) {
        guard let router = appServices.router else {
            TestLog.emit("bind_err reason=router_nil")
            return
        }
        let interfaceRepo = InterfaceRepository()
        let destHash = appServices.localIdentityHash
        TestController.shared.bind(
            appServices: appServices,
            router: router,
            interfaceRepo: interfaceRepo,
            destHash: destHash
        )

        // Populate the bridge closures so TestController can drive
        // path lookups, sends, announces without importing AppServices.
        TestPathBridge.hasPath = { [weak appServices] destHash in
            guard let svc = appServices, let pathTable = svc.pathTable else { return false }
            // PathTable is an actor; cross the actor boundary explicitly.
            return await pathTable.hasPath(for: destHash)
        }
        TestPathBridge.send = { [weak appServices] destHash, text, method in
            guard let svc = appServices, let identity = svc.identity, let router = svc.router else {
                throw TestError.notReady
            }
            var message = LXMessage(
                destinationHash: destHash,
                sourceIdentity: identity,
                content: text.data(using: .utf8) ?? Data(),
                title: Data(),
                fields: nil,
                desiredMethod: method
            )
            try await router.handleOutbound(&message)
            return message.hash
        }
        TestPathBridge.announce = { [weak appServices] in
            guard let svc = appServices else {
                throw TestError.notReady
            }
            try await svc.sendAnnounce(displayName: "Columba")
        }
        TestPathBridge.selectPropNode = { [weak appServices] hash in
            guard let svc = appServices, let mgr = svc.propagationManager else {
                // Falls back to the router-level setter inside
                // handleSetPropNode if this bridge isn't populated.
                return
            }
            await mgr.selectNode(hash: hash)
        }

        #if ENABLE_NETWORK_EXTENSION
        // Tunnel-control bridge: lets the smoke harness bring the
        // Background-Transport tunnel up from a URL action so the
        // `suspended_notification` scenario can guarantee the extension
        // is alive across the suspend window.
        //
        // Deliberately does NOT persist `tunnelEnabledKey` — the
        // Settings toggle path persists it so a cold relaunch auto-
        // restarts the tunnel, but tests are ephemeral: persisting
        // would poison every subsequent test run with auto-tunnel-on,
        // and the in-flight transition would race the harness's
        // bringup (path discovery) and break baseline scenarios.
        // Tests that need the tunnel call this every run; the persisted
        // flag stays off across runs.
        TestTunnelBridge.enableTunnel = { [weak appServices] in
            guard let svc = appServices, let tunnel = svc.tunnelManager else {
                throw TestError.notReady
            }
            if tunnel.isRunning {
                return Self.tunnelStatusString(tunnel.status)
            }
            try await tunnel.start()
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, tunnel.status != .connected {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return Self.tunnelStatusString(tunnel.status)
        }
        TestTunnelBridge.getTunnelStatus = { [weak appServices] in
            guard let svc = appServices, let tunnel = svc.tunnelManager else {
                return "no_tunnel"
            }
            return Self.tunnelStatusString(tunnel.status)
        }
        #endif

        // Attach the relay delegate so received messages + delivery
        // state changes get observed for the harness. Forwards to the
        // existing IncomingMessageHandler.
        Task { @MainActor in
            // The router's currently-set delegate is reachable as
            // `await router.delegate` if exposed, but LXMRouter's API
            // doesn't expose it. We approximate by passing nil and
            // accepting that during a test run the harness observer is
            // the only delegate. The production IncomingMessageHandler
            // remains wired through AppServices initialization, but the
            // harness deliberately runs against a debug build that
            // doesn't need its UI hooks.
            await TestController.shared.attachDelegate(
                to: router,
                originalDelegate: nil
            )
        }
    }

    /// Dispatch a single `lxma-test://<action>?<query>` URL. Returns
    /// `true` if consumed.
    @discardableResult
    public static func handle(url: URL) -> Bool {
        guard url.scheme == "lxma-test" else { return false }

        // Defense-in-depth: this file is `#if DEBUG`, but the assertion
        // also fires if someone mis-builds a release with DEBUG on.
        assertionFailure_releaseGuard()

        TestLog.emit("rx_url action=\(url.host ?? "<missing>") path=\(url.path)")

        // The convention is `lxma-test://<action>?<query>`. URLComponents
        // surfaces <action> as the host (because it's the authority
        // component of the URL), which mirrors `am broadcast`'s
        // action-string contract on Android.
        let action = (url.host ?? "").lowercased()
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query: [String: String] = Dictionary(
            uniqueKeysWithValues: (comps?.queryItems ?? [])
                .compactMap { item -> (String, String)? in
                    guard let v = item.value else { return nil }
                    return (item.name, v)
                }
        )

        let c = TestController.shared

        switch action {
        case "get_dest":
            c.handleGetDest()
        case "has_path":
            c.handleHasPath(toHex: query["to"] ?? "")
        case "send_direct":
            c.handleSend(method: .direct, toHex: query["to"] ?? "", text: query["text"] ?? "")
        case "send_opp":
            c.handleSend(method: .opportunistic, toHex: query["to"] ?? "", text: query["text"] ?? "")
        case "send_prop":
            c.handleSend(method: .propagated, toHex: query["to"] ?? "", text: query["text"] ?? "")
        case "get_msg_state":
            c.handleGetMsgState(idHex: query["id"] ?? "")
        case "get_rx":
            c.handleGetRx()
        case "rx_clear":
            c.handleRxClear()
        case "announce":
            c.handleAnnounce()
        case "list_interfaces":
            c.handleListInterfaces()
        case "disable_all_interfaces":
            c.handleDisableAllInterfaces()
        case "disable_interface":
            c.handleSetInterfaceEnabled(name: query["name"] ?? "", enabled: false)
        case "enable_interface":
            c.handleSetInterfaceEnabled(name: query["name"] ?? "", enabled: true)
        case "add_tcp_client":
            let port = Int(query["port"] ?? "") ?? -1
            c.handleAddTcpClient(
                name: query["name"] ?? "",
                host: query["host"] ?? "",
                port: port
            )
        case "remove_interface":
            c.handleRemoveInterface(name: query["name"] ?? "")
        case "set_prop_node":
            c.handleSetPropNode(hex: query["hex"] ?? "")
        case "sync_prop":
            c.handleSyncProp()
        case "dump_log":
            // Dump iOS unified log entries for our subsystems into
            // test_log.txt. `?since=<seconds>` (default 120s).
            // `?cat=<comma-separated>` overrides the default category
            // filter (Propagation,Sync,LXMRouter,Stamper,Identity,
            // PropagationNodeManager). Pass `cat=*` to disable category
            // filtering entirely.
            let since = Double(query["since"] ?? "") ?? 120.0
            let cat = query["cat"]
            c.handleDumpLog(sinceSeconds: since, categoryFilter: cat)
        case "dump_db":
            // Dump conversation list + per-conversation message
            // metadata into test_log.txt. Diagnoses UI-grouping bugs
            // (e.g. "PROP messages appear in a separate conversation"
            // — DB inspection reveals whether destination_hash is
            // genuinely diverging or the UI is mis-rendering).
            c.handleDumpDb()
        case "get_notifications":
            // Query UNUserNotificationCenter.deliveredNotifications and
            // emit one `notif` line per delivered notification, plus a
            // `notif_begin` / `notif_end` pair carrying a `query_ts`
            // timestamp. Used by the suspended_notification smoke
            // scenario to test whether a notification was actually
            // delivered while the app was suspended (compare each
            // notification's `delivery_ts` to the foregrounding
            // moment).
            c.handleGetNotifications()
        case "get_notif_status":
            // Emit current iOS notification authorization status +
            // Columba's `notifications_enabled` pref. The
            // suspended_notification scenario checks this up-front so
            // it can short-circuit with a clear `permission_missing`
            // error rather than ambiguous "0/0 notifications" output.
            c.handleGetNotifStatus()
        case "request_notif_permission":
            // Trigger UNUserNotificationCenter.requestAuthorization
            // (iOS shows the system prompt on first run) AND set
            // `notifications_enabled = true` in UserDefaults. The
            // orchestrator can't tap "Allow" on the system prompt
            // automatically, but a single manual tap on first run
            // persists the grant for subsequent smoke runs.
            c.handleRequestNotifPermission()
        case "enable_tunnel":
            // Persist `tunnelEnabledKey` and kick `TunnelManager.start()`
            // so the NE extension stays alive across host-app suspension.
            // Required for the `suspended_notification` scenario: without
            // the tunnel up, the inbound TCP socket dies on suspend and
            // Phase B's destination filter never sees a frame.
            c.handleEnableTunnel()
        case "get_tunnel_status":
            // Emit the current tunnel status. Used by the suspend
            // scenarios to assert the tunnel is `connected` before
            // backgrounding the host app.
            c.handleGetTunnelStatus()
        default:
            TestLog.emit("rx_url_unknown action=\(action)")
        }
        return true
    }

    // MARK: - Helpers

    enum TestError: Error {
        case notReady
    }

    #if ENABLE_NETWORK_EXTENSION
    /// Stringify `NEVPNStatus` for the harness log line. Mirrors the
    /// Settings UI's choice of names so logs read like user intent.
    fileprivate static func tunnelStatusString(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid:       return "invalid"
        case .disconnected:  return "disconnected"
        case .connecting:    return "connecting"
        case .connected:     return "connected"
        case .reasserting:   return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default:    return "unknown"
        }
    }
    #endif

    /// Same release-guard rationale as TestController's: the file is
    /// already `#if DEBUG`, this is the inner layer.
    /// Defense-in-depth runtime guard: if some build-config or compile-
    /// conditions misconfiguration ever lets this code run in a non-DEBUG
    /// build, crash hard at the first invocation rather than silently
    /// expose the test surface. In normal DEBUG builds this is a no-op.
    ///
    /// (Earlier this called `assertionFailure(...)` unconditionally, which
    /// is exactly the wrong direction — `assertionFailure` ALWAYS crashes
    /// in DEBUG builds, so every test invocation crashed the app on the
    /// guard before reaching any actual test logic. Mirrors the Android
    /// side's `check(BuildConfig.DEBUG)` semantics: throw only when DEBUG
    /// is FALSE.)
    private static func assertionFailure_releaseGuard() {
        #if !DEBUG
        fatalError(
            "TestURLHandler must not run in release builds — " +
            "this is a debug-only test surface."
        )
        #endif
    }
}

#endif  // DEBUG
