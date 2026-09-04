import Foundation

/// Discovery sort modes.
public enum DiscoveredSortMode {
    /// Keep the backend order (already quality-ordered).
    case availabilityAndQuality
    /// Sort located interfaces by distance to the user, then the rest.
    case proximity
}

/// Display buckets for discovered interfaces (port of the Android type chips).
public enum DiscoveredTypeFilter: String, CaseIterable, Identifiable {
    case tcp = "TCP"
    case radio = "Radio"
    case i2p = "I2P"
    case other = "Other"

    public var id: String { rawValue }

    /// Classify an interface into a display bucket.
    ///
    /// TCP and radio use the model's derived properties; I2P is matched
    /// case-insensitively on the raw type string; everything else is Other.
    public static func classify(_ iface: DiscoveredInterface) -> DiscoveredTypeFilter {
        if iface.isTcpInterface { return .tcp }
        if iface.isRadioInterface { return .radio }
        if iface.type.range(of: "i2p", options: .caseInsensitive) != nil { return .i2p }
        return .other
    }
}

/// Check whether a host address is a Yggdrasil network address (IPv6 in the
/// `0200::/7` space — addresses starting with `02xx` or `03xx`).
///
/// Port of the Android `isYggdrasilAddress`: trims, strips one leading `[`
/// and one trailing `]` (bracketed IPv6 literals), requires a `:`, and
/// accepts iff the first `:`-segment parses as base-16 into `0x0200...0x03FF`.
public func isYggdrasilAddress(_ host: String?) -> Bool {
    guard let host else { return false }
    var s = host.trimmingCharacters(in: .whitespaces)
    // Strip one leading "[" and one trailing "]" (bracketed IPv6 literal).
    if s.hasPrefix("[") { s.removeFirst() }
    if s.hasSuffix("]") { s.removeLast() }
    guard let colonIndex = s.firstIndex(of: ":") else { return false }
    guard let value = Int(s[s.startIndex..<colonIndex], radix: 16) else { return false }
    return (0x0200...0x03FF).contains(value)
}

/// Format an interface type string for display.
public func formatInterfaceType(_ type: String) -> String {
    switch type {
    case "TCPServerInterface": return "TCP Server"
    case "TCPClientInterface": return "TCP Client"
    case "BackboneInterface": return "Backbone (TCP)"
    case "I2PInterface": return "I2P"
    case "RNodeInterface": return "RNode (LoRa)"
    case "WeaveInterface": return "Weave (LoRa)"
    case "KISSInterface": return "KISS"
    default: return type
    }
}

/// Format a last-heard unix timestamp as relative time.
///
/// - `timestamp` is 0 for "never heard" -> "Never".
/// - `nowSeconds` is injected for deterministic testing; the convenience
///   overload uses `Date().timeIntervalSince1970`.
public func formatLastHeard(_ timestamp: Double, nowSeconds: Double) -> String {
    if timestamp == 0 { return "Never" }
    // Int(exactly:) so a corrupted/clock-jumped diff (e.g. a NaN or >Int.max
    // delta) falls back to the absolute-date branch instead of trapping.
    let diff = Int(exactly: (nowSeconds - timestamp).rounded(.down)) ?? Int.max
    switch diff {
    case ..<60:
        return "just now"
    case ..<3600:
        return "\(diff / 60) min ago"
    case ..<86400:
        return "\(diff / 3600) hours ago"
    case ..<604800:
        return "\(diff / 86400) days ago"
    default:
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

/// Convenience: format against the current time.
public func formatLastHeard(_ timestamp: Double) -> String {
    formatLastHeard(timestamp, nowSeconds: Date().timeIntervalSince1970)
}

/// Great-circle distance in kilometers between two lat/lon points
/// (R = 6371 km, standard haversine formula).
public func haversineDistanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let r = 6371.0
    let phi1 = lat1 * .pi / 180
    let phi2 = lat2 * .pi / 180
    let dPhi = (lat2 - lat1) * .pi / 180
    let dLambda = (lon2 - lon1) * .pi / 180
    let a = sin(dPhi / 2) * sin(dPhi / 2)
        + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
    return 2 * r * asin(min(1, sqrt(a)))
}

/// Build the LoRa-parameters clipboard block for an interface.
///
/// Lines are emitted only for fields that are present; the result is trimmed
/// (no trailing newline).
public func formatLoraParamsForClipboard(_ iface: DiscoveredInterface) -> String {
    var lines: [String] = [
        "LoRa Parameters from: \(iface.name)",
        "---",
    ]
    if let freq = iface.frequency {
        lines.append(String(format: "Frequency: %.6f MHz", freq / 1_000_000.0))
    }
    if let bw = iface.bandwidth {
        lines.append("Bandwidth: \(bw / 1000) kHz")
    }
    if let sf = iface.spreadingFactor {
        lines.append("Spreading Factor: SF\(sf)")
    }
    if let cr = iface.codingRate {
        lines.append("Coding Rate: 4/\(cr)")
    }
    if let mod = iface.modulation {
        lines.append("Modulation: \(mod)")
    }
    return lines.joined(separator: "\n")
}

/// Discovery sort.
public enum DiscoveredSorter {
    /// Sort discovered interfaces.
    ///
    /// - `.availabilityAndQuality`: input order is preserved unchanged (the
    ///   backend already quality-orders the list).
    /// - `.proximity`: located interfaces first, ascending by haversine
    ///   distance to the user location (input order kept when the user
    ///   location is nil), then non-located interfaces appended in input
    ///   order. Ties keep input order (stable tiebreak by original index —
    ///   Swift's `sort` is not guaranteed stable).
    public static func sort(
        _ input: [DiscoveredInterface],
        mode: DiscoveredSortMode,
        userLatitude: Double?,
        userLongitude: Double?
    ) -> [DiscoveredInterface] {
        switch mode {
        case .availabilityAndQuality:
            return input
        case .proximity:
            let located = input.enumerated().filter { $0.element.hasLocation }
            let nonLocated = input.filter { !$0.hasLocation }
            let sortedLocated: [DiscoveredInterface]
            if let userLatitude, let userLongitude {
                let indexed = located.sorted { lhs, rhs in
                    let dl = haversineDistanceKm(
                        lat1: lhs.element.latitude ?? 0,
                        lon1: lhs.element.longitude ?? 0,
                        lat2: userLatitude,
                        lon2: userLongitude
                    )
                    let dr = haversineDistanceKm(
                        lat1: rhs.element.latitude ?? 0,
                        lon1: rhs.element.longitude ?? 0,
                        lat2: userLatitude,
                        lon2: userLongitude
                    )
                    if dl == dr { return lhs.offset < rhs.offset }
                    return dl < dr
                }
                sortedLocated = indexed.map { $0.element }
            } else {
                sortedLocated = located.map { $0.element }
            }
            return sortedLocated + nonLocated
        }
    }
}

/// Discovery display filter (search + type chips + IFAC-only toggle).
///
/// All criteria combine with AND. The IFAC-only check keeps interfaces whose
/// `ifacNetname` is non-nil and non-empty — it must work on previously-heard
/// data regardless of the current discovery state.
public enum DiscoveredFilter {
    /// Apply the combined display filter.
    public static func apply(
        _ input: [DiscoveredInterface],
        searchQuery: String,
        typeFilters: Set<DiscoveredTypeFilter>,
        ifacOnly: Bool
    ) -> [DiscoveredInterface] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        let search: ((DiscoveredInterface) -> Bool)?
        if query.isEmpty {
            search = nil
        } else {
            let q = query.lowercased()
            search = { iface in
                iface.name.lowercased().contains(q)
                    || (iface.reachableOn?.lowercased().contains(q) ?? false)
                    || iface.type.lowercased().contains(q)
                    || (iface.ifacNetname?.lowercased().contains(q) ?? false)
            }
        }
        return input.filter { iface in
            if let search, !search(iface) { return false }
            if !typeFilters.isEmpty && !typeFilters.contains(DiscoveredTypeFilter.classify(iface)) {
                return false
            }
            if ifacOnly {
                guard let ifacNetname = iface.ifacNetname, !ifacNetname.isEmpty else { return false }
            }
            return true
        }
    }
}
