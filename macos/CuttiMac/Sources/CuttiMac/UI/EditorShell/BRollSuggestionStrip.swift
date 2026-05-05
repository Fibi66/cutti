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
            Text(L("Animation generation is experimental — the AI may produce unstable, low-quality, or unrenderable animations, and each attempt consumes a large amount of cloud credits. Continue?"))
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
        // Seed the editable field with BOTH the crisp `userTitle`
        // headline AND the longer scene description (`prompt`), joined
        // by a blank line. Earlier versions exposed only the headline
        // as editable and rendered `prompt` as static text below — but
        // the brief that ships to the agent never carried `prompt`,
        // so users couldn't actually steer the generation. Now the
        // whole scene description is editable and travels to the
        // agent verbatim as `userEdit` (the strongest signal in the
        // server prompt).
        let headline = (hint.userTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = hint.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed: String = {
            if !headline.isEmpty, !body.isEmpty, headline != body { return "\(headline)\n\n\(body)" }
            if !headline.isEmpty { return headline }
            return body
        }()
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
            // Editable scene prompt. The user can rewrite the whole
            // description before kicking off the expensive generation
            // step; whatever they type is forwarded to the agent as
            // `userEdit` (the strongest signal in the compose prompt).
            TextField(L("Describe the animation"), text: editedBinding, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...12)
                .font(.system(size: 12))
                .disabled(isGenerating)
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
        .frame(width: 340, alignment: .leading)
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
