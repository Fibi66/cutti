// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import SwiftUI

/// Callbacks for the Audio dropdown in the timeline toolbar. Bundled into a
/// single struct so TimelineDock can pull them from the environment rather
/// than adding four more closures to its already-oversized initializer (the
/// Swift compiler can no longer type-check larger signatures).
struct TimelineAudioActions {
    var onNormalizeLoudness: () -> Void = {}
    var onCompressSilences: () -> Void = {}
    var onAutoDetectSpeakers: () -> Void = {}
    var onAddBGM: () -> Void = {}
    var onAddSFX: () -> Void = {}
    var isEnabled: Bool = false
    nonisolated(unsafe) static let disabled = TimelineAudioActions()
}

private struct TimelineAudioActionsKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: TimelineAudioActions = .disabled
}

extension EnvironmentValues {
    /// Audio toolbox callbacks surfaced in the timeline header.
    var timelineAudioActions: TimelineAudioActions {
        get { self[TimelineAudioActionsKey.self] }
        set { self[TimelineAudioActionsKey.self] = newValue }
    }
}
