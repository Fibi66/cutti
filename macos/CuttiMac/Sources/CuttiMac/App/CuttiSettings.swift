import Foundation

enum SpeechRecognitionBackend: String, Sendable {
    case appleSpeech
    /// Local Qwen3-ASR + ForcedAligner sidecar (Apple Silicon, direct
    /// distribution only). Becomes the primary engine for every
    /// language once installed; falls back to Apple SFSpeech when it
    /// isn't installed or fails at runtime.
    case qwenAsrSidecar

    var title: String {
        switch self {
        case .appleSpeech:
            return "Apple Speech"
        case .qwenAsrSidecar:
            return "Qwen3-ASR (local)"
        }
    }
}

struct SpeechRecognitionProfile: Sendable {
    let locale: Locale
    /// Two-letter ASR language hint (`en` / `zh` / `yue`) derived from
    /// `locale.language.languageCode`. Qwen3-ASR consumes all three;
    /// Apple SFSpeech reads the parent locale.
    let languageCode: String
    /// Ordered list of backends to try, first → last. Each entry is
    /// attempted until one returns non-empty results. Always at least
    /// one entry; usually two when Qwen3-ASR is available.
    let backendChain: [SpeechRecognitionBackend]

    /// Compatibility shim — most call sites still treat speech-
    /// recognition as a simple "primary + fallback" pair.
    var primaryBackend: SpeechRecognitionBackend { backendChain.first ?? .appleSpeech }
    var fallbackBackend: SpeechRecognitionBackend {
        backendChain.dropFirst().first ?? primaryBackend
    }
}

/// Host capabilities consumed by the pure speech-profile resolver.
/// Splitting these out lets `SpeechTranscriptionServiceTests` exercise
/// the resolution matrix without depending on the actual host /
/// install state.
struct SpeechResolverCapabilities: Sendable {
    /// `true` when the running build is the direct-download variant
    /// (not a Mac App Store build). The Qwen sidecar requires a Python
    /// runtime + downloaded weights and can't ship through MAS.
    let isDirectDistribution: Bool
    /// `true` on Apple Silicon. The Qwen aligner uses MPS fallback
    /// torch ops and won't run on x86_64.
    let isAppleSilicon: Bool
    /// `true` when the on-disk install is present and version-matched.
    let qwenInstalled: Bool

    static func current() -> SpeechResolverCapabilities {
        SpeechResolverCapabilities(
            isDirectDistribution: CuttiDistribution.current == .direct,
            isAppleSilicon: qwenAsrHostIsAppleSilicon(),
            qwenInstalled: QwenAsrSidecarInstaller.isInstallUpToDate()
        )
    }
}

enum CuttiSettings {
    static let subtitlesVisibleByDefaultKey = "cutti.subtitlesVisibleByDefault"
    static let showAgentTraceKey = "cutti.showAgentTrace"
    /// User's preferred UI language. Values: "system" / "en" / "zh-Hans".
    /// Applied at app launch via the `AppleLanguages` UserDefaults key;
    /// changes require a restart to fully take effect.
    static let uiLanguageKey = "cutti.uiLanguage"

    static let uiLanguageSystem = "system"
    static let uiLanguageEnglish = "en"
    static let uiLanguageChinese = "zh-Hans"

    // MARK: - AI provider (BYOK)

    /// `AIProviderPreference.rawValue`. Default: `cuttiCloud`.
    static let aiProviderKey = "cutti.aiProvider"
    /// Non-secret BYOK fields. Secrets live in the keychain.
    static let customLLMBaseURLKey = "cutti.byok.llm.baseURL"
    static let customLLMModelKey = "cutti.byok.llm.model"
    static let customUseSeparateImageProviderKey = "cutti.byok.useSeparateImageProvider"
    static let customImageBaseURLKey = "cutti.byok.image.baseURL"
    static let customImageModelKey = "cutti.byok.image.model"

    /// Keychain account names for BYOK API keys.
    static let customLLMKeychainAccount = "cutti.byok.llm.key"
    static let customImageKeychainAccount = "cutti.byok.image.key"

    /// `@AppStorage` flag for the per-editor "Skip Qwen install for now"
    /// dismissal. Persisted across launches so a user who explicitly
    /// dismisses the install prompt isn't nagged again on every editor
    /// open. Reset whenever the install state transitions away from
    /// `.notInstalled`/`.failed` (e.g. install succeeds, user
    /// uninstalls).
    static let qwenSetupDismissedKey = "cutti.qwenSetupDismissed"

    static func ensureDefaults(defaults: UserDefaults = .standard) {
        if defaults.object(forKey: subtitlesVisibleByDefaultKey) == nil {
            defaults.set(true, forKey: subtitlesVisibleByDefaultKey)
        }
        if defaults.object(forKey: showAgentTraceKey) == nil {
            defaults.set(false, forKey: showAgentTraceKey)
        }
        if defaults.object(forKey: uiLanguageKey) == nil {
            defaults.set(uiLanguageSystem, forKey: uiLanguageKey)
        }
        if defaults.object(forKey: aiProviderKey) == nil {
            defaults.set(AIProviderPreference.cuttiCloud.rawValue, forKey: aiProviderKey)
        }
        if defaults.object(forKey: customUseSeparateImageProviderKey) == nil {
            defaults.set(false, forKey: customUseSeparateImageProviderKey)
        }
    }

    /// Reads the stored UI language preference and, when not "system",
    /// pushes a one-element AppleLanguages array into UserDefaults so
    /// `Bundle.main` resolves localized strings against the override at
    /// next launch. Must be called BEFORE any SwiftUI view is built.
    static func applyUILanguageOverride(defaults: UserDefaults = .standard) {
        let value = defaults.string(forKey: uiLanguageKey) ?? uiLanguageSystem
        if value == uiLanguageSystem {
            // Stop forcing — fall back to the OS-resolved preferred order.
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([value], forKey: "AppleLanguages")
        }
    }

    static func subtitlesVisibleByDefault(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: subtitlesVisibleByDefaultKey) == nil {
            return true
        }
        return defaults.bool(forKey: subtitlesVisibleByDefaultKey)
    }

    /// Pure resolver. Given a fallback locale (typically `Locale.current`)
    /// and host capabilities, return the speech profile. Has no side
    /// effects and reads no globals — kept testable.
    static func resolveSpeechProfile(
        fallbackLocale: Locale,
        capabilities: SpeechResolverCapabilities
    ) -> SpeechRecognitionProfile {
        var chain: [SpeechRecognitionBackend] = []
        if capabilities.isDirectDistribution,
           capabilities.isAppleSilicon,
           capabilities.qwenInstalled {
            chain.append(.qwenAsrSidecar)
        }
        // Apple SFSpeech is always reachable as a baseline — it ships
        // with macOS, doesn't need a download, and works on every host.
        chain.append(.appleSpeech)

        return SpeechRecognitionProfile(
            locale: fallbackLocale,
            languageCode: asrLanguageHint(for: fallbackLocale),
            backendChain: chain
        )
    }

    /// Production entry point — fills `SpeechResolverCapabilities` from
    /// real host state and delegates to the pure resolver.
    static func resolvedSpeechProfile(
        fallbackLocale: Locale = .current
    ) -> SpeechRecognitionProfile {
        return resolveSpeechProfile(
            fallbackLocale: fallbackLocale,
            capabilities: SpeechResolverCapabilities.current()
        )
    }

    /// Map a `Locale` to a 2-letter ASR hint. Returns `zh` for any
    /// Chinese variant, `yue` for Cantonese, and `en` for everything
    /// else. Qwen3-ASR's aligner accepts all three; Apple SFSpeech
    /// reads the parent locale.
    static func asrLanguageHint(for locale: Locale) -> String {
        let lang = locale.language.languageCode?.identifier.lowercased() ?? "en"
        switch lang {
        case "zh": return "zh"
        case "yue": return "yue"
        default: return "en"
        }
    }

    // MARK: - Qwen setup overlay dismissal

    static func qwenSetupDismissed(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: qwenSetupDismissedKey)
    }

    static func setQwenSetupDismissed(_ dismissed: Bool, defaults: UserDefaults = .standard) {
        defaults.set(dismissed, forKey: qwenSetupDismissedKey)
    }

    // MARK: - AI provider helpers

    /// Returns the user's persisted AI provider choice. Falls back to
    /// `.cuttiCloud` if the stored value is missing or unrecognized
    /// (e.g. settings file from a future build).
    static func aiProvider(defaults: UserDefaults = .standard) -> AIProviderPreference {
        guard let raw = defaults.string(forKey: aiProviderKey),
              let provider = AIProviderPreference(rawValue: raw) else {
            return .cuttiCloud
        }
        return provider
    }

    /// Snapshot of all custom-provider fields. Reads non-secret values
    /// from `UserDefaults` and the API keys from the keychain in one
    /// call so AI services don't have to thread that plumbing through
    /// every call site.
    static func customAIConfiguration(defaults: UserDefaults = .standard) -> CustomAIConfiguration {
        CustomAIConfiguration(
            llmBaseURL: defaults.string(forKey: customLLMBaseURLKey) ?? "",
            llmApiKey: KeychainStore.string(for: customLLMKeychainAccount) ?? "",
            llmModel: defaults.string(forKey: customLLMModelKey) ?? "",
            useSeparateImageProvider: defaults.bool(forKey: customUseSeparateImageProviderKey),
            imageBaseURL: defaults.string(forKey: customImageBaseURLKey) ?? "",
            imageApiKey: KeychainStore.string(for: customImageKeychainAccount) ?? "",
            imageModel: defaults.string(forKey: customImageModelKey) ?? ""
        )
    }
}
