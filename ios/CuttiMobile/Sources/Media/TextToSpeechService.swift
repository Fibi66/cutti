import Foundation
import AVFoundation

/// Renders text to a `.caf` audio file via `AVSpeechSynthesizer`'s
/// offline write path. Used by the AI 工具箱 "文本转语音" tile to add
/// a synthesized narration onto the timeline as if it were an
/// imported voice-over file. No relay/LLM dependency — Apple's
/// on-device TTS handles it.
enum TextToSpeechService {

    enum TTSError: LocalizedError {
        case synthesisFailed
        case noAudio
        var errorDescription: String? {
            switch self {
            case .synthesisFailed: return "合成失败"
            case .noAudio:         return "没有音频可写出"
            }
        }
    }

    /// Synthesize `text` with the given voice (or system default if
    /// nil) and return a temporary URL to the resulting audio file.
    /// Caller is responsible for moving / deleting the file.
    @MainActor
    static func synthesize(
        text: String,
        voiceIdentifier: String? = nil,
        rate: Float = AVSpeechUtteranceDefaultSpeechRate,
        pitch: Float = 1.0
    ) async throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TTSError.noAudio }

        let utterance = AVSpeechUtterance(string: trimmed)
        if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = v
        } else {
            // Match the device's preferred locale; falls through to
            // en-US if no localized voice is installed.
            let lang = AVSpeechSynthesisVoice.currentLanguageCode()
            utterance.voice = AVSpeechSynthesisVoice(language: lang)
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = rate
        utterance.pitchMultiplier = pitch

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-\(UUID().uuidString).caf")

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let synth = AVSpeechSynthesizer()
            var writer: AVAudioFile?
            var didFinish = false
            // The write callback fires for each PCM chunk; the final
            // call delivers an empty buffer signalling completion.
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if !didFinish {
                        didFinish = true
                        if writer != nil {
                            cont.resume(returning: outURL)
                        } else {
                            cont.resume(throwing: TTSError.synthesisFailed)
                        }
                    }
                    return
                }
                if writer == nil {
                    do {
                        writer = try AVAudioFile(
                            forWriting: outURL,
                            settings: pcm.format.settings,
                            commonFormat: pcm.format.commonFormat,
                            interleaved: pcm.format.isInterleaved
                        )
                    } catch {
                        if !didFinish {
                            didFinish = true
                            cont.resume(throwing: error)
                        }
                        return
                    }
                }
                do {
                    try writer?.write(from: pcm)
                } catch {
                    if !didFinish {
                        didFinish = true
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Voices available on this device, sorted by language then name.
    /// Used by the picker in `TextToSpeechSheet`.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { a, b in
            if a.language != b.language { return a.language < b.language }
            return a.name < b.name
        }
    }
}
