import Foundation

/// Persisted in the app's own defaults domain. Only the `serve` process ever
/// touches these; the other verbs are socket clients and ask the daemon.
enum Settings {
    static let suiteName = "com.hongzio.imswitch"

    /// Inside Imswitch.app the suite *is* the bundle identifier, and
    /// `UserDefaults(suiteName:)` both warns and returns nil for that case —
    /// the standard defaults already point at the very same domain.
    private static let store: UserDefaults = {
        if Bundle.main.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }()

    static let preferredDefaultTargetID = "com.apple.keylayout.ABC"

    private static let targetKey = "targetInputSourceID"
    private static let enabledKey = "enabled"

    static var targetInputSourceID: String {
        get {
            if let stored = store.string(forKey: targetKey), !stored.isEmpty { return stored }
            let resolved = InputSources.defaultTargetID()
            store.set(resolved, forKey: targetKey)
            return resolved
        }
        set {
            store.set(newValue, forKey: targetKey)
            InputSources.invalidateCache()
        }
    }

    static var enabled: Bool {
        get {
            guard store.object(forKey: enabledKey) != nil else { return true }
            return store.bool(forKey: enabledKey)
        }
        set { store.set(newValue, forKey: enabledKey) }
    }
}
