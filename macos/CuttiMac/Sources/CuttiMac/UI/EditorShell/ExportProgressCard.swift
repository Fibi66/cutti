import SwiftUI

/// Floating progress card shown while an export is running. Surfaces the
/// percent complete, a friendly remaining-time estimate, and a Cancel
/// button that forwards into AVAssetExportSession.cancelExport().
struct ExportProgressCard: View {
    let progress: AIVideoExporter.ExportProgress?
    let isCancelling: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .foregroundStyle(.tint)
                T("Exporting video")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Text(isCancelling ? L("Cancelling…") : L("Cancel"))
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(isCancelling)
            }

            ProgressView(value: max(0, min(1, progress?.fractionComplete ?? 0)))
                .progressViewStyle(.linear)

            HStack(spacing: 12) {
                Text(detailText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let eta = progress?.estimatedSecondsRemaining {
                    Text(String(format: L("≈ %@ left"), formatDuration(eta)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
    }

    private var detailText: String {
        if isCancelling { return "Cancelling…" }
        guard let progress else { return "Preparing…" }
        let pct = Int(max(0, min(1, progress.fractionComplete)) * 100)
        if !progress.detail.isEmpty {
            return "\(progress.detail) · \(pct)%"
        }
        return "\(pct)%"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let rem = s % 60
        if m < 60 { return rem == 0 ? "\(m)m" : "\(m)m \(rem)s" }
        let h = m / 60
        let mr = m % 60
        return mr == 0 ? "\(h)h" : "\(h)h \(mr)m"
    }
}
