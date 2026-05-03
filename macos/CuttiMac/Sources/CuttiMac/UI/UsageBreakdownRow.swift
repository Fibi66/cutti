import SwiftUI

/// Per-feature credit consumption table. Calls the relay's
/// `/v1/me/usage/by-feature` endpoint and renders one row per AI
/// feature (first cut, creative, agent, translate, image, overlay,
/// other) with the call count and credit total over the selected
/// window.
///
/// Deliberately coarse: we don't expose tokens / per-call credit
/// because the user doesn't care. They want to know which feature is
/// eating their monthly 5000.
struct UsageBreakdownRow: View {
    @ObservedObject private var session = RelaySession.shared
    @State private var rows: [RelaySession.FeatureUsage] = []
    @State private var loading = false
    @State private var lastError: String?
    @State private var days: Int = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(selection: $days) {
                    T("Last 7 days").tag(7)
                    T("Last 30 days").tag(30)
                    T("Last 90 days").tag(90)
                } label: {
                    T("Window")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)

                Spacer()

                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Refresh"))
                }
            }

            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if rows.isEmpty && !loading {
                T("No AI calls billed in this window yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        HStack {
                            Text(displayName(for: row.feature))
                            Spacer()
                            Text("\(row.credits) cr")
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("\(row.calls) ×")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 56, alignment: .trailing)
                        }
                        .font(.callout)
                    }
                    Divider()
                    HStack {
                        T("Total")
                            .fontWeight(.semibold)
                        Spacer()
                        Text("\(totalCredits) cr")
                            .monospacedDigit()
                            .fontWeight(.semibold)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("\(totalCalls) ×")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }

            T("Counts every AI feature billed through Cutti Cloud. Local models (Whisper transcription) are free and not shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: days) { await reload() }
    }

    private var totalCredits: Int { rows.reduce(0) { $0 + $1.credits } }
    private var totalCalls: Int { rows.reduce(0) { $0 + $1.calls } }

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

    private func displayName(for feature: String) -> LocalizedStringKey {
        switch feature {
        case "first_cut":  return "First cut"
        case "creative":   return "Creative (B-roll · overlays)"
        case "agent":      return "Agent chat"
        case "translate":  return "Subtitle translation"
        case "image":      return "Image generation"
        case "overlay":    return "Overlay rendering"
        case "other":      return "Other"
        default:           return LocalizedStringKey(feature)
        }
    }
}
