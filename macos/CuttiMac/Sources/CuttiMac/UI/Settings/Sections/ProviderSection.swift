import SwiftUI

/// AI Provider section. Mode picker (Cutti Cloud / BYOK) at the top.
/// Cloud → friendly info card; BYOK → Chat/LLM credentials card with
/// connection status footer, optional separate Image provider card,
/// compatible-provider pills, and a soft amber "limitations of BYOK"
/// callout.
///
/// All AppStorage / KeychainStore wiring matches the legacy
/// `AIProviderSettingsSection` so existing call sites continue to work.
struct ProviderSection: View {
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

    @State private var llmAPIKey: String = ""
    @State private var imageAPIKey: String = ""

    @State private var llmStatus: ProbeStatus = .idle
    @State private var imageStatus: ProbeStatus = .idle

    @ObservedObject private var session = RelaySession.shared

    /// Last successful test result, persisted across Settings opens so
    /// "Connected · last test 14:22" doesn't reset every ⌘, cycle.
    @AppStorage("cutti.byok.llm.lastTestAt")     private var llmLastTestEpoch: Double = 0
    @AppStorage("cutti.byok.image.lastTestAt")   private var imageLastTestEpoch: Double = 0

    private var provider: AIProviderPreference {
        AIProviderPreference(rawValue: providerRaw) ?? .cuttiCloud
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "AI Provider",
                sub: "Choose where Cutti's AI runs. Cutti Cloud is fastest to start; bring your own keys for full control."
            )

            modePicker
                .padding(.bottom, 18)

            switch provider {
            case .cuttiCloud:
                cloudCard
            case .custom:
                byokSection
            }

            Spacer(minLength: 0)
        }
        .onAppear {
            llmAPIKey = KeychainStore.string(for: CuttiSettings.customLLMKeychainAccount) ?? ""
            imageAPIKey = KeychainStore.string(for: CuttiSettings.customImageKeychainAccount) ?? ""
        }
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        HStack(spacing: 10) {
            SettingsRadioCard(
                title: "Cutti Cloud",
                subtitle: "Managed · billed by credits",
                tag: "Recommended",
                selected: provider == .cuttiCloud
            ) {
                providerRaw = AIProviderPreference.cuttiCloud.rawValue
            }
            SettingsRadioCard(
                title: "Custom (BYOK)",
                subtitle: "OpenAI-compatible endpoint",
                tag: "Pro",
                selected: provider == .custom
            ) {
                providerRaw = AIProviderPreference.custom.rawValue
            }
        }
        // Substitute a real Picker for assistive tech so VoiceOver users
        // see "Provider — radio button group" instead of two unlabeled
        // card hits.
        .accessibilityRepresentation {
            Picker(selection: Binding(
                get: { provider },
                set: { providerRaw = $0.rawValue }
            )) {
                Text("Cutti Cloud").tag(AIProviderPreference.cuttiCloud)
                Text("Custom (BYOK)").tag(AIProviderPreference.custom)
            } label: {
                T("Provider")
            }
            .pickerStyle(.radioGroup)
        }
    }

    // MARK: - Cloud info

    @ViewBuilder
    private var cloudCard: some View {
        SettingsCard(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(SettingsTheme.accent)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    T("Using Cutti Cloud")
                        .font(SettingsTheme.bodyMedium)
                        .foregroundStyle(SettingsTheme.text)
                    T("All AI features available — first cut, B-roll generation, agent chat, subtitle translation, image generation, and animated overlays.")
                        .font(SettingsTheme.caption)
                        .foregroundStyle(SettingsTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }

        // Quality preference is only meaningful on Cutti Cloud — BYOK
        // users use whatever model they configure. So it lives here
        // (instead of as its own sidebar page) and disappears the moment
        // the user switches to Custom (BYOK).
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupTitle(
                title: "Quality preference",
                hint: "How Cutti picks models for first-cut and creative tasks."
            )
            HStack(alignment: .top, spacing: 8) {
                qualityCard(
                    mode: "smart",
                    title: "Smart",
                    description: "Routes between fast & premium based on task complexity. Best balance."
                )
                qualityCard(
                    mode: "high_quality",
                    title: "High Quality",
                    description: "Always uses premium models. Slower, costs more credits."
                )
                qualityCard(
                    mode: "economy",
                    title: "Economy",
                    description: "Always uses cheaper models. Fast, fewer credits."
                )
            }
            .accessibilityRepresentation {
                Picker(selection: qualityBinding) {
                    Text("Smart").tag("smart")
                    Text("High Quality").tag("high_quality")
                    Text("Economy").tag("economy")
                } label: {
                    T("Quality preference")
                }
                .pickerStyle(.radioGroup)
            }
        }
        .padding(.top, 18)
    }

    @ViewBuilder
    private func qualityCard(mode: String, title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        Button {
            qualityBinding.wrappedValue = mode
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                T(title)
                    .font(SettingsTheme.bodyMedium)
                    .foregroundStyle(SettingsTheme.text)
                T(description)
                    .font(SettingsTheme.captionFaint)
                    .foregroundStyle(SettingsTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(session.qualityMode == mode ? SettingsTheme.accentSoft : SettingsTheme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        session.qualityMode == mode ? SettingsTheme.accent : SettingsTheme.border,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var qualityBinding: Binding<String> {
        Binding(
            get: { session.qualityMode },
            set: { newValue in
                Task { await session.setQualityMode(newValue) }
            }
        )
    }

    // MARK: - BYOK

    @ViewBuilder
    private var byokSection: some View {
        SettingsGroupTitle(title: "Chat / LLM", hint: "OpenAI-compatible")

        SettingsCard(padding: nil) {
            VStack(spacing: 0) {
                SettingsRow(label: "Base URL") {
                    SettingsField(
                        text: $llmBaseURL,
                        placeholder: "https://api.deepseek.com/v1",
                        mono: true
                    )
                }
                SettingsRow(label: "API Key", sub: "Stored in macOS Keychain.") {
                    SettingsField(
                        text: $llmAPIKey,
                        placeholder: "sk-…",
                        secure: true,
                        mono: true
                    )
                    .onChange(of: llmAPIKey) { _, newValue in
                        KeychainStore.setString(
                            newValue.isEmpty ? nil : newValue,
                            for: CuttiSettings.customLLMKeychainAccount
                        )
                        llmStatus = .idle
                    }
                }
                SettingsRow(label: "Model", divider: false) {
                    SettingsField(
                        text: $llmModel,
                        placeholder: "deepseek-chat",
                        mono: true
                    )
                }

                // Status footer
                HStack(spacing: 10) {
                    statusBadge(for: llmStatus, lastTestEpoch: llmLastTestEpoch)
                    Spacer()
                    SettingsButton(
                        variant: .secondary,
                        size: .small,
                        loading: llmStatus.isInFlight,
                        disabled: llmBaseURL.isEmpty || llmAPIKey.isEmpty || llmModel.isEmpty,
                        action: { runLLMTest() },
                        label: { T("Test connection") }
                    )
                }
                .padding(.horizontal, SettingsTheme.cardPaddingH)
                .padding(.vertical, 10)
                .background(
                    SettingsTheme.borderSoft
                        .frame(height: 1),
                    alignment: .top
                )
            }
        }
        .padding(.bottom, 4)

        // Image provider
        SettingsGroupTitle(title: "Image Generation")

        SettingsCard(padding: nil) {
            VStack(spacing: 0) {
                SettingsRow(
                    label: "Use a different provider for images",
                    sub: "Most chat APIs don't generate images. Configure separately.",
                    divider: useSeparateImage
                ) {
                    SettingsToggle(
                        isOn: $useSeparateImage,
                        label: "Use a different provider for images"
                    )
                }
                if useSeparateImage {
                    SettingsRow(label: "Base URL") {
                        SettingsField(
                            text: $imageBaseURL,
                            placeholder: "https://api.openai.com/v1",
                            mono: true
                        )
                    }
                    SettingsRow(label: "API Key") {
                        SettingsField(
                            text: $imageAPIKey,
                            placeholder: "sk-…",
                            secure: true,
                            mono: true
                        )
                        .onChange(of: imageAPIKey) { _, newValue in
                            KeychainStore.setString(
                                newValue.isEmpty ? nil : newValue,
                                for: CuttiSettings.customImageKeychainAccount
                            )
                            imageStatus = .idle
                        }
                    }
                    SettingsRow(label: "Model", divider: false) {
                        SettingsField(
                            text: $imageModel,
                            placeholder: "dall-e-3",
                            mono: true
                        )
                    }

                    HStack(spacing: 10) {
                        statusBadge(for: imageStatus, lastTestEpoch: imageLastTestEpoch)
                        Spacer()
                        SettingsButton(
                            variant: .secondary,
                            size: .small,
                            loading: imageStatus.isInFlight,
                            disabled: imageBaseURL.isEmpty || imageAPIKey.isEmpty || imageModel.isEmpty,
                            action: { runImageTest() },
                            label: { T("Test connection") }
                        )
                    }
                    .padding(.horizontal, SettingsTheme.cardPaddingH)
                    .padding(.vertical, 10)
                    .background(
                        SettingsTheme.borderSoft
                            .frame(height: 1),
                        alignment: .top
                    )
                }
            }
        }
        .padding(.bottom, 14)

        compatibleProvidersCard
            .padding(.bottom, 12)

        SettingsWarningCallout(
            title: "Limitations of BYOK mode.",
            message: "Animated overlays — chapter cards, animated subtitles — are rendered server-side and require Cutti Cloud. Your custom provider handles chat, B-roll search, image generation, and subtitle translation only."
        )
    }

    // MARK: - Compatible providers

    private var compatibleProvidersCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            T("Compatible providers")
                .font(SettingsTheme.groupTitle)
                .foregroundStyle(SettingsTheme.textFaint)
                .textCase(.uppercase)
                .tracking(0.7)

            FlowLayout(spacing: 5) {
                ForEach(compatibleProviders, id: \.self) { name in
                    Text(name)
                        .font(SettingsTheme.mono(10.5))
                        .foregroundStyle(SettingsTheme.textDim)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: SettingsTheme.pillRadius)
                                .fill(SettingsTheme.panel3)
                        )
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius)
                .fill(SettingsTheme.panel2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius)
                .strokeBorder(SettingsTheme.borderSoft, lineWidth: 1)
        )
    }

    private let compatibleProviders: [String] = [
        "DeepSeek", "Kimi", "GLM", "Qwen", "Doubao",
        "Ollama", "OpenAI", "OpenRouter", "LiteLLM", "Together", "Groq"
    ]

    // MARK: - Test connection

    @ViewBuilder
    private func statusBadge(for status: ProbeStatus, lastTestEpoch: Double) -> some View {
        switch status {
        case .idle:
            if lastTestEpoch > 0 {
                SettingsStatusDotRaw(
                    tone: .neutral,
                    label: L("Idle · last test %@", Self.timeFormatter.string(from: Date(timeIntervalSince1970: lastTestEpoch)))
                )
            } else {
                SettingsStatusDot(tone: .neutral, label: "Not tested")
            }
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                T("Testing…")
                    .font(SettingsTheme.caption)
                    .foregroundStyle(SettingsTheme.textDim)
            }
        case .success:
            SettingsStatusDotRaw(
                tone: .green,
                label: L("Connected · last test %@", Self.timeFormatter.string(from: Date(timeIntervalSince1970: lastTestEpoch)))
            )
        case .failure(let msg):
            SettingsStatusDotRaw(tone: .red, label: msg)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func runLLMTest() {
        let cfg = OpenAIConfiguration.custom(
            baseURL: llmBaseURL,
            apiKey: llmAPIKey,
            model: llmModel
        )
        llmStatus = .testing
        Task {
            let result = await Self.probeLLM(configuration: cfg)
            await MainActor.run {
                llmStatus = result
                if case .success = result {
                    llmLastTestEpoch = Date().timeIntervalSince1970
                }
            }
        }
    }

    private func runImageTest() {
        let baseRaw = imageBaseURL
        let base = baseRaw.hasSuffix("/") ? String(baseRaw.dropLast()) : baseRaw
        guard let url = URL(string: "\(base)/images/generations") else {
            imageStatus = .failure(L("Invalid base URL"))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(imageAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": imageModel])
        request.timeoutInterval = 15

        imageStatus = .testing
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    await MainActor.run { imageStatus = .failure(L("Non-HTTP response")) }
                    return
                }
                let result: ProbeStatus
                switch http.statusCode {
                case 200, 400, 422: result = .success
                case 401, 403: result = .failure(L("Auth failed (%d)", http.statusCode))
                case 404:      result = .failure(L("Endpoint not found"))
                default:       result = .failure("HTTP \(http.statusCode)")
                }
                await MainActor.run {
                    imageStatus = result
                    if case .success = result {
                        imageLastTestEpoch = Date().timeIntervalSince1970
                    }
                }
            } catch {
                await MainActor.run {
                    imageStatus = .failure(error.localizedDescription)
                }
            }
        }
    }

    private static func probeLLM(configuration: OpenAIConfiguration) async -> ProbeStatus {
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
            return L("Network: %@", m)
        case .invalidResponse(let status, _):
            return "HTTP \(status)"
        case .decodingFailed:
            return L("Could not decode response")
        case .noChoices:
            return L("No choices in response")
        case .relayAuthRequired:
            return L("Auth required")
        case .relayEmailNotVerified:
            return L("Email not verified")
        case .relayQuotaExceeded:
            return L("Quota exceeded")
        }
    }

    enum ProbeStatus: Equatable {
        case idle, testing, success
        case failure(String)

        var isInFlight: Bool { self == .testing }
    }
}

// MARK: - Flow layout helper

/// Lightweight flow layout — wraps children to a new line when the
/// available width is exhausted. Used for the compatible-provider pill
/// row in `ProviderSection`.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let containerWidth = proposal.width else {
            return CGSize(width: 0, height: 0)
        }
        let arrangement = arrange(subviews: subviews, containerWidth: containerWidth)
        return arrangement.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews: subviews, containerWidth: bounds.width)
        for (index, frame) in arrangement.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.origin.x,
                            y: bounds.minY + frame.origin.y),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(subviews: Subviews, containerWidth: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > containerWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        return (frames, CGSize(width: maxWidth, height: y + lineHeight))
    }
}
