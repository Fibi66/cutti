import SwiftUI

/// Invisible hardware-keyboard shortcut layer. Surfaces the common
/// editing verbs so Magic Keyboard / external keyboard users on iPad
/// (or iPhone) get CapCut-style velocity:
///
///   Space           — play / pause
///   ⌘Z              — undo
///   ⇧⌘Z             — redo
///   ⌘B              — split at playhead
///   ⌫ / Delete      — delete selected segment
///   ⌘D              — duplicate selected segment
///   ⌘C / ⌘X / ⌘V    — copy / cut / paste selected segment
///   ←  / →          — nudge playhead 1 frame (1/30s)
///   ⇧←  / ⇧→        — nudge playhead 1 second
///
/// Each shortcut is a zero-size Button so SwiftUI installs it into the
/// focus system without affecting layout.
struct KeyboardShortcutsLayer: View {
    @EnvironmentObject private var document: ProjectDocument
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            shortcut("Play/Pause", key: .space, mods: []) {
                document.togglePlayback()
            }
            shortcut("Undo", key: "z", mods: .command) {
                if document.canUndo { document.undo() }
            }
            shortcut("Redo", key: "z", mods: [.command, .shift]) {
                if document.canRedo { document.redo() }
            }
            shortcut("Split", key: "b", mods: .command) {
                document.splitAtPlayhead()
            }
            shortcut("Delete", key: .delete, mods: []) {
                document.deleteSelectedSegment()
            }
            shortcut("Duplicate", key: "d", mods: .command) {
                document.duplicateSelectedSegment()
            }
            shortcut("Copy", key: "c", mods: .command) {
                document.copySelectedSegment(to: appState)
            }
            shortcut("Cut", key: "x", mods: .command) {
                document.cutSelectedSegment(to: appState)
            }
            shortcut("Paste", key: "v", mods: .command) {
                document.pasteClipboardSegment(from: appState)
            }
            shortcut("Step -1f", key: .leftArrow, mods: []) {
                document.seek(toSeconds: document.currentTime - (1.0 / 30.0))
            }
            shortcut("Step +1f", key: .rightArrow, mods: []) {
                document.seek(toSeconds: document.currentTime + (1.0 / 30.0))
            }
            shortcut("Step -1s", key: .leftArrow, mods: .shift) {
                document.seek(toSeconds: document.currentTime - 1.0)
            }
            shortcut("Step +1s", key: .rightArrow, mods: .shift) {
                document.seek(toSeconds: document.currentTime + 1.0)
            }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func shortcut(
        _ label: String,
        key: KeyEquivalent,
        mods: EventModifiers,
        action: @escaping () -> Void
    ) -> some View {
        Button(label, action: action)
            .keyboardShortcut(key, modifiers: mods)
            .opacity(0)
            .frame(width: 0, height: 0)
    }
}
