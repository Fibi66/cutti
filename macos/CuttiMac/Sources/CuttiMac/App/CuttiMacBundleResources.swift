import Foundation

extension Bundle {
    /// Resolves the CuttiMac SwiftPM resource bundle in a way that works
    /// both for the packaged `Cutti.app` and for `swift run` / `swift test`.
    ///
    /// SwiftPM auto-synthesizes `Bundle.module` per target and looks the
    /// bundle up at:
    ///
    ///     Bundle.main.bundleURL.appendingPathComponent("CuttiMac_CuttiMac.bundle")
    ///
    /// For an `.app`, `Bundle.main.bundleURL` is the `.app` itself, so the
    /// accessor expects the resource bundle at `Cutti.app/CuttiMac_CuttiMac.bundle`
    /// — i.e. *at the .app's root, sibling to `Contents/`*. macOS code
    /// signing rejects any content there ("unsealed contents present in
    /// the bundle root"), so a packaged + signed Cutti.app cannot put the
    /// resource bundle where SwiftPM's accessor will find it. Calling
    /// `Bundle.module` from inside such an app trips its `fatalError(...)`
    /// at the first font/localization/skill lookup, killing the process at
    /// launch — see crash report from v0.1.1.
    ///
    /// This accessor sidesteps the synthesized one entirely:
    ///
    /// 1. **Packaged `.app`:** the resource bundle is copied to the
    ///    Apple-standard location `Cutti.app/Contents/Resources/CuttiMac_CuttiMac.bundle`
    ///    by `scripts/package-macos.sh`, and `Bundle.main.url(forResource:withExtension:)`
    ///    finds it there.
    /// 2. **`swift run` / `swift test`:** `Bundle.main` is the build
    ///    directory or the xctest bundle, neither of which hosts a
    ///    `CuttiMac_CuttiMac.bundle` resource. We fall through to
    ///    `Bundle.module`, which works correctly in those contexts
    ///    because its `mainPath = Bundle.main.bundleURL/...` lookup
    ///    points at the SwiftPM build dir where the bundle lives.
    ///
    /// All callers in the CuttiMac target should use
    /// `Bundle.cuttiMacResources` instead of `Bundle.module`. This file
    /// exists specifically so that bug fixes to the lookup logic land in
    /// one place.
    static let cuttiMacResources: Bundle = {
        if let url = Bundle.main.url(forResource: "CuttiMac_CuttiMac", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}
