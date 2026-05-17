//
//  PythonConfigWriter.swift
//  ColumbaApp
//
//  Writes the RNS config file consumed by the embedded Python stack, based on
//  the user's `InterfaceEntity` records from `InterfaceRepository`. Mirrors the
//  config-from-UI flow Columba Android already uses with Chaquopy.
//
//  RNS's config format is ConfigObj-style (nested `[[section]]` brackets for
//  subsections, two-space indentation). Not quite TOML.
//

import Foundation
import RNSAPI

/// Serializes Columba's interface entities to an RNS config file.
///
/// Lifecycle:
/// 1. AppServices.initialize collects enabled `InterfaceEntity` records from
///    `InterfaceRepository`.
/// 2. Calls `PythonConfigWriter.write(...)` to produce the RNS config string.
/// 3. Writes the string to `<configDir>/config` so the Python `RNS.Reticulum`
///    instance picks it up on init.
///
/// When the user adds, removes, or edits an interface in Settings, the
/// InterfaceRepository observes the change, AppServices re-runs the writer,
/// and Python is restarted to pick up the new config. (Hot-reload isn't a
/// thing in RNS — Mark Qvist noted this in upstream issue threads.)
enum PythonConfigWriter {
    /// Build the RNS config text from a set of enabled interfaces.
    ///
    /// - Parameters:
    ///   - interfaces: enabled `InterfaceEntity` records (typically from
    ///     `InterfaceRepository.getEnabledInterfaces()`). Disabled rows
    ///     should be filtered before this call.
    ///   - enableTransport: whether the local RNS instance should act as a
    ///     transport node. Phones usually want `false` (terminal device);
    ///     desktop relays want `true`. Set from the Settings "Transport
    ///     Mode" toggle (stored in App Group UserDefaults under
    ///     `transport_enabled`). Changing this requires an Apply &
    ///     Restart since RNS reads it at `Reticulum.__init__` time.
    /// - Returns: ConfigObj-format text suitable for writing to
    ///   `<configDir>/config`.
    static func write(
        interfaces: [InterfaceEntity],
        enableTransport: Bool = false
    ) -> String {
        var lines: [String] = []

        lines.append("[reticulum]")
        lines.append("  enable_transport = \(enableTransport ? "yes" : "no")")
        lines.append("  share_instance = no")
        lines.append("  panic_on_interface_error = no")
        lines.append("")
        lines.append("[logging]")
        lines.append("  loglevel = 4")
        lines.append("")

        if interfaces.isEmpty {
            // No interfaces configured yet — the app starts in an offline
            // state. The Settings UI is the user's path to add some.
            return lines.joined(separator: "\n") + "\n"
        }

        lines.append("[interfaces]")
        for iface in interfaces {
            appendInterface(iface, to: &lines)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendInterface(_ iface: InterfaceEntity, to lines: inout [String]) {
        // RNS interface names show up in `rnstatus`; use Columba's
        // human-readable name (sanitized) plus the entity id so we can
        // round-trip if multiple have the same display name.
        let sectionName = sanitize(iface.name).isEmpty
            ? iface.id
            : "\(sanitize(iface.name))-\(iface.id.prefix(6))"
        lines.append("  [[\(sectionName)]]")
        lines.append("    enabled = yes")
        lines.append("    interface_enabled = yes")
        appendMode(iface.mode, to: &lines)

        switch iface.config {
        case .tcpClient(let cfg):
            lines.append("    type = TCPClientInterface")
            lines.append("    target_host = \(cfg.targetHost)")
            lines.append("    target_port = \(cfg.targetPort)")
            appendIFAC(networkName: cfg.networkName, passphrase: cfg.passphrase, to: &lines)
        case .tcpServer(let cfg):
            lines.append("    type = TCPServerInterface")
            lines.append("    listen_ip = \(cfg.listenIp)")
            lines.append("    listen_port = \(cfg.listenPort)")
        case .autoInterface(let cfg):
            lines.append("    type = AutoInterface")
            if let group = cfg.groupId, !group.isEmpty {
                lines.append("    group_id = \(group)")
            }
            lines.append("    discovery_scope = \(cfg.discoveryScope)")
            if let port = cfg.discoveryPort { lines.append("    discovery_port = \(port)") }
            if let port = cfg.dataPort { lines.append("    data_port = \(port)") }
        case .ble:
            // Loaded from <configDir>/interfaces/IOSBLEInterface.py — the
            // file is copied there at startup by AppServices.startBLEInterface()
            // from the app bundle. The Python `IOSBLEDriver` calls into Swift
            // via ctypes-bound `columba_ble_*` C-ABI shims (see
            // Sources/SwiftBLEBridge/BleNativeBindings.swift).
            lines.append("    type = IOSBLEInterface")
            // Optional power preset — currently informational on iOS (the
            // OS auto-manages duty cycle). Surfaced for parity with
            // Android's BleConnections settings.
            lines.append("    ble_power_preset = balanced")
        case .rnode, .multipeer:
            // RNode / Multipeer interfaces are owned by Swift (KISS-over-BLE,
            // MultipeerConnectivity) — Python sees them through a custom
            // RNS.Interface subclass that hasn't landed yet. Emit a placeholder
            // comment so the file is still valid for the rest of the config;
            // the Swift-side driver wakes the radio independently.
            lines.append("    type = TCPClientInterface  # placeholder; \(iface.type) bridged from Swift not yet wired")
            lines.append("    target_host = 127.0.0.1")
            lines.append("    target_port = 65535")
            lines.append("    enabled = no")
        }
        lines.append("")
    }

    private static func appendMode(_ mode: InterfaceMode, to lines: inout [String]) {
        switch mode {
        case .full: lines.append("    mode = full")
        case .gateway: lines.append("    mode = gateway")
        case .accessPoint: lines.append("    mode = access_point")
        case .roaming: lines.append("    mode = roaming")
        case .boundary: lines.append("    mode = boundary")
        }
    }

    private static func appendIFAC(networkName: String?, passphrase: String?, to lines: inout [String]) {
        if let name = networkName, !name.isEmpty {
            lines.append("    networkname = \(name)")
        }
        if let pass = passphrase, !pass.isEmpty {
            lines.append("    passphrase = \(pass)")
        }
    }

    /// Strip characters ConfigObj doesn't like in section names (brackets,
    /// equals, whitespace runs).
    private static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let bad: Set<Character> = ["[", "]", "=", "#", "\n", "\r"]
        var out = ""
        for ch in trimmed {
            if bad.contains(ch) { out.append("_") }
            else if ch.isWhitespace { out.append("_") }
            else { out.append(ch) }
        }
        return out
    }
}
