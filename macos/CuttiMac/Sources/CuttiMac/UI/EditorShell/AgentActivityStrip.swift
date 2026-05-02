import SwiftUI

/// A thin strip directly below `EditorCommandBar` that surfaces the
/// aggregate AI agent state across the current project.
struct AgentActivityStrip: View {
    let status: AICopilotPresentation.AgentStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)

            Text(status.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(EditorShellStyle.textSecondary)

            Text(status.detail)
                .font(.system(size: 11))
                .foregroundStyle(EditorShellStyle.textTertiary)
                .lineLimit(1)

            if status.tone == .working {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, EditorShellStyle.panelPadding)
        .frame(height: EditorShellStyle.agentStripHeight)
        .background(EditorShellStyle.backgroundApp)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(EditorShellStyle.borderSubtle)
                .frame(height: 1)
        }
    }

    private var dotColor: Color {
        switch status.tone {
        case .idle:    return EditorShellStyle.agentIdle
        case .working: return EditorShellStyle.agentWorking
        case .ready:   return EditorShellStyle.agentReady
        }
    }
}
