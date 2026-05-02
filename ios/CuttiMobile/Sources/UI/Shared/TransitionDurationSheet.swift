import SwiftUI

/// Compact sheet opened by tapping the transition indicator
/// between two chips. Hosts a duration slider (0.1–2.0s) and a
/// destructive "取消转场" action. Kept deliberately small — users
/// generally just want to nudge the fade longer/shorter or turn
/// it off, not compose a complex transition stack.
struct TransitionDurationSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss
    let segmentID: UUID

    private var duration: Double {
        get { document.transitions[segmentID] ?? 0.5 }
        nonmutating set {
            document.setTransitionDuration(for: segmentID, seconds: newValue)
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("转场时长")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button("完成") { dismiss() }
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("淡入淡出")
                    Spacer()
                    Text(String(format: "%.2fs", duration))
                        .font(.system(.body, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.85))

                Slider(
                    value: Binding(
                        get: { duration },
                        set: { document.setTransitionDuration(for: segmentID, seconds: $0) }
                    ),
                    in: 0.1...2.0,
                    onEditingChanged: { document.interactiveEdit($0) }
                )
                .tint(Color(red: 0.95, green: 0.25, blue: 0.35))
            }

            Button(role: .destructive) {
                document.setTransitionDuration(for: segmentID, seconds: 0)
                dismiss()
            } label: {
                Label("取消转场", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Color.black.ignoresSafeArea())
    }
}
