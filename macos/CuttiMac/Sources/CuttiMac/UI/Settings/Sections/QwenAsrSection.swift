import SwiftUI

/// Settings page for the Qwen3-ASR local sidecar — install /
/// uninstall + status. The sidecar is the *only* primary speech
/// engine; Apple SFSpeech is reserved as the system fallback when
/// Qwen isn't installed or fails at runtime, so there is no toggle
/// to disable it.
///
/// State machine drawn from `QwenAsrSidecarManager.installState`:
///   .unsupported(reason)  → message + greyed-out everything
///   .notInstalled         → "Install" button + disclosure of disk
///                           cost & what gets downloaded
///   .installing           → progress bar with phase label
///   .installed(manifest)  → Uninstall + version metadata
///   .failed(message)      → error block + Retry button
struct QwenAsrSection: View {
    @ObservedObject private var manager = QwenAsrSidecarManager.shared

    @State private var showUninstallConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "Qwen3-ASR",
                sub: "Higher-accuracy local transcription for Chinese, Cantonese and English, with per-character timestamps."
            )

            SettingsCard(padding: nil) {
                VStack(alignment: .leading, spacing: 0) {
                    statusRow
                    actionRow
                }
            }

            Spacer(minLength: 0)
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

    // MARK: - Status row

    @ViewBuilder
    private var statusRow: some View {
        SettingsRow(
            label: "Local Qwen3-ASR",
            sub: statusSubtitle,
            divider: !isOnlyRow,
            align: .top
        ) {
            statusBadge
        }
    }

    private var statusSubtitle: LocalizedStringKey {
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
    private var statusBadge: some View {
        switch manager.installState {
        case .unsupported:
            statusPill(text: "Unsupported", color: SettingsTheme.textFaint)
        case .notInstalled:
            statusPill(text: "Not installed", color: SettingsTheme.textDim)
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
            statusPill(text: "Ready", color: SettingsTheme.accent)
        case .failed:
            statusPill(text: "Failed", color: SettingsTheme.red)
        }
    }

    private func statusPill(text: LocalizedStringKey, color: Color) -> some View {
        T(text)
            .font(SettingsTheme.captionFaint)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
    }

    // MARK: - Action row

    @ViewBuilder
    private var actionRow: some View {
        switch manager.installState {
        case .unsupported:
            EmptyView()
        case .notInstalled:
            actionButtonRow {
                SettingsButton(variant: .primary, size: .medium) {
                    manager.install()
                } label: { T("Install Qwen3-ASR") }
            }
        case .installing:
            actionButtonRow {
                SettingsButton(variant: .ghost, size: .medium, disabled: true) {
                } label: { T("Installing…") }
            }
        case .installed:
            actionButtonRow {
                HStack(spacing: 10) {
                    SettingsButton(variant: .secondary, size: .medium) {
                        showUninstallConfirm = true
                    } label: { T("Uninstall") }
                    if case .running = manager.runState {
                        SettingsButton(variant: .ghost, size: .medium) {
                            Task { await manager.stop() }
                        } label: { T("Stop server") }
                    }
                }
            }
        case .failed:
            actionButtonRow {
                HStack(spacing: 10) {
                    SettingsButton(variant: .primary, size: .medium) {
                        manager.install()
                    } label: { T("Retry install") }
                    SettingsButton(variant: .secondary, size: .medium) {
                        showUninstallConfirm = true
                    } label: { T("Remove files") }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButtonRow<Trailing: View>(@ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack {
            Spacer()
            trailing()
        }
        .padding(.horizontal, SettingsTheme.cardPaddingH)
        .padding(.vertical, SettingsTheme.rowVerticalPadding)
    }

    /// True when statusRow is the only thing in the card — controls
    /// whether it draws a bottom divider.
    private var isOnlyRow: Bool {
        if case .unsupported = manager.installState { return true }
        return false
    }
}
