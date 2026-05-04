import SwiftUI

/// AI Quality section — picker row in a card + 3 selectable summary
/// cards. Wires to RelaySession.qualityMode (server-authoritative).
struct QualitySection: View {
    @ObservedObject private var session = RelaySession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "AI Quality",
                sub: "How Cutti picks models for first-cut and creative tasks."
            )

            SettingsCard(padding: nil) {
                SettingsRow(label: "Quality preference", divider: false) {
                    qualityMenu
                }
            }
            .padding(.bottom, 14)

            HStack(alignment: .top, spacing: 8) {
                qualityCard(
                    mode: "smart",
                    title: "Smart",
                    description: "Routes between fast & premium based on task complexity. Best balance."
                )
                qualityCard(
                    mode: "high_quality",
                    title: "High Quality",
                    description: "Always uses premium models. Slower, costs more credits."
                )
                qualityCard(
                    mode: "economy",
                    title: "Economy",
                    description: "Always uses cheaper models. Fast, fewer credits."
                )
            }
            .accessibilityRepresentation {
                Picker(selection: qualityBinding) {
                    Text("Smart").tag("smart")
                    Text("High Quality").tag("high_quality")
                    Text("Economy").tag("economy")
                } label: {
                    T("Quality preference")
                }
                .pickerStyle(.radioGroup)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Picker menu

    private var qualityMenu: some View {
        Menu {
            Button { qualityBinding.wrappedValue = "smart" } label: { T("Smart  ·  Recommended") }
            Button { qualityBinding.wrappedValue = "high_quality" } label: { T("High Quality") }
            Button { qualityBinding.wrappedValue = "economy" } label: { T("Economy") }
        } label: {
            HStack(spacing: 4) {
                T(qualityLabel(for: session.qualityMode))
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func qualityLabel(for mode: String) -> LocalizedStringKey {
        switch mode {
        case "high_quality": return "High Quality"
        case "economy":      return "Economy"
        default:             return "Smart  ·  Recommended"
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private func qualityCard(mode: String, title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        Button {
            qualityBinding.wrappedValue = mode
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                T(title)
                    .font(SettingsTheme.bodyMedium)
                    .foregroundStyle(SettingsTheme.text)
                T(description)
                    .font(SettingsTheme.captionFaint)
                    .foregroundStyle(SettingsTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(session.qualityMode == mode ? SettingsTheme.accentSoft : SettingsTheme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        session.qualityMode == mode ? SettingsTheme.accent : SettingsTheme.border,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Binding

    private var qualityBinding: Binding<String> {
        Binding(
            get: { session.qualityMode },
            set: { newValue in
                Task { await session.setQualityMode(newValue) }
            }
        )
    }
}
