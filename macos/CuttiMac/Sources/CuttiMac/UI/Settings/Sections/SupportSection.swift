import AppKit
import SwiftUI

/// Support page — Bug-report row + small Docs / Discord link cards.
struct SupportSection: View {
    @State private var showsBugReportSheet: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "Support",
                sub: "Help us make Cutti better."
            )

            SettingsCard(padding: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(SettingsTheme.panel3)
                        Image(systemName: "ladybug.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(SettingsTheme.accent)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        T("Report a bug")
                            .font(SettingsTheme.bodyMedium)
                            .foregroundStyle(SettingsTheme.text)
                        T("Reports go to our public GitHub. Diagnostics are optional.")
                            .font(SettingsTheme.caption)
                            .foregroundStyle(SettingsTheme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    SettingsButton(
                        "Report…",
                        variant: .secondary,
                        size: .medium
                    ) {
                        showsBugReportSheet = true
                    }
                }
            }
            .padding(.bottom, 8)

            HStack(spacing: 8) {
                linkCard(
                    icon: "book",
                    title: "Docs",
                    action: {
                        if let url = URL(string: "https://cutti.app/docs") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
                linkCard(
                    icon: "bubble.left.and.bubble.right",
                    title: "Discord",
                    action: {
                        if let url = URL(string: "https://discord.gg/cutti") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
            }

            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showsBugReportSheet) {
            BugReportSheet()
        }
    }

    @ViewBuilder
    private func linkCard(icon: String, title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(SettingsTheme.textDim)
                T(title)
                    .font(SettingsTheme.bodyRegular)
                    .foregroundStyle(SettingsTheme.text)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SettingsTheme.textFaint)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius)
                    .fill(SettingsTheme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius)
                    .strokeBorder(SettingsTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
