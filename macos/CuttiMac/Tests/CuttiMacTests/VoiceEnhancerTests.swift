import XCTest
import AVFoundation
import CuttiKit
@testable import CuttiMac

final class VoiceEnhancerTests: XCTestCase {

    /// Generate a 1-second 440 Hz sine tone WAV file at the given URL so
    /// tests don't need a fixture binary checked in.
    private func writeSineToneWAV(at url: URL, seconds: Double = 1.0) throws {
        let sampleRate: Double = 44_100
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "test", code: 1)
        }
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "test", code: 2)
        }
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            channel[i] = sinf(Float(i) * 2 * .pi * 440 / Float(sampleRate)) * 0.3
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func test_settings_disabledIsDisabled() {
        XCTAssertFalse(VoiceEnhancer.Settings.disabled.enabled)
        XCTAssertTrue(VoiceEnhancer.Settings.defaultOn.enabled)
    }

    func test_process_createsOutputFile_withComparableDuration() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-enhancer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inputURL = tmp.appendingPathComponent("in.wav")
        let outputURL = tmp.appendingPathComponent("out.wav")
        try writeSineToneWAV(at: inputURL, seconds: 1.0)

        let result = try VoiceEnhancer.process(
            sourceURL: inputURL,
            destinationURL: outputURL,
            settings: .defaultOn
        )
        XCTAssertEqual(result, outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let outFile = try AVAudioFile(forReading: outputURL)
        // Output length should closely match input (within one buffer tick).
        XCTAssertGreaterThan(outFile.length, 40_000)
        XCTAssertLessThanOrEqual(outFile.length, 44_100 + 4_096)
    }

    func test_process_throwsOnMissingSource() {
        let tmp = FileManager.default.temporaryDirectory
        let missing = tmp.appendingPathComponent("nope-\(UUID().uuidString).wav")
        let out = tmp.appendingPathComponent("out-\(UUID().uuidString).wav")
        XCTAssertThrowsError(try VoiceEnhancer.process(
            sourceURL: missing,
            destinationURL: out,
            settings: .defaultOn
        ))
    }
}
