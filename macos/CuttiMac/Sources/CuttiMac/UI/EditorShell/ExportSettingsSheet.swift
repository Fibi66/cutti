import SwiftUI
import CuttiKit

/// Production-ready export settings sheet.
/// Shown before the save panel to let users configure format, resolution, and review details.
struct ExportSettingsSheet: View {
    let record: MediaAssetRecord
    let segmentCount: Int
    let composedDuration: Double
    /// Whether the current timeline has any subtitle cues to emit.
    let hasSubtitles: Bool
    /// Current voice-enhancer setting; shown as a toggle in the
    /// Audio section of the sheet.
    let voiceEnhancerEnabled: Bool
    let onExport: (ExportFormat, ExportResolution, SubtitleExportOption, Bool) -> Void
    /// Invoked when the user chooses to export only the subtitle sidecar
    /// without the video. Sheet is dismissed by the caller.
    let onExportSubtitlesOnly: () -> Void
    let onCancel: () -> Void

    @State private var selectedFormat: ExportFormat = .mp4
    @State private var selectedResolution: ExportResolution = .original
    @State private var subtitleMode: SubtitleMode = .off
    @State private var selectedPresetID: String = SubtitleStyle.defaultPresetID
    @State private var enhanceVoice: Bool = false

    enum SubtitleMode: String, CaseIterable, Identifiable {
        case off      = "Off"
        case sidecarSRT = "SRT file"
        case sidecarVTT = "VTT file"
        case burnIn   = "Burn in"
        var id: String { rawValue }
    }

    private var resolvedSubtitleOption: SubtitleExportOption {
        guard hasSubtitles else { return .none }
        switch subtitleMode {
        case .off: return .none
        case .sidecarSRT: return .sidecarSRT
        case .sidecarVTT: return .sidecarVTT
        case .burnIn:
            let style = SubtitleStyle.preset(id: selectedPresetID) ?? .default
            return .burnIn(style)
        }
    }

    private var analysis: AnalysisSummary? { record.analysis }

    private var estimatedSize: String {
        guard let a = analysis else { return "—" }
        // Rough estimate: H.264 ~5 Mbps, ProRes ~100 Mbps
        let bitrate: Double = selectedFormat == .mp4 ? 5.0 : 100.0
        let resFactor: Double
        switch selectedResolution {
        case .original: resFactor = 1.0
        case .hd1080: resFactor = min(1.0, 1080.0 / Double(a.height))
        case .hd720: resFactor = min(1.0, 720.0 / Double(a.height))
        case .sd480: resFactor = min(1.0, 480.0 / Double(a.height))
        }
        let megabytes = bitrate * composedDuration * resFactor * resFactor / 8
        if megabytes > 1024 {
            return String(format: "~%.1f GB", megabytes / 1024)
        }
        return String(format: "~%.0f MB", megabytes)
    }

    private var outputResolutionLabel: String {
        guard let a = analysis else { return "—" }
        switch selectedResolution {
        case .original:
            return "\(a.width) × \(a.height)"
        case .hd1080:
            let scale = 1080.0 / Double(a.height)
            let w = Int(ceil(Double(a.width) * scale / 2) * 2)
            return "\(w) × 1080"
        case .hd720:
            let scale = 720.0 / Double(a.height)
            let w = Int(ceil(Double(a.width) * scale / 2) * 2)
            return "\(w) × 720"
        case .sd480:
            let scale = 480.0 / Double(a.height)
            let w = Int(ceil(Double(a.width) * scale / 2) * 2)
            return "\(w) × 480"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20))
                    .foregroundStyle(EditorShellStyle.agentReady)
                T("Export Video")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 20) {
                    // Overview
                    settingsSection(L("Overview")) {
                        infoRow(L("Segments"), "\(segmentCount)")
                        infoRow(L("Duration"), formatDuration(composedDuration))
                        infoRow(L("Frame Rate"), analysis.map { String(format: "%.0f fps", $0.nominalFPS) } ?? "—")
                    }

                    // Format Selection
                    settingsSection(L("Format")) {
                        Picker(selection: $selectedFormat) {
                            ForEach(ExportFormat.allCases) { format in
                                Text(format.rawValue).tag(format)
                            }
                        } label: { T("Container") }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        HStack(spacing: 16) {
                            formatCard(
                                format: .mp4,
                                icon: "doc.zipper",
                                title: "MP4 (H.264)",
                                subtitle: "Small file, web-ready\nBest for sharing"
                            )
                            formatCard(
                                format: .mov,
                                icon: "film",
                                title: "MOV (ProRes)",
                                subtitle: "Large file, high quality\nBest for further editing"
                            )
                        }
                    }

                    // Resolution
                    settingsSection(L("Resolution")) {
                        Picker(selection: $selectedResolution) {
                            ForEach(ExportResolution.allCases) { res in
                                Text(res.rawValue).tag(res)
                            }
                        } label: { T("Resolution") }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        HStack {
                            T("Output")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(outputResolutionLabel)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }

                    // Subtitles
                    settingsSection(L("Subtitles")) {
                        if hasSubtitles {
                            Picker(selection: $subtitleMode) {
                                ForEach(SubtitleMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            } label: { T("Subtitles") }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            if subtitleMode == .burnIn {
                                HStack {
                                    T("Style")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Picker(selection: $selectedPresetID) {
                                        ForEach(SubtitleStyle.allPresets, id: \.presetID) { preset in
                                            Text(preset.displayName).tag(preset.presetID ?? "")
                                        }
                                    } label: { T("Style") }
                                    .labelsHidden()
                                    .frame(width: 160)
                                }
                            }

                            Text(subtitleHint)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else {
                            T("No subtitles available. Run AI analysis or add captions to enable.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Audio enhancement
                    settingsSection(L("Audio")) {
                        Toggle(isOn: $enhanceVoice) {
                            VStack(alignment: .leading, spacing: 2) {
                                T("Voice enhancer")
                                    .font(.caption.weight(.semibold))
                                T("High-pass + compressor + limiter. Cleaner dialog at the cost of ~15s extra export time.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                    }

                    // Summary
                    settingsSection(L("Export Summary")) {
                        infoRow(L("Format"), selectedFormat == .mp4 ? "H.264 / MP4" : "ProRes 422 / MOV")
                        infoRow(L("Resolution"), outputResolutionLabel)
                        infoRow(L("Subtitles"), hasSubtitles ? subtitleMode.rawValue : "—")
                        infoRow(L("Est. File Size"), estimatedSize)
                    }
                }
                .padding(24)
            }

            Divider()

            // Actions
            HStack {
                Button { onCancel() } label: { T("Cancel") }
                .keyboardShortcut(.cancelAction)

                if hasSubtitles {
                    Button {
                        onExportSubtitlesOnly()
                    } label: {
                        Label { T("Export SRT only…") } icon: { Image(systemName: "doc.text") }
                    }
                    .help(L("Save just the subtitle sidecar without rendering the video."))
                }

                Spacer()

                Button {
                    onExport(selectedFormat, selectedResolution, resolvedSubtitleOption, enhanceVoice)
                } label: {
                    Label { T("Choose Location…") } icon: { Image(systemName: "square.and.arrow.up") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 480, height: 620)
        .background(EditorShellStyle.panelBackground)
        .onAppear { enhanceVoice = voiceEnhancerEnabled }
    }

    private var subtitleHint: String {
        switch subtitleMode {
        case .off:        return "No subtitles included."
        case .sidecarSRT: return "Writes <name>.srt next to the video — portable, editable, player-selectable."
        case .sidecarVTT: return "Writes <name>.vtt — best for web/HTML5 players."
        case .burnIn:     return "Bakes subtitles into the video pixels. Can't be turned off in the final file."
        }
    }

    // MARK: - Components

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                content()
            }
            .padding(14)
            .background(EditorShellStyle.panelInsetBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private func formatCard(
        format: ExportFormat,
        icon: String,
        title: String,
        subtitle: String
    ) -> some View {
        let isSelected = selectedFormat == format

        return Button {
            selectedFormat = format
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? EditorShellStyle.agentReady : .secondary)

                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(isSelected
                ? EditorShellStyle.accent.opacity(0.12)
                : Color.clear
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? EditorShellStyle.accent : EditorShellStyle.subtleBorder,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
