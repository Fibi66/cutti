import Foundation

enum EditorLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case chinese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .chinese:
            return "Chinese"
        case .english:
            return "English"
        }
    }

    func resolvedLocale(fallback: Locale) -> Locale {
        switch self {
        case .automatic:
            return fallback
        case .chinese:
            return Locale(identifier: "zh-CN")
        case .english:
            return Locale(identifier: "en-US")
        }
    }

    func resolvedWhisperLanguageCode(fallback: Locale) -> String {
        switch self {
        case .automatic:
            let languageCode = fallback.language.languageCode?.identifier.prefix(2).lowercased() ?? "en"
            return languageCode == "zh" ? "zh" : "en"
        case .chinese:
            return "zh"
        case .english:
            return "en"
        }
    }

    func resolvedPrimaryBackend(fallback: Locale) -> SpeechRecognitionBackend {
        // Whisper is the default for both languages now: Apple SFSpeech
        // accumulates per-segment timing drift on long Chinese files
        // (subtitles end up arriving seconds before the audio in the
        // final cut), and its phrase-level substring grouping forces
        // multi-character cues that show their full text the instant
        // the first syllable plays. WhisperKit gives genuine per-word
        // timestamps that stay aligned with the source audio for the
        // length of the file, which is what we need for editor-grade
        // subtitle timing. Apple Speech remains as the fallback when
        // Whisper isn't yet downloaded or fails.
        switch self {
        case .automatic, .chinese, .english:
            return .whisperKit
        }
    }
}

enum SpeechRecognitionBackend: String, Sendable {
    case appleSpeech
    case whisperKit

    var title: String {
        switch self {
        case .appleSpeech:
            return "Apple Speech"
        case .whisperKit:
            return "Whisper"
        }
    }
}

struct SpeechRecognitionProfile: Sendable {
    let languagePreference: EditorLanguagePreference
    let locale: Locale
    let whisperLanguageCode: String
    let primaryBackend: SpeechRecognitionBackend
    let fallbackBackend: SpeechRecognitionBackend
}

enum CuttiSettings {
    static let subtitlesVisibleByDefaultKey = "cutti.subtitlesVisibleByDefault"
    static let editorLanguageKey = "cutti.editorLanguage"
    static let showAgentTraceKey = "cutti.showAgentTrace"
    /// User's preferred UI language. Independent from `editorLanguageKey`,
    /// which controls speech recognition. Values: "system" / "en" / "zh-Hans".
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

    static func ensureDefaults(defaults: UserDefaults = .standard) {
        if defaults.object(forKey: subtitlesVisibleByDefaultKey) == nil {
            defaults.set(true, forKey: subtitlesVisibleByDefaultKey)
        }
        if defaults.object(forKey: editorLanguageKey) == nil {
            defaults.set(EditorLanguagePreference.automatic.rawValue, forKey: editorLanguageKey)
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

    static func editorLanguage(defaults: UserDefaults = .standard) -> EditorLanguagePreference {
        guard let rawValue = defaults.string(forKey: editorLanguageKey),
              let language = EditorLanguagePreference(rawValue: rawValue) else {
            return .automatic
        }
        return language
    }

    static func resolvedSpeechProfile(
        defaults: UserDefaults = .standard,
        fallbackLocale: Locale = .current
    ) -> SpeechRecognitionProfile {
        let languagePreference = editorLanguage(defaults: defaults)
        let primaryBackend = languagePreference.resolvedPrimaryBackend(fallback: fallbackLocale)
        let fallbackBackend: SpeechRecognitionBackend = primaryBackend == .appleSpeech ? .whisperKit : .appleSpeech

        return SpeechRecognitionProfile(
            languagePreference: languagePreference,
            locale: languagePreference.resolvedLocale(fallback: fallbackLocale),
            whisperLanguageCode: languagePreference.resolvedWhisperLanguageCode(fallback: fallbackLocale),
            primaryBackend: primaryBackend,
            fallbackBackend: fallbackBackend
        )
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
