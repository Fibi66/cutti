import SwiftUI

/// Developer page — power-user toggles. Currently only the agent-trace
/// toggle, but the section exists so future devtools have a home.
struct DeveloperSection: View {
    @AppStorage(CuttiSettings.showAgentTraceKey)
    private var showAgentTrace: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "Developer",
                sub: "Advanced options for power users."
            )

            SettingsCard(padding: nil) {
                SettingsRow(
                    label: "Show agent trace",
                    sub: "Reveals a step-by-step inspector for the AI editor. Most users won't need this.",
                    divider: false,
                    align: .top
                ) {
                    SettingsToggle(
                        isOn: $showAgentTrace,
                        label: "Show agent trace"
                    )
                }
            }

            Spacer(minLength: 0)
        }
    }
}
