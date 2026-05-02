import SwiftUI
import AVFoundation

/// Simple microphone recorder. Writes an .m4a (AAC) file to the
/// caller-provided URL and reports the duration on stop. The sheet
/// asks for microphone permission on first use and shows a live
/// elapsed timer while recording.
@MainActor
final class VoiceRecorderController: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case recording
        case finished(URL, Double)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var elapsed: Double = 0
    /// Smoothed 0…1 input level, from AVAudioRecorder metering. Used
    /// to pulse the record-button ring as a vitality signal.
    @Published var level: Double = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startDate: Date?

    func start(destination: URL) {
        state = .preparing
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.state = .failed("需要麦克风权限才能录音")
                    return
                }
                self.beginRecording(at: destination)
            }
        }
    }

    private func beginRecording(at url: URL) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            rec.prepareToRecord()
            rec.record()
            self.recorder = rec
            self.startDate = Date()
            self.state = .recording
            self.elapsed = 0
            self.level = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let s = self.startDate, let r = self.recorder else { return }
                    self.elapsed = Date().timeIntervalSince(s)
                    r.updateMeters()
                    // averagePower is in dBFS (-160 … 0). Normalize to
                    // 0…1 with -50 dB floor so the ring reads "full"
                    // at comfortable speaking volume.
                    let db = r.averagePower(forChannel: 0)
                    let norm = max(0, min(1, (Double(db) + 50) / 50))
                    // light smoothing to avoid jitter
                    self.level = self.level * 0.6 + norm * 0.4
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        guard let rec = recorder else { return }
        let url = rec.url
        let dur = rec.currentTime
        rec.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        state = .finished(url, dur)
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        recorder?.stop()
        if let u = recorder?.url { try? FileManager.default.removeItem(at: u) }
        recorder = nil
        state = .idle
    }
}

struct VoiceRecorderSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ctl = VoiceRecorderController()
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("录音").font(.headline).foregroundStyle(.white)

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 4)
                    .frame(width: 140, height: 140)
                // Live input-level ring — grows with mic volume while
                // recording, stays hidden when idle.
                Circle()
                    .stroke(Color.red.opacity(0.55), lineWidth: 6)
                    .frame(
                        width: 140 + CGFloat(ctl.level) * 40,
                        height: 140 + CGFloat(ctl.level) * 40
                    )
                    .opacity(isRecording ? 1 : 0)
                    .animation(.easeOut(duration: 0.08), value: ctl.level)
                Circle()
                    .fill(isRecording ? Color.red : Color.red.opacity(0.85))
                    .frame(width: isRecording ? 80 : 100,
                           height: isRecording ? 80 : 100)
                    .animation(.easeInOut(duration: 0.2), value: isRecording)
            }

            Text(timeString(ctl.elapsed))
                .font(.system(size: 34, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)

            HStack(spacing: 30) {
                Button(role: .cancel) {
                    ctl.cancel()
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 80, height: 44)
                }

                Button {
                    if isRecording {
                        ctl.stop()
                    } else {
                        let url = tempURL()
                        // Pause the preview before taking the mic — the
                        // .playAndRecord category lets both run, but
                        // the user rarely wants video audio bleeding
                        // into their voiceover take.
                        document.player.pause()
                        ctl.start(destination: url)
                    }
                } label: {
                    Text(isRecording ? "完成" : "开始录制")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 120, height: 44)
                        .background(Capsule().fill(Color.red))
                }
            }

            if let errorText {
                Text(L(errorText)).font(.system(size: 12)).foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color.black.ignoresSafeArea())
        .onChange(of: ctl.state) { _, s in
            switch s {
            case .finished(let url, _):
                Task {
                    do {
                        try await document.importAudio(at: url)
                        try? FileManager.default.removeItem(at: url)
                        dismiss()
                    } catch {
                        errorText = "保存失败：\(error.localizedDescription)"
                    }
                }
            case .failed(let msg):
                errorText = msg
            default: break
            }
        }
    }

    private var isRecording: Bool {
        if case .recording = ctl.state { return true }
        return false
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "cutti-rec-\(UUID().uuidString).m4a")
    }

    private func timeString(_ t: Double) -> String {
        let s = Int(t)
        let ms = Int((t - Double(s)) * 10)
        return String(format: "%02d:%02d.%d", s / 60, s % 60, ms)
    }
}
