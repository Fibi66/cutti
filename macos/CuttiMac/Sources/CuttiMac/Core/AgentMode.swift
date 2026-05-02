import Foundation

/// Controls whether Agent-issued `edit_timeline` batches apply
/// immediately or go through a user-approval gate.
///
/// Default is `.manual` — every destructive Agent batch surfaces as a
/// `ProposedBatch` card in chat so the user can review a diff and
/// Apply/Reject. Power users can switch to `.autoApply` to skip the
/// gate (the trace is still recorded).
enum AgentMode: String, Codable, CaseIterable, Sendable {
    case manual
    case autoApply

    var displayName: String {
        switch self {
        case .manual: return L("Manual")
        case .autoApply: return L("Auto-apply")
        }
    }

    var caption: String {
        switch self {
        case .manual:
            return L("Review every Agent edit before it applies.")
        case .autoApply:
            return L("Agent edits apply immediately; undo via revisions.")
        }
    }
}
