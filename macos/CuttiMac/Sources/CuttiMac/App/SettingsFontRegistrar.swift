import AppKit
import CoreText
import Foundation

/// Registers the bundled UI fonts (Inter + JetBrains Mono) with CoreText
/// at app launch so the Settings redesign can reference them by family
/// name (`Font.custom("Inter", size:13)` etc.) without depending on
/// system-installed copies.
///
/// SwiftPM executables ship without an `Info.plist`, so the usual
/// `ATSApplicationFontsPath` declaration isn't available — we have to
/// register them programmatically. `Bundle.cuttiMacResources` resolves
/// to the SwiftPM-emitted resource bundle in both `swift run` (via
/// `Bundle.module`) and production `.app` builds (where the bundle
/// lives at `Contents/Resources/CuttiMac_CuttiMac.bundle` because
/// macOS code signing forbids the location SwiftPM's synthesized
/// `Bundle.module` looks at — see CuttiMacBundleResources.swift).
///
/// Failures to register are non-fatal: `Font.custom(...)` falls back
/// to the system font silently, and `kCTFontManagerErrorAlreadyRegistered`
/// (-336) — common when a developer has Inter installed system-wide —
/// is treated as success. Real failures are logged but never thrown.
enum SettingsFontRegistrar {
    /// File names of every bundled font, sans extension. Order doesn't
    /// matter; the registrar enumerates both `.otf` and `.ttf` for each
    /// stem and picks whichever exists.
    private static let fontStems: [String] = [
        "Inter-Regular",
        "Inter-Medium",
        "Inter-SemiBold",
        "JetBrainsMono-Regular",
        "JetBrainsMono-Medium",
    ]

    /// Idempotent — safe to call from any thread, but should run before
    /// the first SwiftUI view materializes so font lookups in view
    /// bodies always succeed. The recommended call site is the very
    /// first line of `CuttiMacApp.init()`.
    static func registerAll() {
        for stem in fontStems {
            register(stem: stem)
        }
    }

    private static func register(stem: String) {
        guard let url = locateFont(stem: stem) else {
            NSLog("⚠️ [fonts] Bundled font missing: \(stem) — Settings UI will fall back to system font.")
            return
        }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if ok { return }

        // CoreText returns an NSError with code 105 (`kCTFontManagerErrorAlreadyRegistered`)
        // when the same family + style is already registered for this
        // process — usually because the developer has the font
        // installed system-wide via Font Book. Treat as success.
        if let cfErr = error?.takeRetainedValue() {
            let nsErr = cfErr as Error as NSError
            if nsErr.code == CTFontManagerError.alreadyRegistered.rawValue {
                return
            }
            NSLog("⚠️ [fonts] Failed to register \(stem): \(nsErr.localizedDescription) (\(nsErr.code))")
        } else {
            NSLog("⚠️ [fonts] Failed to register \(stem) (no error returned)")
        }
    }

    private static func locateFont(stem: String) -> URL? {
        // SwiftPM's `.process()` rule preserves the original extension.
        // Inter ships as .otf; JetBrains Mono as .ttf.
        for ext in ["otf", "ttf"] {
            if let url = Bundle.cuttiMacResources.url(forResource: stem, withExtension: ext) {
                return url
            }
        }
        return nil
    }
}
