import AppKit
import SwiftUI

/// Support page — bug-report entry point.
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

            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showsBugReportSheet) {
            BugReportSheet()
        }
    }
}

