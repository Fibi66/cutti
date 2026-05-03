import SwiftUI

/// Pill in the editor topbar that surfaces which AI backend the app
/// is currently using. Click to open Settings → AI provider.
///
/// We added this because users on the Cutti Cloud subscription can
/// also switch to BYOK at any time — without a visible indicator
/// they had no way to tell which mode they were in (and therefore
/// whether a given AI call was burning their monthly credits or
/// hitting their own API key).
///
/// Two styles:
///   .cuttiCloud  cloud icon · "Cutti Cloud"   (accent tint)
///   .custom      key   icon · "Custom · model" (neutral tint)
struct AIProviderChip: View {
    @AppStorage(CuttiSettings.aiProviderKey)
    private var providerRaw: String = AIProviderPreference.cuttiCloud.rawValue

    @AppStorage(CuttiSettings.customLLMModelKey)
    private var customModel: String = ""

    @Environment(\.openSettings) private var openSettings

    private var provider: AIProviderPreference {
        AIProviderPreference(rawValue: providerRaw) ?? .cuttiCloud
    }

    var body: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(
                Capsule().fill(tint.opacity(0.14))
            )
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var iconName: String {
        switch provider {
        case .cuttiCloud: return "cloud.fill"
        case .custom:     return "key.fill"
        }
    }

    private var label: String {
        switch provider {
        case .cuttiCloud:
            return "Cutti Cloud"
        case .custom:
            let m = customModel.trimmingCharacters(in: .whitespaces)
            return m.isEmpty ? "Custom (BYOK)" : "BYOK · \(m)"
        }
    }

    private var tint: Color {
        switch provider {
        case .cuttiCloud: return EditorShellStyle.accentSolid
        case .custom:     return EditorShellStyle.warningSolid
        }
    }

    private var helpText: LocalizedStringKey {
        switch provider {
        case .cuttiCloud:
            return "AI calls billed to your Cutti subscription. Click to change."
        case .custom:
            return "AI calls go to your own API key — no Cutti credits used. Click to change."
        }
    }
}
