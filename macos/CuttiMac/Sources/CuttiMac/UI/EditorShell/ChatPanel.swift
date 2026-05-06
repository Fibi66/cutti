import AppKit
import SwiftUI
import CuttiKit

/// Left-side AI chat panel for natural language editing.
struct ChatPanel: View {
    let messages: [EditorChatMessage]
    let isProcessing: Bool
    @Binding var inputText: String
    let onSend: (String) -> Void
    /// Auto-send a workflow-preset prompt directly to the agent loop,
    /// bypassing the composer. The chat-history bubble shows
    /// `displayLabel` (the preset's localized title) instead of the
    /// verbose internal prompt; the LLM still receives the full
    /// prompt as the user message's `content`. Nil ⇒ workflow
    /// presets fall back to the fill-composer path only.
    var onAutoSendPrompt: ((_ prompt: String, _ displayLabel: String) -> Void)? = nil
    /// Current Agent mode. Manual shows Apply/Reject cards; Auto
    /// applies immediately. Toggle lives in the header.
    let agentMode: AgentMode
    let onSetAgentMode: (AgentMode) -> Void
    /// Resolver for the Apply/Reject card bodies. Returns nil once a
    /// proposal has been applied/rejected and dropped from the live
    /// list; the card then collapses to a compact outcome line.
    let resolveProposal: (UUID) -> ProposedBatch?
    let onApplyProposal: (UUID) -> Void
    let onRejectProposal: (UUID) -> Void
    /// Start-analysis CTA shown above the chat when any imported clip
    /// hasn't been analyzed yet. Replaces the old top-bar Start button.
    var canStartAnalysis: Bool = false
    var isAnalyzing: Bool = false
    var onStartAnalysis: () -> Void = {}
    /// Trigger the local-only trim-pauses pipeline (no LLM).
    var onRunTrimPauses: () -> Void = {}
    /// Trigger the 4-pass LLM cleanup only (no B-roll suggestion pass).
    var onRunTranscriptCleanup: () -> Void = {}
    /// Trigger only the B-roll / animation suggestion pass.
    var onRunSuggestBRoll: () -> Void = {}
    /// Trigger AI chapter-bar generation on the current edited timeline.
    var onGenerateChapters: () -> Void = {}
    /// Trigger the on-device Auto-PiP analyzer across every overlay.
    var onRunAutoPiP: () -> Void = {}
    /// Trigger to open the agent trace inspector.
    var onShowTrace: () -> Void = {}
    /// Segments the user has dragged onto the composer; when non-empty
    /// the AI is scoped to operate only within these ranges.
    var attachments: [ChatAttachment] = []
    /// IDs of segments that still exist on the timeline. Used to render
    /// stale attachments as a disabled chip instead of silently dropping
    /// them.
    var liveSegmentIDs: Set<UUID> = []
    var attachmentRecords: [MediaAssetRecord] = []
    var attachmentProjectRoot: URL? = nil
    var onAttachSegment: (UUID) -> Void = { _ in }
    var onRemoveAttachment: (UUID) -> Void = { _ in }
    var onClearAttachments: () -> Void = {}
    /// Kick off a freeform FLUX image generation — the result is
    /// imported into the Media Browser, not auto-inserted on the
    /// timeline. Called from the "make image" button above the
    /// composer. Nil ⇒ button hidden.
    var onGenerateImage: ((String) -> Void)? = nil

    @StateObject private var voiceInput = ChatVoiceInputController()
    @StateObject private var fnMonitor = FnPushToTalkMonitor()
    /// Controls whether the composer TextField holds keyboard focus.
    /// Flipped to `true` after a voice transcript is inserted so the
    /// user can immediately edit with arrow keys / delete instead of
    /// reaching for the mouse.
    @FocusState private var composerFocused: Bool

    /// Presents the "Generate image" sheet when non-nil. Kept as a
    /// @State so dismissing the sheet doesn't bounce the binding.
    @State private var showImageGenSheet = false
    @State private var imageGenPrompt: String = ""

    @AppStorage(CuttiSettings.showAgentTraceKey) private var showAgentTrace: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            // Banner removed: full-analysis now lives as the first
            // preset inside the ⚡ workflow menu in the composer.

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if messages.isEmpty {
                            chatEmptyState
                        }

                        // Index of the newest assistant role-tag (i.e.
                        // the start of the most recent assistant run).
                        // Only that one gets the thinking face — older
                        // completed assistant tags stay iconless.
                        let activeAssistantTagIdx: Int? = {
                            for i in stride(from: messages.count - 1, through: 0, by: -1) {
                                let prev: EditorChatMessage.Role? = i > 0 ? messages[i - 1].role : nil
                                if messages[i].role == .assistant && prev != .assistant {
                                    return i
                                }
                            }
                            return nil
                        }()

                        ForEach(Array(messages.enumerated()), id: \.element.id) { idx, message in
                            let prevRole: EditorChatMessage.Role? = idx > 0 ? messages[idx - 1].role : nil
                            let showRole = prevRole != message.role
                            if let pid = message.proposedBatchID {
                                ProposedBatchCard(
                                    messageContent: message.content,
                                    proposal: resolveProposal(pid),
                                    onApply: { onApplyProposal(pid) },
                                    onReject: { onRejectProposal(pid) }
                                )
                                .id(message.id)
                            } else {
                                ChatBubble(
                                    message: message,
                                    projectRoot: attachmentProjectRoot,
                                    showRoleTag: showRole,
                                    showThinkingFace: isProcessing && idx == activeAssistantTagIdx
                                )
                                    .id(message.id)
                            }
                        }

                        // Thinking indicator now lives inline inside
                        // the assistant's role tag (`✦ CUTTI 👀`). The
                        // standalone row that used to sit here was
                        // redundant once the face moved up next to
                        // the name.
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            ChatAttachmentStrip(
                attachments: attachments,
                liveSegmentIDs: liveSegmentIDs,
                records: attachmentRecords,
                projectRoot: attachmentProjectRoot,
                onRemove: onRemoveAttachment,
                onClearAll: onClearAttachments
            )

            composer
        }
        .background(EditorShellStyle.panelBackground)
        .dropDestination(for: String.self) { items, _ in
            var handled = false
            for item in items {
                // Multi-selected segments arrive as one composite
                // payload ("multi:<uuid>|<uuid>|…"); single drags use
                // the bare UUID form. Both paths end up calling
                // onAttachSegment once per UUID.
                if item.hasPrefix("multi:") {
                    let body = String(item.dropFirst("multi:".count))
                    for part in body.split(separator: "|") {
                        if let uuid = UUID(uuidString: String(part)) {
                            onAttachSegment(uuid)
                            handled = true
                        }
                    }
                } else if let uuid = UUID(uuidString: item) {
                    onAttachSegment(uuid)
                    handled = true
                }
            }
            return handled
        }
        .onAppear {
            fnMonitor.onBegin = { voiceInput.pressToTalkBegin() }
            fnMonitor.onEnd = {
                voiceInput.pressToTalkEnd { transcript in
                    appendToComposer(transcript)
                }
            }
            fnMonitor.install()
        }
        .onDisappear {
            fnMonitor.uninstall()
            voiceInput.cancel()
        }
        .sheet(isPresented: $showImageGenSheet) {
            ImageGenerationSheet(
                initialPrompt: imageGenPrompt,
                onGenerate: { prompt in
                    onGenerateImage?(prompt)
                    showImageGenSheet = false
                },
                onCancel: { showImageGenSheet = false }
            )
        }
    }

    /// Shared path for both the mic button and the Fn push-to-talk: drop
    /// the final transcript into the composer without auto-sending so the
    /// user can still edit before hitting return.
    private func appendToComposer(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if inputText.isEmpty {
            inputText = trimmed
        } else {
            let separator = inputText.hasSuffix(" ") ? "" : " "
            inputText += separator + trimmed
        }
        // Pull keyboard focus into the composer so the user can
        // immediately edit/delete the transcript. SwiftUI's
        // @FocusState alone puts us in NSTextField, which by default
        // selects all text on becoming first responder — that's the
        // wrong UX (the next keystroke would wipe everything). Jump
        // onto the next runloop tick and collapse the selection to the
        // end of the field via the AppKit text view under the hood.
        composerFocused = true
        DispatchQueue.main.async {
            moveComposerCaretToEnd()
        }
    }

    /// Finds the `NSTextView` backing whatever text field currently
    /// holds first-responder status and collapses its selection to the
    /// end. Safe no-op if the responder chain doesn't resolve to a
    /// text view (e.g., the user clicked elsewhere between focus and
    /// this dispatch).
    private func moveComposerCaretToEnd() {
        guard let responder = NSApp.keyWindow?.firstResponder else { return }
        let textView: NSTextView? = {
            if let tv = responder as? NSTextView { return tv }
            if let tf = responder as? NSTextField,
               let editor = tf.currentEditor() as? NSTextView { return editor }
            return nil
        }()
        guard let tv = textView else { return }
        let end = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: end, length: 0))
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing
    }

    /// Prominent button shown above the chat while the user has
    /// unanalyzed imported clips. Clicking kicks off the same analysis
    /// flow the removed top-bar "Start" button used to trigger.
    private var startAnalysisCTA: some View {
        Button(action: onStartAnalysis) {
            HStack(spacing: 8) {
                if isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(isAnalyzing ? "Analyzing…" : "Start AI analysis")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !isAnalyzing {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.8)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(EditorShellStyle.agentWorking)
            )
        }
        .buttonStyle(.plain)
        .disabled(isAnalyzing || !canStartAnalysis)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(EditorShellStyle.chromeBackground)
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Amber rounded-square "Clip AI" badge, matching the
            // Obsidian reference's chat-sidebar header.
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [EditorShellStyle.accentSolid, EditorShellStyle.accentSolidHover],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(EditorShellStyle.backgroundApp)
            }
            .frame(width: 20, height: 20)

            Text(L("__app_name__"))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(EditorShellStyle.textPrimary)

            Spacer()

            agentModePicker

            if showAgentTrace {
                Button(action: onShowTrace) {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(EditorShellStyle.textTertiary)
                }
                .buttonStyle(.plain)
                .help(L("Agent trace — see & undo past edits (developer)"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(EditorShellStyle.backgroundPanel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(EditorShellStyle.borderSubtle)
                .frame(height: 1)
        }
    }

    /// Compact two-segment picker that swaps the Agent between
    /// "every batch needs Apply" (Manual) and "apply immediately"
    /// (Auto). Visually subtle so it doesn't compete with the send
    /// button for attention.
    private var agentModePicker: some View {
        Menu {
            ForEach(AgentMode.allCases, id: \.self) { mode in
                Button {
                    onSetAgentMode(mode)
                } label: {
                    HStack {
                        Image(systemName: mode == agentMode ? "checkmark" : "")
                        VStack(alignment: .leading) {
                            Text(mode.displayName)
                            Text(mode.caption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: agentMode == .manual ? "hand.raised.fill" : "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(agentMode.displayName)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
            )
            .foregroundStyle(agentMode == .manual ? .primary : EditorShellStyle.accentSolid)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Switch between Manual (review every edit) and Auto-apply"))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = voiceInput.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(message)
                        .font(.system(size: 10))
                        .lineLimit(2)
                }
                .foregroundStyle(EditorShellStyle.warningSolid)
                .padding(.horizontal, 12)
            } else if voiceInput.phase == .recording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(EditorShellStyle.destructiveSolid)
                        .frame(width: 6, height: 6)
                        .opacity(0.4 + 0.6 * voiceInput.level)
                    T("Listening… release Fn (or click mic) to transcribe")
                        .font(.system(size: 10))
                        .foregroundStyle(EditorShellStyle.textSecondary)
                }
                .padding(.horizontal, 12)
            } else if voiceInput.phase == .transcribing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    T("Transcribing with the local speech model…")
                        .font(.system(size: 10))
                        .foregroundStyle(EditorShellStyle.textSecondary)
                }
                .padding(.horizontal, 12)
            }

            HStack(spacing: 8) {
                WorkflowPresetButton(
                    onSeedPromptIntoComposer: { text in
                        inputText = text
                        composerFocused = true
                    },
                    onAutoSendPrompt: { prompt, displayLabel in
                        onAutoSendPrompt?(prompt, displayLabel)
                    },
                    onRunFullAnalysis: onStartAnalysis,
                    onRunTrimPauses: onRunTrimPauses,
                    onRunTranscriptCleanup: onRunTranscriptCleanup,
                    onRunSuggestBRoll: onRunSuggestBRoll,
                    onRunChapterGeneration: onGenerateChapters,
                    onRunAutoPiP: onRunAutoPiP,
                    onOpenImageGen: {
                        imageGenPrompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                        showImageGenSheet = true
                    },
                    canStartAnalysis: canStartAnalysis,
                    isAnalyzing: isAnalyzing
                )

                TextField(
                    voiceInput.phase == .recording ? L("Listening…") : L("Ask AI · ⌘⇧P for workflows"),
                    text: $inputText,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .disabled(voiceInput.phase == .recording)
                    .focused($composerFocused)
                    // axis: .vertical makes `.onSubmit` unreliable — the
                    // field treats Return as a newline. Handle it
                    // ourselves: plain Return sends, Shift+Return
                    // inserts a newline (standard chat UX).
                    .onKeyPress(keys: [.return]) { press in
                        if press.modifiers.contains(.shift) {
                            return .ignored
                        }
                        sendMessage()
                        return .handled
                    }

                voiceButton

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(canSend ? EditorShellStyle.accentSolid : EditorShellStyle.backgroundSurface)
                        )
                        .foregroundStyle(canSend ? Color.black : EditorShellStyle.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: EditorShellStyle.radiusMedium)
                    .fill(EditorShellStyle.panelInsetBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: EditorShellStyle.radiusMedium)
                    .strokeBorder(
                        canSend || !inputText.isEmpty
                            ? EditorShellStyle.accentSolid.opacity(0.45)
                            : EditorShellStyle.borderSubtle,
                        lineWidth: 1
                    )
            )
            // Make the whole rounded-rect area a focus target, not just
            // the 1-pixel-wide TextField's internal NSTextView. Without
            // this, clicks that landed on the padding (a surprisingly
            // large hit area at this size) were swallowed by the
            // background shape and the field never became first
            // responder — hence the "placeholder stays and cursor never
            // appears" bug, especially after the user had been
            // interacting with the timeline or video preview.
            .contentShape(RoundedRectangle(cornerRadius: EditorShellStyle.radiusMedium))
            .onTapGesture {
                if voiceInput.phase != .recording {
                    composerFocused = true
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(EditorShellStyle.chromeBackground)
    }

    /// Mic button for voice-to-text input. Tapping toggles recording;
    /// when recording stops, the local speech model transcribes and
    /// the text is appended to the composer so the user can review
    /// and send.
    private var voiceButton: some View {
        Button {
            voiceInput.toggle { transcript in
                appendToComposer(transcript)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(voiceButtonBackground)
                    .frame(width: 30, height: 30)

                if voiceInput.phase == .transcribing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: voiceInput.phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(voiceButtonForeground)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(voiceInput.phase == .transcribing)
        .help(voiceButtonHelp)
    }

    /// "Generate image" is accessible exclusively through the ⚡
    /// workflow preset menu (see `AgentWorkflowPresets.gen.image`);
    /// the previous inline button next to the mic was redundant, so
    /// it has been removed. The `onGenerateImage` closure is retained
    /// on the public surface because other callers drive the FLUX
    /// sheet through it.

    private var voiceButtonBackground: Color {
        switch voiceInput.phase {
        case .recording:
            return EditorShellStyle.destructiveSolid.opacity(0.85)
        case .transcribing:
            return EditorShellStyle.backgroundSurface
        case .idle:
            return inputText.isEmpty
                ? EditorShellStyle.accentSolid.opacity(0.18)
                : EditorShellStyle.backgroundHover
        }
    }

    private var voiceButtonForeground: Color {
        switch voiceInput.phase {
        case .recording: return .white
        case .transcribing: return EditorShellStyle.textTertiary
        case .idle: return EditorShellStyle.accentSolid
        }
    }

    private var voiceButtonHelp: String {
        switch voiceInput.phase {
        case .idle: return "Dictate with the local speech model — or hold Fn to push-to-talk"
        case .recording: return "Stop and transcribe"
        case .transcribing: return "Transcribing…"
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend(text)
        inputText = ""
    }

    private var chatEmptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(EditorShellStyle.agentWorking.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Chat Bubble

private struct ChatBubble: View {
    let message: EditorChatMessage
    var projectRoot: URL? = nil
    var showRoleTag: Bool = true
    /// Render the blinking Cutti face next to the assistant's name.
    /// Only the active assistant role-tag passes `true`; idle/completed
    /// tags leave the face absent entirely.
    var showThinkingFace: Bool = false

    @State private var showFullscreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showRoleTag {
                roleTag
            }

            bubbleText
                .font(.system(size: 12.5))
                .foregroundStyle(messageTextColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let url = attachmentURL {
                ChatImageAttachmentView(
                    url: url,
                    onOpen: { showFullscreen = true }
                )
            }

            if message.checkpointID != nil {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                    T("Checkpoint saved")
                        .font(.system(size: 9, design: .monospaced))
                }
                .foregroundStyle(EditorShellStyle.obGreen.opacity(0.8))
            }
        }
        .padding(.top, showRoleTag ? 4 : 0)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showFullscreen) {
            if let url = attachmentURL {
                ChatImageFullscreenView(url: url) { showFullscreen = false }
            }
        }
    }

    /// Resolves `message.imageAttachmentPath` against the project root
    /// when it's a relative path; otherwise treats it as absolute. Nil
    /// when the message has no image or the file no longer exists.
    private var attachmentURL: URL? {
        guard let raw = message.imageAttachmentPath, !raw.isEmpty else { return nil }
        let url: URL
        if raw.hasPrefix("/") {
            url = URL(fileURLWithPath: raw)
        } else if let root = projectRoot {
            url = root.appending(path: raw)
        } else {
            url = URL(fileURLWithPath: raw)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Obsidian-style uppercase role header — `YOU` for the user,
    /// `✦ CUTTI` (amber sparkle) for the assistant, and a muted
    /// `SYSTEM` tag for system/status messages. When the agent is
    /// actively working, the Cutti face mark appears after the name
    /// and its eyes blink; it vanishes once the agent is idle.
    @ViewBuilder
    private var roleTag: some View {
        HStack(spacing: 4) {
            switch message.role {
            case .user:
                T("YOU")
            case .assistant:
                Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(EditorShellStyle.accentSolid)
                Text(L("__app_name__"))
                    .textCase(.uppercase)
                if showThinkingFace {
                    // 13.68 pt × 1.15 ≈ 15.73 pt per the designer's
                    // latest nudge (bigger but still tucked inside
                    // the role-tag line).
                    BlinkingEyesView(
                        isAnimating: true,
                        targetHeight: 15.73
                    )
                }
            case .system:
                T("SYSTEM")
            }
        }
        .font(.system(size: 9.5, weight: .semibold, design: .default))
        .tracking(0.6)
        .foregroundStyle(EditorShellStyle.textTertiary)
    }

    /// User text reads dimmer, assistant text is primary. Matches the
    /// Obsidian reference where "your words" are muted and the AI
    /// response is emphasised.
    private var messageTextColor: Color {
        switch message.role {
        case .user:      return EditorShellStyle.textSecondary
        case .assistant: return EditorShellStyle.textPrimary
        case .system:    return EditorShellStyle.textSecondary
        }
    }

    /// Renders message content with the appropriate leading indicator:
    /// - `.working` tone shows a live spinner so users can *see* the
    ///   pipeline is actively doing work (not frozen).
    /// - `.success` tone shows a bold green filled checkmark so
    ///   completion is unmistakable.
    /// - All other tones fall back to the inline SF Symbol.
    @ViewBuilder
    private var bubbleText: some View {
        if message.iconTone == .working {
            HStack(alignment: .top, spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
                Text(message.displayedContent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if message.iconTone == .success {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EditorShellStyle.obGreen)
                Text(message.displayedContent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let name = message.iconSystemName {
            (
                Text(Image(systemName: name))
                    .foregroundStyle(iconColor)
                + Text("  ")
                + Text(message.displayedContent)
            )
        } else {
            Text(message.displayedContent)
        }
    }

    private var iconColor: Color {
        switch message.iconTone {
        case .working: return EditorShellStyle.accentSolid
        case .success: return EditorShellStyle.obGreen
        case .warning: return EditorShellStyle.obSub
        case .failure: return EditorShellStyle.obRed
        case .neutral, .none:
            return EditorShellStyle.textSecondary
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >> 8)  & 0xff) / 255
        let b = Double((hex >> 0)  & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Proposed Batch Card

/// Apply/Reject card rendered in chat when the Agent proposes a batch
/// of edits. Collapses to a compact "Applied ✓" / "Rejected ✕" line
/// once the user (or Auto mode) resolves the proposal.
private struct ProposedBatchCard: View {
    let messageContent: String
    let proposal: ProposedBatch?
    let onApply: () -> Void
    let onReject: () -> Void

    var body: some View {
        if let p = proposal, p.decision == .pending {
            pendingCard(for: p)
        } else if let p = proposal {
            resolvedCard(for: p)
        } else {
            // No live proposal — history view of a long-resolved item.
            resolvedCard(for: nil)
        }
    }

    @ViewBuilder
    private func pendingCard(for p: ProposedBatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(EditorShellStyle.agentWorking)
                Text(p.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
            }

            diffChips(for: p)

            durationDelta(for: p)

            diffRowsList(for: p)

            if !p.batch.userFacingSummary.isEmpty {
                Text(p.batch.userFacingSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(EditorShellStyle.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(action: onReject) {
                    Label { T("Reject") } icon: { Image(systemName: "xmark") }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(EditorShellStyle.textSecondary)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(EditorShellStyle.backgroundSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(EditorShellStyle.borderSubtle, lineWidth: 1)
                )

                Button(action: onApply) {
                    Label { T("Apply") } icon: { Image(systemName: "checkmark") }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(EditorShellStyle.accentSolid)
                )

                Spacer()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(EditorShellStyle.agentWorking.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(EditorShellStyle.agentWorking.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func resolvedCard(for p: ProposedBatch?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: p?.decision))
                .font(.system(size: 10))
                .foregroundStyle(tintColor(for: p?.decision))
            Text(messageContent.split(separator: "\n").first.map(String.init) ?? "Proposal")
                .font(.system(size: 11))
                .foregroundStyle(EditorShellStyle.textSecondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(EditorShellStyle.backgroundSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(EditorShellStyle.borderSubtle, lineWidth: 1)
        )
    }

    private func iconName(for decision: ProposedBatch.Decision?) -> String {
        switch decision {
        case .applied: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        case .stale: return "exclamationmark.circle.fill"
        case .pending, .none: return "circle.dashed"
        }
    }

    private func tintColor(for decision: ProposedBatch.Decision?) -> Color {
        switch decision {
        case .applied: return EditorShellStyle.successSolid
        case .rejected: return EditorShellStyle.textTertiary
        case .stale: return EditorShellStyle.warningSolid
        case .pending, .none: return EditorShellStyle.textTertiary
        }
    }

    @ViewBuilder
    private func diffChips(for p: ProposedBatch) -> some View {
        HStack(spacing: 6) {
            if !p.deletedSegmentIDs.isEmpty {
                chip(
                    color: EditorShellStyle.destructiveSolid,
                    systemImage: "minus.circle.fill",
                    label: "\(p.deletedSegmentIDs.count) delete\(p.deletedSegmentIDs.count == 1 ? "" : "s")"
                )
            }
            if !p.speedChangedSegmentIDs.isEmpty {
                chip(
                    color: EditorShellStyle.accentSolid,
                    systemImage: "speedometer",
                    label: "\(p.speedChangedSegmentIDs.count) speed"
                )
            }
            if !p.volumeChangedSegmentIDs.isEmpty {
                chip(
                    color: EditorShellStyle.warningSolid,
                    systemImage: "speaker.wave.2.fill",
                    label: "\(p.volumeChangedSegmentIDs.count) volume"
                )
            }
            if p.touchesSubtitleStyle {
                chip(
                    color: EditorShellStyle.timelineAudioTrack,
                    systemImage: "textformat",
                    label: "subtitle style"
                )
            }
            Spacer()
        }
    }

    private func chip(color: Color, systemImage: String, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.18))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func durationDelta(for p: ProposedBatch) -> some View {
        let delta = p.afterTotalSeconds - p.beforeTotalSeconds
        if abs(delta) > 0.05 {
            HStack(spacing: 4) {
                Image(systemName: delta < 0 ? "arrow.down.right" : "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundStyle(delta < 0 ? EditorShellStyle.destructiveSolid : EditorShellStyle.successSolid)
                Text(String(format: "%.1fs", p.beforeTotalSeconds))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(EditorShellStyle.textTertiary)
                    .strikethrough()
                Text("→")
                    .font(.system(size: 10))
                    .foregroundStyle(EditorShellStyle.textTertiary)
                Text(String(format: "%.1fs", p.afterTotalSeconds))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(EditorShellStyle.textPrimary)
                Text(String(format: "(%@%.1fs)", delta < 0 ? "" : "+", delta))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(delta < 0 ? EditorShellStyle.destructiveSolid : EditorShellStyle.successSolid)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func diffRowsList(for p: ProposedBatch) -> some View {
        if !p.diffRows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(p.diffRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        Text("#\(row.segmentIndex)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(EditorShellStyle.textTertiary)
                            .frame(minWidth: 26, alignment: .leading)
                        Text(row.kind.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(kindColor(row.kind))
                            .frame(minWidth: 50, alignment: .leading)
                        Text(row.before)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(EditorShellStyle.textTertiary)
                            .strikethrough(row.kind == .delete)
                        Text("→")
                            .font(.system(size: 10))
                            .foregroundStyle(EditorShellStyle.textTertiary)
                        Text(row.after)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(EditorShellStyle.textPrimary)
                        Spacer()
                    }
                }
                if p.previewAppliedCount > p.diffRows.count {
                    Text(String(format: L("+%d more…"), p.previewAppliedCount - p.diffRows.count))
                        .font(.system(size: 9))
                        .foregroundStyle(EditorShellStyle.textTertiary)
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(EditorShellStyle.backgroundInset)
            )
        }
    }

    private func kindColor(_ kind: ProposedBatch.DiffRow.Kind) -> Color {
        switch kind {
        case .delete:   return EditorShellStyle.destructiveSolid
        case .speed:    return EditorShellStyle.accentSolid
        case .volume:   return EditorShellStyle.warningSolid
        case .trim:     return EditorShellStyle.timelineVideoTrack
        case .split:    return EditorShellStyle.warningSolid
        case .reorder:  return EditorShellStyle.timelineAudioTrack
        case .subtitle: return EditorShellStyle.timelineSubtitleTrack
        }
    }
}
