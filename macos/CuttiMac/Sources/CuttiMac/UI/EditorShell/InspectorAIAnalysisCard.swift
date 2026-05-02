import SwiftUI
import CuttiKit

/// Inspector card that displays AI analysis data for the selected clip.
struct InspectorAIAnalysisCard: View {
    let analysis: AICopilotPresentation.InspectorAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Label { T("AI Analysis") } icon: { Image(systemName: "sparkles") }
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(EditorShellStyle.textSecondary)
                    .labelStyle(.titleAndIcon)
                Spacer()
                if analysis.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            // Title and summary
            Text(analysis.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(EditorShellStyle.textPrimary)

            Text(analysis.supportingText)
                .font(.system(size: 11))
                .foregroundStyle(EditorShellStyle.textSecondary)

            // Transcript preview
            if let transcript = analysis.transcriptPreview {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    T("TRANSCRIPT PREVIEW")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(EditorShellStyle.textTertiary)
                    Text(transcript)
                        .font(.system(size: 11))
                        .foregroundStyle(EditorShellStyle.textPrimary)
                        .lineLimit(4)
                }
            }

            // Suggested trim
            if let trimText = analysis.suggestedTrimText {
                Divider()
                HStack {
                    T("SUGGESTED TRIM")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(EditorShellStyle.textTertiary)
                    Spacer()
                    Text(trimText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(EditorShellStyle.textPrimary)
                }
            }

            // Issues
            if !analysis.issues.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    T("ISSUES")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(EditorShellStyle.textTertiary)
                    ForEach(Array(analysis.issues.enumerated()), id: \.offset) { _, issue in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: issueIcon(for: issue.severity))
                                .foregroundStyle(issueColor(for: issue.severity))
                                .font(.system(size: 10))
                            Text(issue.title)
                                .font(.system(size: 11))
                                .foregroundStyle(EditorShellStyle.textPrimary)
                        }
                    }
                }
            }

            // Suggestions
            if !analysis.suggestions.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    T("SUGGESTIONS")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(EditorShellStyle.textTertiary)
                    ForEach(Array(analysis.suggestions.enumerated()), id: \.offset) { _, suggestion in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(EditorShellStyle.textPrimary)
                            if let detail = suggestion.detail {
                                Text(detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(EditorShellStyle.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Private helpers

    private func issueIcon(for severity: AICopilotIssue.Severity) -> String {
        switch severity {
        case .info:     return "info.circle"
        case .warning:  return "exclamationmark.triangle"
        case .critical: return "xmark.octagon"
        }
    }

    private func issueColor(for severity: AICopilotIssue.Severity) -> Color {
        switch severity {
        case .info:     return EditorShellStyle.accentSolid
        case .warning:  return EditorShellStyle.warningSolid
        case .critical: return EditorShellStyle.destructiveSolid
        }
    }
}
