import SwiftUI
import CuttiKit

/// A thin strip of AI-generated "drop a visual here" bubbles rendered
/// directly above the V1 track. Each bubble is anchored to a composed-
/// time position derived from the underlying source-time suggestion
/// via `ComposedTimelineIndex`, so dragging/cutting segments naturally
/// repositions or hides bubbles without extra bookkeeping.
///
/// Interaction:
/// - hover → tooltip with the suggestion prompt
/// - click  → popover with kind/prompt/rationale and [Dismiss] /
///            [Generate image] (the latter is a stub pending the
///            image-gen pipeline).
struct BRollSuggestionStrip: View {
    let suggestions: [TimelineCreativeActions.BRollSuggestionHint]
    let width: CGFloat
    let totalDuration: Double
    let onDismiss: (UUID) -> Void
    /// Trigger a Remotion overlay render (or FLUX image generation —
    /// the view-model picks the right path based on hint.kind) from
    /// this suggestion. Second argument is the user's edited prompt;
    /// the view-model falls back to `hint.prompt` if it's empty.
    /// Nil ⇒ the Generate button stays disabled (fallback UX when no
    /// overlay renderer is wired, e.g. unit tests).
    var onGenerate: ((TimelineCreativeActions.BRollSuggestionHint, String) -> Void)? = nil
    /// When false, animation-kind suggestions (`.animation` / `.other`,
    /// which route through the cloud Remotion renderer) are dropped
    /// from the rendered strip entirely. BYOK users see only `.image`-
    /// family hints they can actually fulfill via their own image API.
    /// Defaults to true so existing call sites and tests keep behavior.
    var animationGenerationAvailable: Bool = true

    /// Track which bubble is currently showing its popover. Only one at
    /// a time so the strip doesn't turn into a popover storm if the
    /// user clicks multiple bubbles in quick succession.
    @State private var activeID: UUID? = nil

    /// Per-hint editable copies of the prompt. Stays populated across
    /// popover opens so a user can come back to finish typing.
    @State private var editedPrompts: [UUID: String] = [:]

    /// Hints whose Generate button is currently in flight. Used to
    /// disable the button + swap the label for a spinner so double-
    /// clicks don't spawn duplicate renders / image generations.
    @State private var generatingIDs: Set<UUID> = []

    /// In-flight experimental-confirmation request for an animation
    /// generation. Set when the user clicks "Generate animation"; the
    /// `confirmationDialog` reads from it and only invokes
    /// `onGenerate` when the user confirms. Image-family hints
    /// bypass the dialog entirely (they're a mature path).
    @State private var pendingAnimationConfirmation: PendingAnimationConfirmation? = nil

    /// Captured hint + the user's edited prompt text at the moment the
    /// experimental confirmation was raised. We need both because the
    /// edit textfield isn't owned by the dialog and we don't want a
    /// late re-edit after the user clicked Generate to silently
    /// rewrite the request.
    fileprivate struct PendingAnimationConfirmation: Identifiable {
        let id: UUID
        let hint: TimelineCreativeActions.BRollSuggestionHint
        let editedPrompt: String
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Invisible backing so the strip always claims layout
            // height even when there are no suggestions — keeps the
            // ruler → V1 vertical rhythm steady.
            Color.clear.frame(width: width, height: BRollSuggestionStrip.stripHeight)

            if totalDuration > 0 {
                ForEach(visibleSuggestions) { hint in
                    bubble(for: hint)
                }
            }
        }
        .frame(width: width, height: BRollSuggestionStrip.stripHeight, alignment: .topLeading)
        // Experimental gate. Animation generation can produce unstable
        // / low-quality / unrenderable output today, so every click on
        // "Generate animation" is wrapped in an explicit confirmation.
        // Image-family generations bypass this — they're mature and
        // the warning would just be noise.
        .confirmationDialog(
            L("Experimental: animation generation"),
            isPresented: Binding(
                get: { pendingAnimationConfirmation != nil },
                set: { if !$0 { pendingAnimationConfirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAnimationConfirmation
        ) { pending in
            Button(L("Generate anyway")) {
                triggerGenerate(hint: pending.hint, editedPrompt: pending.editedPrompt)
                pendingAnimationConfirmation = nil
            }
            Button(L("Cancel"), role: .cancel) {
                pendingAnimationConfirmation = nil
            }
        } message: { _ in
            Text(L("Animation generation is experimental — the AI may produce unstable, low-quality, or unrenderable animations, and each attempt costs cloud credits. Continue?"))
        }
    }

    /// Filters out animation-kind hints when the cloud animation
    /// pipeline is unavailable (BYOK). Image-family hints still show
    /// because BYOK users CAN run image generation through their own
    /// API. Exposed `internal` so tests can pin the behavior without
    /// SwiftUI rendering.
    var visibleSuggestions: [TimelineCreativeActions.BRollSuggestionHint] {
        Self.filterSuggestions(
            suggestions,
            animationGenerationAvailable: animationGenerationAvailable
        )
    }

    static func filterSuggestions(
        _ suggestions: [TimelineCreativeActions.BRollSuggestionHint],
        animationGenerationAvailable: Bool
    ) -> [TimelineCreativeActions.BRollSuggestionHint] {
        guard !animationGenerationAvailable else { return suggestions }
        return suggestions.filter { hint in
            switch hint.kind {
            case .image, .chart, .mapGraphic, .dataTable, .screenRecording:
                return true
            case .animation, .other:
                return false
            }
        }
    }

    /// Whether a given suggestion kind has to pass the "experimental"
    /// confirmation dialog before generation kicks off. Animation /
    /// other go through Remotion compose — currently unstable. The
    /// image-family kinds run through the proven FLUX path and don't
    /// need the gate. Exposed for tests so the routing stays pinned
    /// without rendering UI.
    static func requiresExperimentalConfirmation(_ kind: BRollSuggestion.Kind) -> Bool {
        switch kind {
        case .animation, .other:
            return true
        case .image, .chart, .mapGraphic, .dataTable, .screenRecording:
            return false
        }
    }

    /// The actual "Generate" call. Lives in its own method because
    /// both the direct (image) path and the post-confirmation
    /// (animation) path need to flip `generatingIDs`, fire the
    /// callback, schedule the auto-release, and dismiss the popover.
    private func triggerGenerate(
        hint: TimelineCreativeActions.BRollSuggestionHint,
        editedPrompt: String
    ) {
        guard let onGenerate else { return }
        generatingIDs.insert(hint.id)
        onGenerate(hint, editedPrompt)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            generatingIDs.remove(hint.id)
        }
        activeID = nil
    }

    static let stripHeight: CGFloat = 18

    @ViewBuilder
    private func bubble(for hint: TimelineCreativeActions.BRollSuggestionHint) -> some View {
        let frac = max(0, min(1, hint.composedSeconds / totalDuration))
        let x = CGFloat(frac) * width

        // Use a fixed-width container with leading padding to place the
        // bubble at the correct x. This keeps the bubble's layout frame
        // accurate so `.popover` anchors exactly on it — earlier we
        // used `.offset(x:)`, which doesn't update layout and made
        // every popover fly to the timeline's leading edge.
        HStack(spacing: 0) {
            Button {
                activeID = (activeID == hint.id) ? nil : hint.id
            } label: {
                Image(systemName: hint.kind.systemImage)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(EditorShellStyle.agentReady)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help(String(format: L("%@: %@"), hint.kind.label, hint.prompt))
            .contextMenu {
                Button(role: .destructive) {
                    onDismiss(hint.id)
                    if activeID == hint.id {
                        activeID = nil
                    }
                } label: {
                    Label { T("Delete suggestion") } icon: { Image(systemName: "trash") }
                }
            }
            .popover(isPresented: Binding(
                get: { activeID == hint.id },
                set: { if !$0 { activeID = nil } }
            ), arrowEdge: .bottom) {
                popoverBody(for: hint)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, max(0, x - 8))
        .frame(width: width, alignment: .leading)
        .padding(.top, 1)
    }

    private func popoverBody(for hint: TimelineCreativeActions.BRollSuggestionHint) -> some View {
        // Seed the editable textfield from the crisp `userTitle` when
        // available, falling back to the longer `prompt` for legacy
        // suggestions. The user's edit is what they actually want to
        // see on the overlay; the verbose `prompt` and `rationale` sit
        // in the popover body as context (and as inspiration for the
        // downstream agent).
        let seed = hint.userTitle ?? hint.prompt
        let editedBinding = Binding<String>(
            get: { editedPrompts[hint.id] ?? seed },
            set: { editedPrompts[hint.id] = $0 }
        )
        let isGenerating = generatingIDs.contains(hint.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: hint.kind.systemImage)
                    .foregroundStyle(EditorShellStyle.agentReady)
                Text(hint.kind.label)
                    .font(.system(size: 13, weight: .semibold))
                if Self.requiresExperimentalConfirmation(hint.kind) {
                    Text(L("Experimental"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.12))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.orange.opacity(0.5), lineWidth: 0.5)
                        )
                        .help(L("Animation generation may produce unstable or low-quality results. Each attempt costs cloud credits."))
                }
            }
            // Editable prompt: the user can tweak the AI's suggestion
            // before kicking off the expensive generation step.
            TextField(L("Prompt"), text: editedBinding, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .font(.system(size: 12))
                .disabled(isGenerating)
            // For new suggestions where `userTitle` was the seed, also
            // surface the longer `prompt` as a muted subtitle so the
            // user sees the full scene description without losing the
            // crisp editable headline.
            if hint.userTitle != nil, !hint.prompt.isEmpty {
                Text(hint.prompt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !hint.rationale.isEmpty {
                Text(hint.rationale)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    onDismiss(hint.id)
                    activeID = nil
                } label: { T("Dismiss") }
                .controlSize(.small)
                .disabled(isGenerating)

                // Generation routing:
                //  - .image / .chart / .mapGraphic / .dataTable /
                //    .screenRecording → FLUX still on a new overlay track
                //  - .animation / .other → Remotion ChapterTitle card
                // The view-model (`generateOverlayFromSuggestion`) does
                // the dispatch; this view just forwards the edited
                // prompt and flips the button into a "generating" state.
                let canGenerate = onGenerate != nil
                let buttonLabel = generateButtonLabel(for: hint.kind, generating: isGenerating)
                let buttonIcon = generateButtonIcon(for: hint.kind)

                Button {
                    let edited = editedBinding.wrappedValue
                    if Self.requiresExperimentalConfirmation(hint.kind) {
                        // Stash the click + the prompt the user just
                        // typed, dismiss the bubble's popover (so the
                        // dialog isn't stacked behind it), and let the
                        // confirmationDialog on the strip drive the
                        // rest. `triggerGenerate` runs only after the
                        // user confirms.
                        pendingAnimationConfirmation = PendingAnimationConfirmation(
                            id: hint.id,
                            hint: hint,
                            editedPrompt: edited
                        )
                        activeID = nil
                    } else {
                        triggerGenerate(hint: hint, editedPrompt: edited)
                    }
                } label: {
                    Label(buttonLabel, systemImage: buttonIcon)
                }
                .controlSize(.small)
                .disabled(!canGenerate || isGenerating)
                .help(canGenerate
                       ? L("Generate from this suggestion. Edit the prompt above to steer the result.")
                       : L("Generation is unavailable in this build."))
            }
        }
        .padding(10)
        .frame(width: 280, alignment: .leading)
    }

    private func generateButtonLabel(for kind: BRollSuggestion.Kind, generating: Bool) -> String {
        switch kind {
        case .image, .chart, .mapGraphic, .dataTable, .screenRecording:
            return generating ? "Generating…" : "Generate image"
        case .animation, .other:
            return generating ? "Rendering…" : "Generate animation"
        }
    }

    private func generateButtonIcon(for kind: BRollSuggestion.Kind) -> String {
        switch kind {
        case .image, .chart, .mapGraphic, .dataTable, .screenRecording:
            return "photo.badge.plus"
        case .animation, .other:
            return "wand.and.stars"
        }
    }
}
