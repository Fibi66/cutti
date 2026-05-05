import AVFoundation
import Combine
import Foundation
import CuttiKit

/// Drives the microphone → speech-to-text flow for the AI chat composer.
///
/// Start recording on user click, stop to finalize, then transcribe
/// the captured audio via the app's existing `SpeechTranscriptionService`
/// (local Qwen3-ASR when installed, Apple Speech otherwise — same
/// backend selection used everywhere else). The transcribed text is
/// surfaced to the UI, which drops it into the chat composer so the
/// user can review/edit before hitting send.
@MainActor
final class ChatVoiceInputController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    @Published private(set) var phase: Phase = .idle
    /// Monotonically increasing input-meter level (0...1). Re-published
    /// at ~10 Hz while recording so the button can pulse with voice.
    @Published private(set) var level: Double = 0
    /// Non-fatal error surfaced to the UI (e.g. permission denied).
    /// Cleared the next time the user tries to record.
    @Published private(set) var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var recordingURL: URL?
    private let transcriptionService: SpeechTranscriptionService

    /// Reject recordings shorter than this — most of those are accidental
    /// clicks and transcribing silence just confuses the user.
    private let minimumRecordingSeconds: TimeInterval = 0.35

    init(transcriptionService: SpeechTranscriptionService = SpeechTranscriptionService()) {
        self.transcriptionService = transcriptionService
        super.init()
    }

    var isBusy: Bool { phase != .idle }

    /// Called by the UI when the mic button is clicked. Toggles between
    /// start-recording and stop-and-transcribe.
    ///
    /// - Parameter onTranscript: invoked on the main actor with the final
    ///   transcript once the speech model finishes. The view typically appends
    ///   this to the composer's `inputText`.
    func toggle(onTranscript: @escaping @MainActor (String) -> Void) {
        switch phase {
        case .idle:
            Task { await startRecording() }
        case .recording:
            Task { await stopAndTranscribe(onTranscript: onTranscript) }
        case .transcribing:
            // Ignore clicks while the speech model is still working — the spinner
            // in the UI tells the user to wait.
            break
        }
    }

    /// Push-to-talk entry point. No-op if already recording or transcribing
    /// so repeated key-down events (while the user physically holds Fn)
    /// don't restart the recorder.
    func pressToTalkBegin() {
        guard phase == .idle else { return }
        Task { await startRecording() }
    }

    /// Push-to-talk release. Only finalizes if we're actually recording;
    /// stray key-up events are harmless.
    func pressToTalkEnd(onTranscript: @escaping @MainActor (String) -> Void) {
        guard phase == .recording else { return }
        Task { await stopAndTranscribe(onTranscript: onTranscript) }
    }

    /// Best-effort cancel used when the panel disappears mid-recording.
    func cancel() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        phase = .idle
        level = 0
    }

    // MARK: - Record

    private func startRecording() async {
        errorMessage = nil

        let granted = await requestMicrophonePermission()
        guard granted else {
            errorMessage = L("Microphone access denied. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
            return
        }

        do {
            let url = Self.makeTempRecordingURL()
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                throw NSError(
                    domain: "ChatVoiceInput",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to start audio recorder"]
                )
            }
            self.recorder = recorder
            self.recordingURL = url
            self.phase = .recording
            self.level = 0
            self.startMeterTimer()
        } catch {
            errorMessage = L("Could not start recording: %@", error.localizedDescription)
            phase = .idle
        }
    }

    private func stopAndTranscribe(onTranscript: @escaping @MainActor (String) -> Void) async {
        guard let recorder = recorder, let url = recordingURL else {
            phase = .idle
            return
        }

        let duration = recorder.currentTime
        meterTimer?.invalidate()
        meterTimer = nil
        recorder.stop()
        self.recorder = nil
        self.recordingURL = nil
        level = 0

        guard duration >= minimumRecordingSeconds else {
            try? FileManager.default.removeItem(at: url)
            phase = .idle
            return
        }

        phase = .transcribing
        let service = transcriptionService

        do {
            let result = try await service.transcribe(url: url)
            let raw = Self.joinTranscript(result.displaySegments)
            let cleaned = TranscriptCleaner.stripFillers(raw)
            try? FileManager.default.removeItem(at: url)

            if cleaned.isEmpty {
                errorMessage = L("Didn't catch anything — try speaking a bit louder.")
            } else {
                onTranscript(cleaned)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            errorMessage = L("Transcription failed: %@", error.localizedDescription)
        }
        phase = .idle
    }

    // MARK: - Helpers

    private func startMeterTimer() {
        meterTimer?.invalidate()
        // ~10 Hz is enough for a pulsing indicator without burning CPU.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                // -60 dB (silence) → 0, 0 dB (clipping) → 1.
                let db = Double(recorder.averagePower(forChannel: 0))
                let normalized = max(0, min(1, (db + 60) / 60))
                self.level = normalized
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            return false
        }
    }

    private static func makeTempRecordingURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuttiVoiceInput", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("input-\(UUID().uuidString).m4a")
    }

    private static func joinTranscript(_ segments: [TranscriptSegment]) -> String {
        let pieces = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard var joined = pieces.first else { return "" }
        for piece in pieces.dropFirst() {
            if let prev = joined.last, let next = piece.first,
               isCJK(prev) && isCJK(next) {
                joined += piece
            } else {
                joined += " " + piece
            }
        }
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCJK(_ char: Character) -> Bool {
        char.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }
}

extension ChatVoiceInputController: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.errorMessage = L("Recording error: %@", error?.localizedDescription ?? "unknown")
            self?.phase = .idle
        }
    }
}
