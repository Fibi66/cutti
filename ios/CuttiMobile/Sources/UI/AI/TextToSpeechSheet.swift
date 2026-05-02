import SwiftUI
import AVFoundation
import CuttiKit

/// Text → Voice synthesis sheet. User types narration, picks a voice
/// + speed, taps 合成. Result lands on the timeline as a regular
/// voice-over audio segment via the existing `importAudio` path so
/// the rest of the editor (trim / mute / fade / mix) just works.
struct TextToSpeechSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var voiceID: String? = nil
    @State private var rate: Double = Double(AVSpeechUtteranceDefaultSpeechRate)
    @State private var pitch: Double = 1.0
    @State private var isWorking = false
    @State private var errorMessage: String?

    private let voices: [AVSpeechSynthesisVoice] = TextToSpeechService.availableVoices()

    var body: some View {
        NavigationStack {
            Form {
                Section("文本") {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                }

                Section("声音") {
                    Picker("发音人", selection: $voiceID) {
                        Text("系统默认").tag(String?.none)
                        ForEach(voices, id: \.identifier) { v in
                            Text("\(v.name) · \(v.language)")
                                .tag(Optional(v.identifier))
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section(L("语速 (%@)", String(format: "%.2fx", rate / Double(AVSpeechUtteranceDefaultSpeechRate)))) {
                    Slider(
                        value: $rate,
                        in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate)
                    )
                }

                Section(L("音调 (%@)", String(format: "%.1f", pitch))) {
                    Slider(value: $pitch, in: 0.5...2.0)
                }

                if let errorMessage {
                    Section {
                        Text(L(errorMessage))
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("文本转语音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isWorking ? "合成中…" : "合成") {
                        Task { await synthesize() }
                    }
                    .disabled(isWorking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    @MainActor
    private func synthesize() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let url = try await TextToSpeechService.synthesize(
                text: text,
                voiceIdentifier: voiceID,
                rate: Float(rate),
                pitch: Float(pitch)
            )
            // Lands as a voice-over (anchored at playhead, full
            // volume on its own audio track) via the existing path.
            try await document.importAudio(at: url)
            try? FileManager.default.removeItem(at: url)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
