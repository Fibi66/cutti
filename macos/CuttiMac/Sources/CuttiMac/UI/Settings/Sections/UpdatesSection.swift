import SwiftUI

/// "Updates" page — surfaces Sparkle's auto-update controls in cutti's
/// own Obsidian-Pro settings chrome instead of Sparkle's default AppKit
/// Preferences pane.
///
/// Visibility: routed by `SettingsView.visibleSections` and only
/// included when `SparkleUpdater.shared.isEnabled` is true. That gate
/// is itself driven by `CuttiDistribution.current` — Mac App Store
/// builds never see this section because Apple handles updates.
///
/// The two toggles are bound via `@AppStorage` to the UserDefaults keys
/// Sparkle reads internally:
///   - `SUEnableAutomaticChecks` — Sparkle ticks at the configured
///      interval (default ~24 h) and surfaces a system notification.
///   - `SUAutomaticallyUpdate` — when an update is found, download and
///      install it on next quit instead of prompting.
struct UpdatesSection: View {
    @EnvironmentObject private var updater: SparkleUpdater

    @AppStorage("SUEnableAutomaticChecks") private var autoCheck: Bool = true
    @AppStorage("SUAutomaticallyUpdate")   private var autoInstall: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "Updates",
                sub: "Cutti checks GitHub Releases for new versions."
            )

            SettingsCard(padding: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(SettingsTheme.panel3)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 14))
                            .foregroundStyle(SettingsTheme.accent)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        T(currentVersionTitle)
                            .font(SettingsTheme.bodyMedium)
                            .foregroundStyle(SettingsTheme.text)
                        T(lastCheckSubtitle)
                            .font(SettingsTheme.caption)
                            .foregroundStyle(SettingsTheme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    SettingsButton(
                        "Check Now",
                        variant: .secondary,
                        size: .medium,
                        disabled: !updater.canCheckForUpdates
                    ) {
                        updater.checkForUpdates()
                    }
                }
            }

            SettingsGroupTitle(title: "Preferences")

            SettingsCard(padding: nil) {
                SettingsRow(
                    label: "Automatically check for updates",
                    sub: "Cutti checks for new versions in the background once per day."
                ) {
                    SettingsToggle(isOn: $autoCheck,
                                   label: "Automatically check for updates")
                }
                SettingsRow(
                    label: "Automatically install updates",
                    sub: "Download and install new versions on quit, without asking. Off by default.",
                    divider: false
                ) {
                    SettingsToggle(isOn: $autoInstall,
                                   label: "Automatically install updates")
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    private var currentVersionTitle: LocalizedStringKey {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "—"
        let build = (info?["CFBundleVersion"] as? String) ?? "—"
        return LocalizedStringKey("Version \(version) (build \(build))")
    }

    private var lastCheckSubtitle: LocalizedStringKey {
        guard let date = updater.lastUpdateCheckDate else {
            return "Never checked yet."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return LocalizedStringKey("Last checked \(relative).")
    }
}
