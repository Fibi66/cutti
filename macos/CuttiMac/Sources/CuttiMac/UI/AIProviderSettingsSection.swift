import SwiftUI

/// Settings panel for choosing the AI backend (Cutti Cloud vs custom
/// OpenAI-compatible) and configuring custom-mode credentials.
///
/// Lives in its own file so the main `SettingsView` stays focused on
/// the simple AppStorage toggles.
struct AIProviderSettingsSection: View {
    @AppStorage(CuttiSettings.aiProviderKey)
    private var providerRaw: String = AIProviderPreference.cuttiCloud.rawValue

    @AppStorage(CuttiSettings.customLLMBaseURLKey)
    private var llmBaseURL: String = ""
    @AppStorage(CuttiSettings.customLLMModelKey)
    private var llmModel: String = ""

    @AppStorage(CuttiSettings.customUseSeparateImageProviderKey)
    private var useSeparateImage: Bool = false

    @AppStorage(CuttiSettings.customImageBaseURLKey)
    private var imageBaseURL: String = ""
    @AppStorage(CuttiSettings.customImageModelKey)
    private var imageModel: String = ""

    /// Mirror of the keychain-backed API keys. We pull the value into
    /// `@State` on appear and write it back on every change so SwiftUI
    /// SecureField bindings work without us needing a custom binding
    /// type. The keychain is the source of truth — `@State` is purely
    /// view-local plumbing.
    @State private var llmAPIKey: String = ""
    @State private var imageAPIKey: String = ""

    @State private var llmTestStatus: TestStatus = .idle
    @State private var imageTestStatus: TestStatus = .idle

    private var providerSelection: Binding<AIProviderPreference> {
        Binding(
            get: { AIProviderPreference(rawValue: providerRaw) ?? .cuttiCloud },
            set: { providerRaw = $0.rawValue }
        )
    }

    var body: some View {
        Section {
            Picker(selection: providerSelection) {
                ForEach(AIProviderPreference.allCases) { provider in
                    T(LocalizedStringKey(provider.title)).tag(provider)
                }
            } label: {
                T("Provider")
            }
            .pickerStyle(.segmented)

            T(LocalizedStringKey(providerSelection.wrappedValue.subtitle))
                .font(.caption)
                .foregroundStyle(.secondary)

            if providerSelection.wrappedValue == .custom {
                customConfigurationFields
            }
        } header: {
            T("AI Provider")
        }
        .onAppear {
            llmAPIKey = KeychainStore.string(for: CuttiSettings.customLLMKeychainAccount) ?? ""
            imageAPIKey = KeychainStore.string(for: CuttiSettings.customImageKeychainAccount) ?? ""
        }
    }

    @ViewBuilder
    private var customConfigurationFields: some View {
        Divider()

        // MARK: - LLM

        T("Chat / LLM")
            .font(.callout.weight(.semibold))

        TextField("Base URL", text: $llmBaseURL, prompt: Text("https://api.deepseek.com/v1"))
            .textFieldStyle(.roundedBorder)
        SecureField("API Key", text: $llmAPIKey, prompt: Text("sk-…"))
            .textFieldStyle(.roundedBorder)
            .onChange(of: llmAPIKey) { _, newValue in
                KeychainStore.setString(newValue.isEmpty ? nil : newValue,
                                        for: CuttiSettings.customLLMKeychainAccount)
                llmTestStatus = .idle
            }
        TextField("Model", text: $llmModel, prompt: Text("deepseek-chat"))
            .textFieldStyle(.roundedBorder)

        HStack {
            Button {
                runLLMTest()
            } label: {
                T("Test connection")
            }
            .disabled(llmBaseURL.isEmpty || llmAPIKey.isEmpty || llmModel.isEmpty || llmTestStatus.isInFlight)

            statusLabel(for: llmTestStatus)
        }

        T("Anything that speaks the OpenAI `/chat/completions` shape works. Examples:\n• DeepSeek — `https://api.deepseek.com/v1`, model `deepseek-chat`\n• Kimi (Moonshot) — `https://api.moonshot.cn/v1`, model `kimi-latest`\n• 智谱 GLM — `https://open.bigmodel.cn/api/paas/v4`, model `glm-4.6`\n• 通义千问 — `https://dashscope.aliyuncs.com/compatible-mode/v1`, model `qwen-max`\n• 豆包 — `https://ark.cn-beijing.volces.com/api/v3`, model `doubao-seed-1.6-thinking`\n• Ollama (local) — `http://localhost:11434/v1`, model `qwen2.5`\n• OpenAI / Azure / OpenRouter / LiteLLM proxy — same shape")
            .font(.caption)
            .foregroundStyle(.secondary)

        // MARK: - Image generation

        Toggle(isOn: $useSeparateImage) {
            T("Use a different provider for image generation")
        }
        .padding(.top, 8)

        if useSeparateImage {
            T("Image generation")
                .font(.callout.weight(.semibold))

            // Image generation is the rough edge of BYOK because there's
            // no industry-wide standard the way `/chat/completions` is.
            // We only speak the OpenAI shape here. List the handful of
            // providers that match it and gently steer everyone else
            // towards a proxy.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                T("Only OpenAI-shape image APIs are supported. Most Chinese providers (Kimi/DeepSeek don't have one; GLM CogView returns URLs not base64; 阿里万相 is async). Recommended: 字节豆包 (compatible), or route through LiteLLM / OneAPI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Base URL", text: $imageBaseURL, prompt: Text("https://ark.cn-beijing.volces.com/api/v3"))
                .textFieldStyle(.roundedBorder)
            SecureField("API Key", text: $imageAPIKey, prompt: Text("sk-…"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: imageAPIKey) { _, newValue in
                    KeychainStore.setString(newValue.isEmpty ? nil : newValue,
                                            for: CuttiSettings.customImageKeychainAccount)
                    imageTestStatus = .idle
                }
            TextField("Model", text: $imageModel, prompt: Text("doubao-seedream-4-0"))
                .textFieldStyle(.roundedBorder)

            HStack {
                Button {
                    runImageTest()
                } label: {
                    T("Test connection")
                }
                .disabled(imageBaseURL.isEmpty || imageAPIKey.isEmpty || imageModel.isEmpty || imageTestStatus.isInFlight)

                statusLabel(for: imageTestStatus)
            }
        } else {
            T("Image generation reuses the chat key and base URL above. Many providers don't expose an image API on the chat URL — if it fails, enable the toggle above and configure a separate image provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        T("⚠️ Animated overlay rendering (chapter cards, animated subtitles) is only available with Cutti Cloud.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }

    @ViewBuilder
    private func statusLabel(for status: TestStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .success:
            Label("OK", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .labelStyle(.titleAndIcon)
                .lineLimit(2)
        }
    }

    // MARK: - Test connection

    private func runLLMTest() {
        let cfg = OpenAIConfiguration.custom(
            baseURL: llmBaseURL,
            apiKey: llmAPIKey,
            model: llmModel
        )
        llmTestStatus = .testing
        Task {
            let result = await Self.probe(configuration: cfg)
            await MainActor.run { llmTestStatus = result }
        }
    }

    private func runImageTest() {
        // Image endpoint test = HEAD-equivalent: send a `model:list` style
        // probe by hitting `/images/generations` with a near-empty body
        // and accepting *any* 4xx that means "bad request" rather than
        // "auth failed". OpenAI returns 400 for missing prompt, which we
        // treat as ✅ (auth + URL good). 401/403 → ❌.
        let baseRaw = imageBaseURL
        let base = baseRaw.hasSuffix("/") ? String(baseRaw.dropLast()) : baseRaw
        guard let url = URL(string: "\(base)/images/generations") else {
            imageTestStatus = .failure("Invalid base URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(imageAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": imageModel])
        request.timeoutInterval = 15

        imageTestStatus = .testing
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    await MainActor.run { imageTestStatus = .failure("Non-HTTP response") }
                    return
                }
                let result: TestStatus
                switch http.statusCode {
                case 200, 400, 422: result = .success
                case 401, 403: result = .failure("Auth failed (\(http.statusCode))")
                case 404:      result = .failure("Endpoint not found")
                default:       result = .failure("HTTP \(http.statusCode)")
                }
                await MainActor.run { imageTestStatus = result }
            } catch {
                await MainActor.run { imageTestStatus = .failure(error.localizedDescription) }
            }
        }
    }

    /// Sends a minimum-cost chat completion to verify auth + reachability.
    /// `max_tokens: 1` so the user isn't billed for more than a few cents
    /// even on the most expensive model.
    private static func probe(configuration: OpenAIConfiguration) async -> TestStatus {
        let client = OpenAIClient(configuration: configuration)
        do {
            _ = try await client.chatCompletion(
                messages: [.user("ping")],
                tools: nil,
                toolChoice: nil,
                temperature: 0
            )
            return .success
        } catch let error as OpenAIClientError {
            return .failure(Self.shortDescription(error))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func shortDescription(_ error: OpenAIClientError) -> String {
        switch error {
        case .networkError(let m):
            return "Network: \(m)"
        case .invalidResponse(let status, _):
            return "HTTP \(status)"
        case .decodingFailed(let m):
            return "Decode: \(m)"
        case .noChoices:
            return "No choices in response"
        case .relayAuthRequired:
            return "Auth required"
        case .relayEmailNotVerified:
            return "Email not verified"
        case .relayQuotaExceeded:
            return "Quota exceeded"
        }
    }

    enum TestStatus: Equatable {
        case idle, testing, success
        case failure(String)

        var isInFlight: Bool { self == .testing }
    }
}
