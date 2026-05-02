import SwiftUI

/// Modal sheet for the "generate an image out of thin air" flow. The
/// user types a prompt, picks a size, and the caller wires
/// `onGenerate` to `MediaCoreViewModel.generateAIImageToLibrary(...)`.
/// We intentionally don't track the in-flight / result state inside
/// this view — the view-model already owns the `importingFiles` queue
/// and banner messages that light up the media browser, so this sheet
/// is a fire-and-forget dispatcher.
struct ImageGenerationSheet: View {
    let initialPrompt: String
    let onGenerate: (String) -> Void
    let onCancel: () -> Void

    @State private var prompt: String = ""
    @State private var size: ImageGenerationSize = .landscape
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(EditorShellStyle.accentSolid)
                T("Generate AI image")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            T("The image will be added to your Media Browser. Drag it onto the timeline from there.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(L("Describe the image…"), text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
                .font(.system(size: 13))
                .focused($promptFocused)

            Picker(selection: $size) {
                ForEach(ImageGenerationSize.allCases, id: \.self) { s in
                    Text(s.label).tag(s)
                }
            } label: { T("Size") }
            .pickerStyle(.segmented)

            HStack {
                Spacer()
                Button(action: onCancel) { T("Cancel") }
                    .keyboardShortcut(.cancelAction)
                Button {
                    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onGenerate(trimmed)
                } label: {
                    Label { T("Generate") } icon: { Image(systemName: "wand.and.stars") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            prompt = initialPrompt
            // Delay focus one tick so the sheet's TextField exists.
            DispatchQueue.main.async { promptFocused = true }
        }
    }
}
