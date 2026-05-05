import AppKit
import SwiftUI

/// "General" page — default editing behaviors, interface language, and
/// the local speech-model install/uninstall block.
///
/// The local speech-model block was previously its own sidebar entry
/// (Qwen3-ASR) and the interface-language picker lived under Video
/// Editor. Both moved here once Qwen became the only primary engine
/// (no toggle, no per-language preference) — so there's nothing left
/// to surface as a separate sidebar entry. Install / Uninstall / Stop
/// remain reachable here so users can free disk space without going
/// hunting.
struct GeneralSection: View {
    @AppStorage(CuttiSettings.subtitlesVisibleByDefaultKey)
    private var subtitlesVisibleByDefault: Bool = true

    @AppStorage(CuttiSettings.uiLanguageKey)
    private var uiLanguage: String = CuttiSettings.uiLanguageSystem

    /// Captured when the section appears so we can detect a real
    /// change vs. just initial value reads when prompting for a
    /// restart.
    @State private var initialUILanguage: String = CuttiSettings.uiLanguageSystem
    @State private var showRestartPrompt: Bool = false

    @ObservedObject private var qwenManager = QwenAsrSidecarManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "General",
                sub: "Default behaviors, language, and the local speech model."
            )

            SettingsCard(padding: nil) {
                SettingsRow(
                    label: "Show subtitles by default",
                    sub: "When you create a new clip, the subtitle overlay is visible in preview and timeline.",
                    align: .top
                ) {
                    SettingsToggle(
                        isOn: $subtitlesVisibleByDefault,
                        label: "Show subtitles by default"
                    )
                }

                SettingsRow(
                    label: "Interface language",
                    sub: "Changing this restarts Cutti.",
                    divider: showsLocalSpeechModel
                ) {
                    Menu {
                        Button { uiLanguage = CuttiSettings.uiLanguageSystem } label: { T("System") }
                        Button { uiLanguage = CuttiSettings.uiLanguageEnglish } label: { T("English") }
                        Button { uiLanguage = CuttiSettings.uiLanguageChinese } label: { T("Chinese") }
                    } label: {
                        menuLabel(text: uiLanguageDisplay)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                if showsLocalSpeechModel {
                    LocalSpeechModelRow(manager: qwenManager)
                }
            }

            Spacer(minLength: 0)
        }
        .onAppear { initialUILanguage = uiLanguage }
        .onChange(of: uiLanguage) { _, newValue in
            if newValue != initialUILanguage {
                showRestartPrompt = true
            }
        }
        .alert(L("Restart Required"), isPresented: $showRestartPrompt) {
            Button(role: .cancel) {
                uiLanguage = initialUILanguage
            } label: {
                T("Cancel")
            }
            Button {
                relaunchApp()
            } label: {
                T("Apply & Restart")
            }
        } message: {
            T("Changing the interface language requires restarting Cutti. Your project and unsaved edits will be preserved.")
        }
    }

    /// Show the Local-speech-model row whenever there's something to
    /// manage:
    ///   - the host can run Qwen (Apple Silicon + direct distribution),
    ///     so users can discover + install, OR
    ///   - install state is anything other than `.notInstalled` /
    ///     `.unsupported`, so users can always uninstall stale or
    ///     in-progress installs even if the host gate later changed.
    private var showsLocalSpeechModel: Bool {
        if qwenAsrHostIsAppleSilicon() && CuttiDistribution.current == .direct {
            return true
        }
        switch qwenManager.installState {
        case .installing, .installed, .failed:
            return true
        case .unsupported, .notInstalled:
            return false
        }
    }

    private var uiLanguageDisplay: String {
        switch uiLanguage {
        case CuttiSettings.uiLanguageEnglish: return L("System  ·  English")
        case CuttiSettings.uiLanguageChinese: return L("System  ·  Chinese")
        default:                              return L("System")
        }
    }

    private func menuLabel(text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(SettingsTheme.bodyRegular)
                .foregroundStyle(SettingsTheme.text)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SettingsTheme.textFaint)
        }
        .padding(.horizontal, 10)
        .frame(height: SettingsTheme.controlHeightMedium)
        .background(
            RoundedRectangle(cornerRadius: SettingsTheme.controlRadius)
                .fill(SettingsTheme.panel2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsTheme.controlRadius)
                .strokeBorder(SettingsTheme.border, lineWidth: 1)
        )
    }

    /// Identical relaunch logic to the legacy SettingsView.
    private func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let isAppBundle = bundleURL.pathExtension == "app"

        let task = Process()
        if isAppBundle {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", bundleURL.path]
        } else if let executableURL = Bundle.main.executableURL {
            task.executableURL = executableURL
        } else {
            NSApp.terminate(nil)
            return
        }
        do {
            try task.run()
        } catch {
            print("Failed to relaunch cutti: \(error)")
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Local speech model row

/// Compact row replacing the former dedicated "Qwen3-ASR" settings
/// page. Surfaces install state + the only two actions that matter
/// (Install / Uninstall) plus a "Stop server" affordance for users
/// who want to free MPS memory without uninstalling.
private struct LocalSpeechModelRow: View {
    @ObservedObject var manager: QwenAsrSidecarManager
    @State private var showUninstallConfirm = false

    var body: some View {
        SettingsRow(
            label: "Local speech model",
            sub: subtitle,
            divider: false,
            align: .top
        ) {
            controls
        }
        .alert(L("Uninstall Qwen3-ASR?"), isPresented: $showUninstallConfirm) {
            Button(role: .cancel) { } label: { T("Cancel") }
            Button(role: .destructive) {
                Task { await manager.uninstall() }
            } label: { T("Uninstall") }
        } message: {
            T("This frees about 6 GB by deleting the Python runtime and the Qwen3-ASR / ForcedAligner models. After uninstall, transcription falls back to Apple Speech. You can reinstall later.")
        }
    }

    private var subtitle: LocalizedStringKey {
        switch manager.installState {
        case .unsupported(let reason):
            return LocalizedStringKey(reason)
        case .notInstalled:
            return "Not installed. Downloads about 6 GB on install (Python runtime + ASR + ForcedAligner). Without this, transcription uses Apple Speech."
        case .installing:
            return LocalizedStringKey(manager.installPhase.displayLabel)
        case .installed(let manifest):
            return LocalizedStringKey("Installed. Python \(manifest.pythonVersion). Models: \(QwenAsrSidecar.Models.asrRepo) + ForcedAligner.")
        case .failed(let msg):
            return LocalizedStringKey(msg)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch manager.installState {
        case .unsupported:
            statusPill(text: "Unsupported", color: SettingsTheme.textFaint)
        case .notInstalled:
            SettingsButton(variant: .primary, size: .medium) {
                manager.install()
            } label: { T("Install") }
        case .installing:
            VStack(alignment: .trailing, spacing: 6) {
                ProgressView(value: manager.overallProgress)
                    .frame(width: 160)
                    .tint(SettingsTheme.accent)
                Text("\(Int(manager.overallProgress * 100))%")
                    .font(SettingsTheme.captionFaint)
                    .foregroundStyle(SettingsTheme.textDim)
                    .monospacedDigit()
            }
        case .installed:
            HStack(spacing: 8) {
                if case .running = manager.runState {
                    SettingsButton(variant: .ghost, size: .medium) {
                        Task { await manager.stop() }
                    } label: { T("Stop server") }
                }
                SettingsButton(variant: .secondary, size: .medium) {
                    showUninstallConfirm = true
                } label: { T("Uninstall") }
            }
        case .failed:
            HStack(spacing: 8) {
                SettingsButton(variant: .primary, size: .medium) {
                    manager.install()
                } label: { T("Retry install") }
                SettingsButton(variant: .secondary, size: .medium) {
                    showUninstallConfirm = true
                } label: { T("Remove files") }
            }
        }
    }

    private func statusPill(text: LocalizedStringKey, color: Color) -> some View {
        T(text)
            .font(SettingsTheme.captionFaint)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
