import SwiftUI

/// Credit Usage page. Window selector → stacked-bar chart → per-feature
/// rows + total. Wires to `session.fetchUsageByFeature(days:)`.
///
/// `total == 0` is a real state for new accounts; the chart renders an
/// empty flat strip and the table shows a "no calls billed yet"
/// placeholder rather than dividing-by-zero.
struct UsageSection: View {
    @ObservedObject private var session = RelaySession.shared

    @State private var rows: [RelaySession.FeatureUsage] = []
    @State private var loading = false
    @State private var lastError: String?
    @State private var days: Int = 30

    private var total: Int { rows.reduce(0) { $0 + $1.credits } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "Credit Usage",
                sub: "Where your credits went, by feature."
            ) {
                HStack(spacing: 6) {
                    daysMenu
                    SettingsButton(
                        variant: .ghost,
                        size: .medium,
                        loading: loading,
                        action: { Task { await reload() } },
                        label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                                T("Refresh")
                            }
                        }
                    )
                }
            }

            stackedBar
                .padding(.bottom, 14)

            if let err = lastError, !err.isEmpty {
                Text(err)
                    .font(SettingsTheme.caption)
                    .foregroundStyle(SettingsTheme.red)
                    .padding(.bottom, 10)
            }

            if rows.isEmpty && !loading {
                SettingsCard(padding: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "chart.bar.xaxis")
                            .foregroundStyle(SettingsTheme.textFaint)
                        T("No AI calls billed in this window yet.")
                            .font(SettingsTheme.caption)
                            .foregroundStyle(SettingsTheme.textDim)
                        Spacer()
                    }
                }
            } else {
                rowsCard
            }

            T("Local speech transcription runs on your Mac and is not counted.")
                .font(SettingsTheme.captionFaint)
                .foregroundStyle(SettingsTheme.textFaint)
                .padding(.top, 10)
                .padding(.leading, 2)

            Spacer(minLength: 0)
        }
        .task(id: days) { await reload() }
    }

    // MARK: - Window selector

    private var daysMenu: some View {
        Menu {
            Button { days = 7 } label: { T("Last 7 days") }
            Button { days = 30 } label: { T("Last 30 days") }
            Button { days = 90 } label: { T("Last 90 days") }
        } label: {
            HStack(spacing: 4) {
                T(daysLabel)
                    .font(SettingsTheme.caption)
                    .foregroundStyle(SettingsTheme.text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
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

    private var daysLabel: LocalizedStringKey {
        switch days {
        case 7:  return "Last 7 days"
        case 90: return "Last 90 days"
        default: return "Last 30 days"
        }
    }

    // MARK: - Stacked bar chart

    private var stackedBar: some View {
        GeometryReader { geo in
            let width = max(0, geo.size.width)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(SettingsTheme.panel3)

                if total > 0 {
                    HStack(spacing: 0) {
                        ForEach(rows.indices, id: \.self) { idx in
                            let row = rows[idx]
                            let fraction = Double(row.credits) / Double(total)
                            let isLast = idx == rows.count - 1
                            // Last segment uses maxWidth: .infinity to
                            // absorb sub-pixel rounding so the bar
                            // always fills exactly to the right edge.
                            Rectangle()
                                .fill(color(for: row.feature))
                                .frame(width: isLast ? nil : width * CGFloat(fraction))
                                .frame(maxWidth: isLast ? .infinity : nil)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
        }
        .frame(height: 8)
        // Duplicate of the table below — hidden from VoiceOver to avoid
        // double-reading the same data.
        .accessibilityHidden(true)
    }

    // MARK: - Rows card

    private var rowsCard: some View {
        SettingsCard(padding: nil) {
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { idx in
                    let row = rows[idx]
                    HStack(spacing: 12) {
                        Circle()
                            .fill(color(for: row.feature))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            T(displayName(for: row.feature))
                                .font(SettingsTheme.bodyRegular)
                                .foregroundStyle(SettingsTheme.text)
                            if let sub = displaySubtitle(for: row.feature) {
                                T(sub)
                                    .font(SettingsTheme.captionFaint)
                                    .foregroundStyle(SettingsTheme.textFaint)
                            }
                        }
                        Spacer()
                        Text("\(row.calls) " + L("calls_suffix"))
                            .font(SettingsTheme.mono(10.5))
                            .foregroundStyle(SettingsTheme.textFaint)
                            .frame(minWidth: 60, alignment: .trailing)
                        Text(row.credits.formatted())
                            .font(SettingsTheme.monoTabular)
                            .foregroundStyle(SettingsTheme.text)
                            .frame(minWidth: 60, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if idx < rows.count - 1 {
                        Rectangle()
                            .fill(SettingsTheme.borderSoft)
                            .frame(height: 1)
                    }
                }

                // Total row
                HStack(spacing: 12) {
                    Color.clear.frame(width: 8, height: 8)
                    T("Total")
                        .font(SettingsTheme.bodyMedium)
                        .foregroundStyle(SettingsTheme.text)
                    Spacer()
                    Text("\(total.formatted()) " + L("credits_suffix"))
                        .font(SettingsTheme.mono(12.5, weight: .semibold))
                        .foregroundStyle(SettingsTheme.text)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(SettingsTheme.panel2)
            }
        }
    }

    // MARK: - Helpers

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            rows = try await session.fetchUsageByFeature(days: days)
            lastError = nil
        } catch {
            lastError = (error as NSError).localizedDescription
        }
    }

    private func color(for feature: String) -> Color {
        switch feature {
        case "first_cut": return SettingsTheme.chartFirstCut
        case "creative":  return SettingsTheme.chartCreative
        case "agent":     return SettingsTheme.chartAgent
        case "translate": return SettingsTheme.chartTranslate
        case "image":     return SettingsTheme.chartImage
        case "overlay":   return SettingsTheme.chartOverlay
        default:          return SettingsTheme.chartOther
        }
    }

    private func displayName(for feature: String) -> LocalizedStringKey {
        switch feature {
        case "first_cut": return "First cut"
        case "creative":  return "Creative"
        case "agent":     return "Agent chat"
        case "translate": return "Translate"
        case "image":     return "Image"
        case "overlay":   return "Overlay"
        case "other":     return "Other"
        default:          return LocalizedStringKey(feature)
        }
    }

    private func displaySubtitle(for feature: String) -> LocalizedStringKey? {
        switch feature {
        case "creative": return "B-roll · overlays"
        default:         return nil
        }
    }
}
