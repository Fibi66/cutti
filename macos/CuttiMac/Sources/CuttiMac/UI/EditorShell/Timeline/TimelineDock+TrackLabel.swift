// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import AppKit
import SwiftUI
import AVFoundation
import CuttiKit

extension TimelineDock {

    // MARK: - Track label

    /// Right-click menu surfaced on every subtitle-row label (S1, S2, …)
    /// so the user can launch bilingual / translate workflows without
    /// having to dig into the AI workflow menu or the chat composer.
    /// Each item fires the same canonical prompt the AI workflow menu
    /// uses (see `AgentWorkflowPreset.SubtitlePrompts`) — so changing
    /// the prompt in one place updates both entry points. When
    /// `onRunAIPrompt` is nil (e.g. previews / tests without a chat
    /// surface) the menu renders empty so SwiftUI doesn't show a
    /// zero-item menu popup.
    @ViewBuilder
    func subtitleLaneContextMenu() -> some View {
        if let run = onRunAIPrompt {
            Button {
                run(AgentWorkflowPreset.SubtitlePrompts.bilingualZhEn)
            } label: { T("Add bilingual subtitles (中 ↔ EN)") }
            Button {
                run(AgentWorkflowPreset.SubtitlePrompts.translateToEnglish)
            } label: { T("Add English translation line") }
            Button {
                run(AgentWorkflowPreset.SubtitlePrompts.translateToChinese)
            } label: { T("Add Chinese translation line") }
            Divider()
            Button {
                run(AgentWorkflowPreset.SubtitlePrompts.translateToCustom)
            } label: { T("Translate subtitles to…") }
        }
    }

    /// Gutter row. `trackID` + `isMuted`/`isLocked` + `onToggleEye`
    /// / `onToggleLock` drive the interactive eye and lock buttons.
    /// Pass `nil` for a closure to render that button non-interactive
    /// (used by the subtitle row for lock, and by empty-project
    /// rows where the underlying Track doesn't exist yet).
    func trackLabel(
        _ label: String,
        icon: String,
        height: CGFloat,
        isMuted: Bool = false,
        isLocked: Bool = false,
        onToggleEye: (() -> Void)? = nil,
        onToggleLock: (() -> Void)? = nil
    ) -> some View {
        let lockIcon = isLocked ? "lock.fill" : "lock.open"
        let eyeIcon = isMuted ? "eye.slash" : "eye"
        let activeColor = EditorShellStyle.obText
        let inactiveColor = EditorShellStyle.obTextFaint
        return HStack(spacing: 5) {
            Button {
                onToggleLock?()
            } label: {
                Image(systemName: lockIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(onToggleLock == nil
                        ? inactiveColor
                        : (isLocked ? activeColor : EditorShellStyle.obTextDim))
            }
            .buttonStyle(.plain)
            .disabled(onToggleLock == nil)
            .help(isLocked ? "Unlock track" : "Lock track")

            Button {
                onToggleEye?()
            } label: {
                Image(systemName: eyeIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(onToggleEye == nil
                        ? inactiveColor
                        : (isMuted ? EditorShellStyle.obTextDim : activeColor))
            }
            .buttonStyle(.plain)
            .disabled(onToggleEye == nil)
            .help(isMuted ? "Show / unmute track" : "Hide / mute track")

            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(EditorShellStyle.obTextDim)
                .tracking(0.4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: gutterWidth, height: height, alignment: .leading)
        .background(EditorShellStyle.panelBackground)
        .overlay(
            Rectangle()
                .fill(EditorShellStyle.obBorderSoft)
                .frame(width: 1),
            alignment: .trailing
        )
        .overlay(
            Rectangle()
                .fill(EditorShellStyle.obBorderSoft)
                .frame(height: 1),
            alignment: .bottom
        )
    }

}
