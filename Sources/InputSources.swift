import Carbon
import Foundation

/// One selectable keyboard input source, as shown in the menu bar.
struct InputSourceInfo {
    let id: String
    let name: String
}

/// Thin wrapper over the Text Input Sources (TIS) API.
///
/// Every entry point here must be called on the main queue: the resolution
/// cache below is not synchronized, and TIS itself expects the main thread.
enum InputSources {

    // MARK: - Property helpers

    /// TIS property accessors hand back a raw pointer to a CF object they still
    /// own, hence `takeUnretainedValue`.
    static func stringProperty(_ src: TISInputSource, _ key: CFString!) -> String? {
        guard let p = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    static func boolProperty(_ src: TISInputSource, _ key: CFString!) -> Bool {
        guard let p = TISGetInputSourceProperty(src, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
    }

    // MARK: - Enumeration

    /// `TISCreateInputSourceList` and friends are imported as `Unmanaged<...>!`
    /// because TextInputSources.h carries neither CF_IMPLICIT_BRIDGING_ENABLED
    /// nor apinotes, so the +1 reference has to be consumed by hand.
    private static func sources(from list: Unmanaged<CFArray>?) -> [TISInputSource] {
        guard let cfList = list?.takeRetainedValue() else { return [] }
        var out: [TISInputSource] = []
        for i in 0..<CFArrayGetCount(cfList) {
            guard let ptr = CFArrayGetValueAtIndex(cfList, i) else { continue }
            out.append(Unmanaged<TISInputSource>.fromOpaque(ptr).takeUnretainedValue())
        }
        return out
    }

    /// Enabled sources the user can actually select. Disabled sources cannot be
    /// selected at all, so there is no reason to list them.
    ///
    /// The category filter drops palettes — "Emoji & Symbols" and
    /// com.apple.PressAndHold report as select-capable but are not keyboards
    /// and make no sense as a switch target.
    private static func selectableSources() -> [TISInputSource] {
        sources(from: TISCreateInputSourceList(nil, false)).filter { src in
            boolProperty(src, kTISPropertyInputSourceIsSelectCapable)
                && stringProperty(src, kTISPropertyInputSourceCategory)
                    == (kTISCategoryKeyboardInputSource as String)
        }
    }

    static func list() -> [InputSourceInfo] {
        selectableSources().compactMap { src in
            guard let id = stringProperty(src, kTISPropertyInputSourceID) else { return nil }
            let name = stringProperty(src, kTISPropertyLocalizedName) ?? id
            return InputSourceInfo(id: id, name: name)
        }
    }

    static func currentSourceID() -> String? {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return stringProperty(cur, kTISPropertyInputSourceID)
    }

    static func currentSourceName() -> String? {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return stringProperty(cur, kTISPropertyLocalizedName)
            ?? stringProperty(cur, kTISPropertyInputSourceID)
    }

    /// First ASCII-capable plain keyboard layout; the safety net for a target
    /// that is no longer installed.
    private static func asciiFallback() -> (id: String, src: TISInputSource)? {
        for src in sources(from: TISCreateASCIICapableInputSourceList()) {
            guard stringProperty(src, kTISPropertyInputSourceType) == (kTISTypeKeyboardLayout as String),
                  let id = stringProperty(src, kTISPropertyInputSourceID)
            else { continue }
            return (id, src)
        }
        return nil
    }

    static func defaultTargetID() -> String {
        let ids = list().map(\.id)
        if ids.contains(Settings.preferredDefaultTargetID) { return Settings.preferredDefaultTargetID }
        return asciiFallback()?.id ?? Settings.preferredDefaultTargetID
    }

    // MARK: - Selection

    enum Outcome {
        case switched(String)
        case noop(String)
        case failed(String)
    }

    /// Resolving an ID walks the whole source list, so hold on to the result.
    /// The cache is dropped whenever selection fails, which is how a source the
    /// user disabled mid-session gets re-resolved on the next request.
    private static var cache: (wanted: String, id: String, src: TISInputSource)?
    private static var warnedAboutFallbackFor: String?

    private static func resolve(_ wanted: String) -> (id: String, src: TISInputSource)? {
        if let c = cache, c.wanted == wanted { return (c.id, c.src) }

        for src in selectableSources() where stringProperty(src, kTISPropertyInputSourceID) == wanted {
            cache = (wanted, wanted, src)
            warnedAboutFallbackFor = nil
            return (wanted, src)
        }

        guard let fallback = asciiFallback() else { return nil }
        if warnedAboutFallbackFor != wanted {
            warnedAboutFallbackFor = wanted
            log("target '\(wanted)' is not an enabled input source; falling back to '\(fallback.id)'")
        }
        cache = (wanted, fallback.id, fallback.src)
        return fallback
    }

    static func invalidateCache() {
        cache = nil
    }

    /// Idempotent by design: the triggers fire often enough that an
    /// unconditional `TISSelectInputSource` makes the IME visibly flicker.
    static func select(id wanted: String) -> Outcome {
        guard let target = resolve(wanted) else { return .failed("no-selectable-source") }
        if currentSourceID() == target.id { return .noop(target.id) }

        let status = TISSelectInputSource(target.src)
        guard status == noErr else {
            cache = nil
            return .failed("TISSelectInputSource=\(status)")
        }
        return .switched(target.id)
    }
}
