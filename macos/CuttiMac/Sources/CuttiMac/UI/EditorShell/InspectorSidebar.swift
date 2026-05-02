import SwiftUI
import CuttiKit

struct InspectorSidebar: View {
    let record: MediaAssetRecord?
    @Binding var isExpanded: Bool
    let onRelink: () -> Void

    var body: some View {
        let presentation = Self.presentation(for: record)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(EditorShellStyle.accentSolid)
                    T("AI LOG")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(EditorShellStyle.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(EditorShellStyle.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? L("Collapse AI log") : L("Expand AI log"))

            if isExpanded {
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if presentation.showsRelinkAction {
                            VStack(alignment: .leading, spacing: 6) {
                                if let errorMessage = presentation.errorMessage {
                                    Text(errorMessage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button(action: onRelink) { T("Relink Source") }
                                    .buttonStyle(.borderedProminent)
                            }
                        }

                        InspectorAIAnalysisCard(analysis: presentation.aiAnalysis)

                        if let editLog = record?.copilot?.editLog {
                            DisclosureGroup(L("Edit Decisions")) {
                                Text(editLog)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(EditorShellStyle.panelBackground)
    }

    private func row(_ title: String, _ row: Presentation.Row) -> some View {
        Group {
            if row.isDisabled {
                disabledField(title, value: row.value)
            } else {
                keyValue(title, row.value)
            }
        }
    }

    private func keyValue(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(EditorShellStyle.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(EditorShellStyle.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private func disabledField(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(EditorShellStyle.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(EditorShellStyle.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .opacity(0.7)
    }
}

extension InspectorSidebar {
    struct Presentation: Equatable {
        struct Row: Equatable {
            let value: String
            let isDisabled: Bool
        }

        let clipName: Row
        let clipStatus: Row
        let resolution: Row
        let duration: Row
        let audio: Row
        let errorMessage: String?
        let showsRelinkAction: Bool
        let aiAnalysis: AICopilotPresentation.InspectorAnalysis
    }

    static func presentation(for record: MediaAssetRecord?) -> Presentation {
        let aiAnalysis = AICopilotPresentation.inspectorAnalysis(for: record)

        guard let record else {
            return Presentation(
                clipName: placeholderRow(),
                clipStatus: placeholderRow("No clip selected"),
                resolution: placeholderRow(),
                duration: placeholderRow(),
                audio: placeholderRow(),
                errorMessage: nil,
                showsRelinkAction: false,
                aiAnalysis: aiAnalysis
            )
        }

        return Presentation(
            clipName: Presentation.Row(value: MediaRecordPresentation.title(for: record), isDisabled: false),
            clipStatus: Presentation.Row(value: MediaRecordPresentation.statusText(for: record.status), isDisabled: false),
            resolution: Presentation.Row(value: MediaRecordPresentation.inspectorResolution(for: record), isDisabled: false),
            duration: Presentation.Row(value: MediaRecordPresentation.inspectorDuration(for: record), isDisabled: false),
            audio: Presentation.Row(value: MediaRecordPresentation.inspectorAudio(for: record), isDisabled: false),
            errorMessage: record.errorMessage,
            showsRelinkAction: record.status == .missing,
            aiAnalysis: aiAnalysis
        )
    }

    private static func placeholderRow(_ value: String = "—") -> Presentation.Row {
        Presentation.Row(value: value, isDisabled: true)
    }
}

