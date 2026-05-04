import SwiftUI

/// "General" page — default behaviors when starting a new clip session.
struct GeneralSection: View {
    @AppStorage(CuttiSettings.subtitlesVisibleByDefaultKey)
    private var subtitlesVisibleByDefault: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "General",
                sub: "Default behaviors when starting a new clip session."
            )

            SettingsCard(padding: nil) {
                SettingsRow(
                    label: "Show subtitles by default",
                    sub: "When you create a new clip, the subtitle overlay is visible in preview and timeline.",
                    divider: false,
                    align: .top
                ) {
                    SettingsToggle(
                        isOn: $subtitlesVisibleByDefault,
                        label: "Show subtitles by default"
                    )
                }
            }

            Spacer(minLength: 0)
        }
    }
}
