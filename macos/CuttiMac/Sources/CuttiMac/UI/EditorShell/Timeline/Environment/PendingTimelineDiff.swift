// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import SwiftUI

/// Aggregated pending-proposal diff passed to TimelineDock for visual preview.
/// Bundled into a single struct (vs three separate `Set<UUID>` parameters) to
/// keep TimelineDock's initializer type-checkable by the Swift compiler.
struct PendingTimelineDiff: Equatable {
    var deletions: Set<UUID>
    var speedChanges: Set<UUID>
    var volumeChanges: Set<UUID>
    static let empty = PendingTimelineDiff(deletions: [], speedChanges: [], volumeChanges: [])
}

private struct PendingTimelineDiffKey: EnvironmentKey {
    static let defaultValue: PendingTimelineDiff = .empty
}

extension EnvironmentValues {
    /// Pending Agent proposal diff consumed by `TimelineDock` to tint segments
    /// that pending proposals would touch. Injected via
    /// `.environment(\.pendingTimelineDiff, …)` to avoid adding another
    /// parameter to TimelineDock's already-large initializer (the Swift
    /// compiler struggles to type-check it otherwise).
    var pendingTimelineDiff: PendingTimelineDiff {
        get { self[PendingTimelineDiffKey.self] }
        set { self[PendingTimelineDiffKey.self] = newValue }
    }
}
