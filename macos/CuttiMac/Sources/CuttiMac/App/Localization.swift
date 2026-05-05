import Foundation
import SwiftUI

// MARK: - Localization helpers
//
// SwiftUI's `Text("Foo")` defaults to looking up `"Foo"` in `Bundle.main`.
// SwiftPM-built executables put localized .lproj resources into a
// sibling resource bundle (`Bundle.module`) instead, so the default
// lookup never finds our translations.
//
// We can't just hand `Bundle.module` to `Text(_:bundle:)` either: SwiftPM
// lowercases lproj folder names (`zh-Hans.lproj` → `zh-hans.lproj`), and
// Foundation's `preferredLocalizations` matching against `AppleLanguages`
// fails to canonicalize them back, so it always falls through to "en".
//
// Workaround: at first access we look up the user's preferred language
// (Settings → Interface language, falling back to the System match), find
// the matching `.lproj` *sub-bundle* inside `Bundle.module`, and resolve
// every string against that single-locale bundle. This sidesteps the
// preferred-localizations mechanism entirely.
//
// Usage:
//   Text("Send")           // ❌ Bundle.main → no translation found
//   T("Send")              // ✅ resolved against the chosen .lproj
//   L("Imported %@ clips") // ✅ String version, e.g. for assignment

private enum LocalizationOverride {
    /// Languages this app actively translates. Order matters for the
    /// "System" fallback: Foundation picks the first one that the user
    /// has expressed any preference for.
    static let supported = ["en", "zh-Hans"]

    /// Cached single-locale sub-bundle. Computed lazily on first access
    /// and never invalidated — language changes require an app restart
    /// (Settings shows a "Restart Required" alert), so caching is safe.
    static let bundle: Bundle = resolveBundle()

    private static func resolveBundle() -> Bundle {
        let lang = currentLanguage()
        // SwiftPM lowercases lproj folder names, so try a few variants.
        let candidates = [lang, lang.lowercased()]
        for candidate in candidates {
            if let path = Bundle.cuttiMacResources.path(forResource: candidate, ofType: "lproj"),
               let sub = Bundle(path: path) {
                return sub
            }
        }
        // Last resort: hand back the multi-locale module bundle so we
        // at least fall through to development-language strings rather
        // than crashing.
        return .cuttiMacResources
    }

    private static func currentLanguage() -> String {
        let pref = UserDefaults.standard.string(forKey: CuttiSettings.uiLanguageKey)
            ?? CuttiSettings.uiLanguageSystem
        if pref != CuttiSettings.uiLanguageSystem {
            return pref
        }
        // System: take the first supported language the user prefers.
        let chosen = Bundle.preferredLocalizations(
            from: supported,
            forPreferences: Locale.preferredLanguages
        )
        return chosen.first ?? "en"
    }
}

/// Returns a SwiftUI `Text` whose `LocalizedStringKey` is resolved
/// against the Cutti module's bundle. Drop-in replacement for
/// `Text(_:)` in any view.
func T(_ key: LocalizedStringKey) -> Text {
    Text(key, bundle: LocalizationOverride.bundle)
}

/// Returns the localized `String` for `key`, resolved against the
/// Cutti module's bundle. Use for non-`Text` contexts: alert
/// titles, accessibility labels, banner messages stored in
/// `@Published` String properties, etc.
func L(_ key: String, _ args: CVarArg...) -> String {
    let template = NSLocalizedString(key, bundle: LocalizationOverride.bundle, comment: "")
    if args.isEmpty { return template }
    return String(format: template, arguments: args)
}
