import SwiftUI

/// Composer bolt button + popover that lists the built-in AI workflow
/// presets. Click a preset to either seed the composer or kick off the
/// full-analysis pipeline. Option-click (⌥) on a prompt preset auto-sends.
struct WorkflowPresetButton: View {
    /// Prefill the composer with a canonical prompt. Caller decides
    /// whether to auto-send based on `autoSend`.
    let onSeedPrompt: (String, _ autoSend: Bool) -> Void
    /// Kick off the deterministic full-analysis pipeline.
    let onRunFullAnalysis: () -> Void
    /// Run the local-only trim-pauses pipeline (no LLM, no credits).
    var onRunTrimPauses: () -> Void = {}
    /// Run the 4-pass LLM cleanup (no B-roll suggestions afterwards).
    var onRunTranscriptCleanup: () -> Void = {}
    /// Run the B-roll / animation suggestion pass on the current cut.
    var onRunSuggestBRoll: () -> Void = {}
    /// Kick off chapter generation on the current edited timeline.
    var onRunChapterGeneration: () -> Void = {}
    /// Kick off the on-device Auto-PiP analyzer across every overlay.
    var onRunAutoPiP: () -> Void = {}
    /// Open the freeform FLUX image-generation sheet. Nil ⇒ preset
    /// is hidden (mostly for previews/tests).
    var onOpenImageGen: () -> Void = {}
    /// Whether the full-analysis pipeline can run right now (there must
    /// be at least one unanalyzed ready clip). Used to grey out the
    /// first preset when it's a no-op.
    let canStartAnalysis: Bool
    /// Whether analysis is currently running — disables the full-
    /// analysis preset to avoid double-trigger.
    let isAnalyzing: Bool

    @State private var isPresented = false
    @State private var filter = ""

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(EditorShellStyle.backgroundSurface)
                    .frame(width: 30, height: 30)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EditorShellStyle.accentSolid)
            }
        }
        .buttonStyle(.plain)
        .help(L("AI workflows (⌘⇧P)"))
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            menuBody
                .frame(width: 320)
        }
        .background(
            Button { isPresented.toggle() } label: { T("Open workflow menu") }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .opacity(0)
            .frame(width: 0, height: 0)
        )
        .background(
            // ⌘⇧1 → One-click first cut
            Button {
                if canStartAnalysis && !isAnalyzing {
                    onRunFullAnalysis()
                }
            } label: { T("Run full analysis shortcut") }
            .keyboardShortcut("1", modifiers: [.command, .shift])
            .opacity(0)
            .frame(width: 0, height: 0)
        )
        .background(
            // ⌘⇧2 → Remove filler words
            Button {
                if let preset = AgentWorkflowPreset.all.first(where: { $0.id == "smart.fillers" }),
                   case let .seedPrompt(text) = preset.action {
                    onSeedPrompt(text, false)
                }
            } label: { T("Seed filler prompt shortcut") }
            .keyboardShortcut("2", modifiers: [.command, .shift])
            .opacity(0)
            .frame(width: 0, height: 0)
        )
        .background(
            // ⌘⇧3 → Pick an opening hook
            Button {
                if let preset = AgentWorkflowPreset.all.first(where: { $0.id == "gen.hook" }),
                   case let .seedPrompt(text) = preset.action {
                    onSeedPrompt(text, false)
                }
            } label: { T("Seed opening hook prompt shortcut") }
            .keyboardShortcut("3", modifiers: [.command, .shift])
            .opacity(0)
            .frame(width: 0, height: 0)
        )
    }

    private var menuBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(AgentWorkflowPreset.byGroup(for: CuttiSettings.aiProvider())), id: \.0) { group, presets in
                        let filtered = presets.filter { matches($0, q: filter) }
                        if !filtered.isEmpty {
                            sectionHeader(L(group.rawValue))
                            ForEach(filtered) { preset in
                                presetRow(preset)
                            }
                        }
                    }

                    if allEmpty {
                        T("No matching workflow")
                            .font(.system(size: 11))
                            .foregroundStyle(EditorShellStyle.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 420)

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                T("Click to fill · ⌥+click to send")
                    .font(.system(size: 10))
            }
            .foregroundStyle(EditorShellStyle.textTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var allEmpty: Bool {
        AgentWorkflowPreset.available(for: CuttiSettings.aiProvider())
            .allSatisfy { !matches($0, q: filter) }
    }

    private func matches(_ p: AgentWorkflowPreset, q: String) -> Bool {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        // Match against both the raw (English) key and the localized
        // string so the filter works regardless of current UI language.
        return p.title.localizedCaseInsensitiveContains(q)
            || p.subtitle.localizedCaseInsensitiveContains(q)
            || L(p.title).localizedCaseInsensitiveContains(q)
            || L(p.subtitle).localizedCaseInsensitiveContains(q)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(EditorShellStyle.textTertiary)
            TextField(L("Search workflows…"), text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: EditorShellStyle.radiusMedium)
                .fill(EditorShellStyle.backgroundInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: EditorShellStyle.radiusMedium)
                .strokeBorder(EditorShellStyle.borderSubtle, lineWidth: 1)
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(EditorShellStyle.textTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func presetRow(_ preset: AgentWorkflowPreset) -> some View {
        let disabled = isFullAnalysis(preset) && (!canStartAnalysis || isAnalyzing)
        Button {
            // Plain click = fill composer (or run pipeline for full analysis).
            invoke(preset, autoSend: false)
        } label: {
            rowBody(preset)
                .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(PresetRowButtonStyle())
        .disabled(disabled)
        .help(disabled && isFullAnalysis(preset)
              ? (isAnalyzing ? L("Analysis already running")
                             : L("All clips have already been analyzed"))
              : "")
        .contextMenu {
            if case .seedPrompt = preset.action {
                Button { invoke(preset, autoSend: true) } label: { T("Send now") }
            }
        }
        // Option-click triggers autosend for seed prompts. SwiftUI
        // buttons collapse modifier state, so we catch it via a
        // simultaneous gesture that reads the current event modifiers.
        .simultaneousGesture(
            TapGesture().modifiers(.option).onEnded {
                invoke(preset, autoSend: true)
            }
        )
    }

    @ViewBuilder
    private func rowBody(_ preset: AgentWorkflowPreset) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: preset.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(EditorShellStyle.accentSolid)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(L(preset.title))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(EditorShellStyle.textPrimary)
                    Spacer(minLength: 4)
                    if let sc = preset.shortcutLabel {
                        Text(sc)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(EditorShellStyle.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(EditorShellStyle.backgroundSurface)
                            )
                    }
                }
                Text(L(preset.subtitle))
                    .font(.system(size: 10))
                    .foregroundStyle(EditorShellStyle.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func isFullAnalysis(_ p: AgentWorkflowPreset) -> Bool {
        if case .runFullAnalysis = p.action { return true }
        return false
    }

    private func invoke(_ preset: AgentWorkflowPreset, autoSend: Bool) {
        isPresented = false
        switch preset.action {
        case .runFullAnalysis:
            onRunFullAnalysis()
        case .runTrimPauses:
            onRunTrimPauses()
        case .runTranscriptCleanup:
            onRunTranscriptCleanup()
        case .runSuggestBRoll:
            onRunSuggestBRoll()
        case .runChapterGeneration:
            onRunChapterGeneration()
        case .runAutoPiP:
            onRunAutoPiP()
        case .openImageGen:
            onOpenImageGen()
        case .seedPrompt(let text):
            onSeedPrompt(text, autoSend)
        }
    }
}

private struct PresetRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? EditorShellStyle.backgroundHover
                    : Color.clear
            )
            .onHover { hovering in
                // hover highlight handled by the overlay below via
                // environment — keep this simple and let SwiftUI
                // redraw on pressed state only.
                _ = hovering
            }
    }
}
