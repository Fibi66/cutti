import SwiftUI

/// The AI prompt field in the command bar.
/// When an API key is configured, it accepts user input and triggers
/// analysis or AI commands. Otherwise it shows a configuration prompt.
struct AICopilotPromptField: View {
    @Binding var text: String
    let isAnalyzing: Bool
    let hasAPIKey: Bool
    let onSubmit: (String) -> Void
    let onSettingsTap: () -> Void

    var body: some View {
        if hasAPIKey {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(isAnalyzing ? EditorShellStyle.agentWorking : EditorShellStyle.agentIdle)
                    .font(.system(size: 14, weight: .medium))

                TextField(L("Ask AI or describe an edit…"), text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit {
                        let value = text
                        text = ""
                        onSubmit(value)
                    }
                    .disabled(isAnalyzing)

                if isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(EditorShellStyle.panelInsetBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(EditorShellStyle.subtleBorder, lineWidth: 1)
            )
            .accessibilityLabel(L("AI prompt field"))
        } else {
            Button(action: onSettingsTap) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(EditorShellStyle.agentIdle)
                        .font(.system(size: 14, weight: .medium))

                    T("Configure API key to enable AI editing…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    T("Settings")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(EditorShellStyle.panelInsetBackground)
                        )
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(EditorShellStyle.panelInsetBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(EditorShellStyle.subtleBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Configure AI settings"))
        }
    }
}
