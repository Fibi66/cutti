import Foundation

/// iOS-side stub for the shared `L()` helper used by cross-platform
/// cloud/AI files (OpenAIClient, RelaySession, etc.). The macOS build
/// resolves strings against a SwiftPM sub-bundle; on iOS we just use
/// `Bundle.main` with `NSLocalizedString`, falling back to the key
/// itself when no translation is available.
func L(_ key: String, _ args: CVarArg...) -> String {
    let template = NSLocalizedString(key, bundle: .main, comment: "")
    if args.isEmpty { return template }
    return String(format: template, arguments: args)
}
