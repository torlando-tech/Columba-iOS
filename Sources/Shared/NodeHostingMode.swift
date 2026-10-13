import Foundation

/// Location of the same Python node, never a different protocol implementation.
public enum NodeHostingMode: String, CaseIterable, Sendable {
    case networkExtension
    case foreground

    public static let preferenceKey = "rnsHostingMode"
    private static let activeKey = "rnsActiveHostingMode"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "group.network.columba.Columba") ?? .standard
    }
    /// Saved Settings choice. It does not change an already running host.
    public static var selected: NodeHostingMode { resolve(defaults: defaults) }
    /// Both processes check the host committed at the last fresh app launch.
    public static var current: NodeHostingMode { resolveActive(defaults: defaults) }
    public static func resolve(defaults: UserDefaults) -> NodeHostingMode {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .networkExtension
    }
    public static func resolveActive(defaults: UserDefaults) -> NodeHostingMode {
        defaults.string(forKey: activeKey).flatMap(Self.init(rawValue:)) ?? resolve(defaults: defaults)
    }
    /// Called at fresh app launch, or by onboarding before a node has started.
    @discardableResult
    public static func activateSelection(defaults: UserDefaults? = nil) -> NodeHostingMode {
        let store = defaults ?? Self.defaults
        let mode = resolve(defaults: store)
        store.set(mode.rawValue, forKey: activeKey)
        return mode
    }
}
