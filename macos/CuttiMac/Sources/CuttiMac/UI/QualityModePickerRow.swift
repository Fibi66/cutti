import SwiftUI

/// Three-way picker that controls which Azure deployment the relay
/// uses for this user. The open-source client only sends the user's
/// chosen mode up — all model routing + billing logic stays
/// server-side (we can't trust an open-source binary to make pricing
/// decisions on its own).
///
///   smart        Auto-pick. First-cut work uses the cheap model,
///                creative / agent work uses the premium one. Best
///                everyday balance.
///   high_quality Always use the premium model. Burns credits faster
///                but produces noticeably better B-roll/overlay
///                copywriting.
///   economy      Always use the cheap model. Stretches a monthly
///                allowance further; expect rougher creative output.
struct QualityModePickerRow: View {
    @ObservedObject private var session = RelaySession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: binding) {
                T("Smart (recommended)").tag("smart")
                T("High quality").tag("high_quality")
                T("Economy").tag("economy")
            } label: {
                T("AI quality")
            }
            .pickerStyle(.menu)

            T("Smart auto-routes simple cuts to the cheap model and creative work to the premium one. High quality always uses the premium model (faster credit burn, better creative output). Economy always uses the cheap model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var binding: Binding<String> {
        Binding(
            get: { session.qualityMode },
            set: { newValue in
                Task { await session.setQualityMode(newValue) }
            }
        )
    }
}
