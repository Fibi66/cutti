import Foundation
import CuttiKit

// MARK: - run_first_cut
//
// Exposes the "One-click first cut" pipeline (transcribe → scene/audio
// analysis → 4-pass LLM cleanup) as an agent tool, so the chat agent can
// invoke the same flow that lives behind the ⌘⇧1 shortcut and the
// AgentWorkflowPresets entry. The tool is mutating: a pre-state revision
// is pushed before running so `restore_checkpoint` can rewind past it,
// and the resulting `userSummary` shows up in the chat trail with a
// `checkpointID` like every other revertable agent step.
//
// Parameters are intentionally minimal — the pipeline derives clip
// targets from the project itself (every "ready" clip without an
// existing copilot snapshot). An optional `clip_id` lets the agent
// re-analyze a specific clip when the user asks for that explicitly.

struct RunFirstCutRequest: Equatable, Sendable {
    /// When set, run the analysis on this single imported clip's UUID.
    /// When nil, run on every ready clip that does not yet have a
    /// copilot snapshot (matches the manual ⌘⇧1 entry point).
    var clipID: UUID?

    /// When true, re-runs the first-cut pipeline even on clips that
    /// already have a copilot snapshot. Use this when the user
    /// explicitly asks to redo the cut (e.g. "重新剪一下", "redo the
    /// first cut", "give me a different version"). Without `force`,
    /// the tool will refuse to re-bill the LLM for clips it already
    /// processed — there's a confirm dialog on the user-facing
    /// button for the same reason. Forced re-cuts overwrite the old
    /// AI output and cannot be undone via `restore_checkpoint`
    /// (revisions snapshot the timeline, not the manifest copilot
    /// blobs), so only set this when the user has explicitly opted in.
    var force: Bool

    static func parse(from args: [String: Any]) -> RunFirstCutRequest {
        let raw = (args["clip_id"] as? String).flatMap { UUID(uuidString: $0) }
        let force = args["force"] as? Bool ?? false
        return RunFirstCutRequest(clipID: raw, force: force)
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "run_first_cut",
            description: """
            Run the full AI first-cut pipeline (transcribe → analyze → 4-pass LLM cleanup) on imported clips. Auto-trims silences, duplicate takes, and half-finished sentences to produce a clean first edit. Equivalent to the manual ⌘⇧1 "One-click first cut" command.

            When to call:
            • The user asks for a vague auto-edit ("帮我剪一下", "make a first cut", "auto-edit this", "clean it up").
            • The current timeline is empty (or only contains raw imports) and the user requests any edit.
            • The user explicitly asks to redo the first cut after importing more clips.

            Slow — transcription dominates and may take minutes for long clips. Mutating: a checkpoint is pushed so the user can revert via restore_checkpoint. Skips clips that already have an analysis snapshot unless `clip_id` is given or `force` is true.

            Re-cutting (force=true): use only when the user explicitly asks to redo the cut on already-analyzed clips ("重新剪一下", "redo the first cut", "make a different version"). It overwrites the old AI output, costs another LLM round-trip, and is NOT undoable — warn the user before invoking.
            """,
            parameters: .init(
                type: "object",
                properties: [
                    "clip_id": .init(
                        type: "string",
                        description: "UUID of a specific imported clip to analyze. Omit to run on every ready clip that hasn't been analyzed yet (the usual case).",
                        items: nil
                    ),
                    "force": .init(
                        type: "boolean",
                        description: "Set true to re-cut clips that already have an analysis snapshot. The default (false) makes the tool refuse to re-bill the LLM for already-cut clips. Forced re-cuts overwrite previous AI output and cannot be undone.",
                        items: nil
                    )
                ],
                required: nil,
                items: nil
            )
        )
    )
}

struct RunFirstCutToolResult: Encodable, Sendable {
    let ok: Bool
    let segments: Int
    let totalDurationSeconds: Double
    /// Number of clips actually transcribed/analyzed in this call.
    /// Zero means everything was already cached and we just rebuilt.
    let analyzedClips: Int
    /// Total clips visible to the pipeline (ready or already analyzed).
    let totalClips: Int
    let note: String?
}
