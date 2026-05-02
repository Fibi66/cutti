import Foundation

/// User's choice of AI backend. Persisted in `UserDefaults` under
/// `CuttiSettings.aiProviderKey` and read by `OpenAIConfiguration`,
/// `ImageGenerationService`, and Settings UI.
///
/// `.cuttiCloud` is the default. `.custom` lets the user point Cutti at
/// any OpenAI-compatible endpoint (OpenAI, Azure, OpenRouter, Ollama,
/// LiteLLM proxy, …) using their own API key, bypassing the cutti
/// relay's billing/credit/quota machinery.
enum AIProviderPreference: String, CaseIterable, Identifiable, Sendable {
    /// Calls go through `https://api.cutti.app` with the user's session
    /// JWT. Credits, quota, subscription UI all visible.
    case cuttiCloud
    /// Calls go directly to a user-configured OpenAI-compatible endpoint
    /// using a Bearer key stored in the keychain. Credit / subscription
    /// UI is hidden.
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cuttiCloud: return "Cutti Cloud"
        case .custom:     return "Custom (BYOK)"
        }
    }

    public var subtitle: String {
        switch self {
        case .cuttiCloud:
            return "Billed via your Cutti subscription. Includes overlay rendering and the proprietary animation skill pack."
        case .custom:
            return "Bring your own OpenAI-compatible API key. No subscription needed; you pay your provider directly."
        }
    }
}

/// Snapshot of BYOK configuration. Read at the top of every AI call so
/// changes in Settings take effect immediately without restarting.
///
/// Non-secret fields come from `UserDefaults`; the `apiKey` comes from
/// the keychain (via `KeychainStore`). Empty / missing fields are
/// represented as empty strings so call sites can do a single
/// `isEmpty` check.
struct CustomAIConfiguration: Sendable, Equatable {
    /// Base URL for OpenAI-compatible chat completions. The trailing
    /// slash is normalized off; routes like `/v1/chat/completions` are
    /// appended at call time.
    var llmBaseURL: String
    var llmApiKey: String
    var llmModel: String

    /// When `useSeparateImageProvider` is `false`, the chat fields above
    /// are reused for image generation and these fields are ignored.
    var useSeparateImageProvider: Bool
    var imageBaseURL: String
    var imageApiKey: String
    var imageModel: String

    /// Effective image config — caller doesn't need to know whether the
    /// user opted for shared or split provider configuration.
    var effectiveImageBaseURL: String {
        useSeparateImageProvider ? imageBaseURL : llmBaseURL
    }
    var effectiveImageApiKey: String {
        useSeparateImageProvider ? imageApiKey : llmApiKey
    }
    var effectiveImageModel: String {
        useSeparateImageProvider ? imageModel : llmModel
    }

    /// Whether the chat config is complete enough to attempt a request.
    /// Image config completeness is checked separately via
    /// `effectiveImageBaseURL`.
    var hasUsableLLMConfig: Bool {
        !llmBaseURL.isEmpty && !llmApiKey.isEmpty && !llmModel.isEmpty
    }

    var hasUsableImageConfig: Bool {
        !effectiveImageBaseURL.isEmpty && !effectiveImageApiKey.isEmpty && !effectiveImageModel.isEmpty
    }

    /// Empty configuration — used as a placeholder before the user has
    /// configured anything. Callers should check
    /// `hasUsableLLMConfig` before issuing requests.
    static let empty = CustomAIConfiguration(
        llmBaseURL: "",
        llmApiKey: "",
        llmModel: "",
        useSeparateImageProvider: false,
        imageBaseURL: "",
        imageApiKey: "",
        imageModel: ""
    )
}
