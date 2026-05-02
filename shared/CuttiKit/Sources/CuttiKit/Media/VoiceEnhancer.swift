import Foundation
import AVFoundation
import Accelerate

/// Offline "Studio Sound"-style voice enhancer built on Apple's native
/// AVAudioEngine + AUAudioUnit chain. Produces a cleaner podcast-ready
/// voice track from a noisy recording by chaining:
///
///   input  →  HighPass (80 Hz)  →  Dynamics (compressor)
///          →  Peak Limiter  →  render-to-file
///
/// The processor runs in AVAudioEngine's manual rendering mode so it can
/// export faster than realtime and without touching the system audio
/// graph. No third-party libraries; works fully offline.
public enum VoiceEnhancer {

    /// User-visible settings; persisted on Project.
    public struct Settings: Codable, Equatable, Sendable {
        /// Whether voice enhancement is enabled at all.
        public var enabled: Bool
        /// 0.0 … 1.0; scales compressor amount and high-pass slope.
        public var strength: Double
        /// Applies a -1 dB peak limiter ceiling to avoid clipping after
        /// compression gain-up.
        public var limit: Bool

        public init(enabled: Bool, strength: Double, limit: Bool) {
            self.enabled = enabled
            self.strength = strength
            self.limit = limit
        }

        public static let disabled = Settings(enabled: false, strength: 0.6, limit: true)
        public static let defaultOn = Settings(enabled: true, strength: 0.6, limit: true)
    }

    public enum EnhanceError: Error, CustomStringConvertible {
        case missingSource
        case openFailed(String)
        case renderFailed(String)

        public var description: String {
            switch self {
            case .missingSource: return "VoiceEnhancer: source file missing"
            case .openFailed(let m): return "VoiceEnhancer: open failed — \(m)"
            case .renderFailed(let m): return "VoiceEnhancer: render failed — \(m)"
            }
        }
    }

    /// Process `sourceURL` with the given settings and write the result to
    /// `destinationURL`. Uses a 4096-frame manual-render pump. Returns
    /// `destinationURL` on success.
    @discardableResult
    public static func process(
        sourceURL: URL,
        destinationURL: URL,
        settings: Settings
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw EnhanceError.missingSource
        }
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw EnhanceError.openFailed(error.localizedDescription)
        }
        let processingFormat = inputFile.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        // High-pass: trims low-frequency rumble (HVAC, plosives).
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.globalGain = 0
        let band = eq.bands[0]
        band.filterType = .highPass
        band.frequency = 80
        band.bandwidth = 1.0
        band.bypass = false

        // Dynamics: broadband compressor to even out speech dynamics.
        let compressor = AVAudioUnitEffect(
            audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_DynamicsProcessor,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
        )

        // Peak limiter: catches short peaks near 0 dBFS.
        let limiter = AVAudioUnitEffect(
            audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
        )

        engine.attach(player)
        engine.attach(eq)
        engine.attach(compressor)
        engine.attach(limiter)
        engine.connect(player, to: eq, format: processingFormat)
        engine.connect(eq, to: compressor, format: processingFormat)
        engine.connect(compressor, to: limiter, format: processingFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: processingFormat)

        let bufferSize: AVAudioFrameCount = 4096
        do {
            try engine.enableManualRenderingMode(
                .offline,
                format: processingFormat,
                maximumFrameCount: bufferSize
            )
            try engine.start()
        } catch {
            throw EnhanceError.openFailed(error.localizedDescription)
        }

        player.scheduleFile(inputFile, at: nil)
        player.play()

        try? FileManager.default.removeItem(at: destinationURL)
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: destinationURL,
                settings: processingFormat.settings,
                commonFormat: processingFormat.commonFormat,
                interleaved: processingFormat.isInterleaved
            )
        } catch {
            engine.stop()
            throw EnhanceError.openFailed(error.localizedDescription)
        }

        guard let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: bufferSize
        ) else {
            engine.stop()
            throw EnhanceError.renderFailed("buffer alloc failed")
        }

        let totalFrames = inputFile.length
        while engine.manualRenderingSampleTime < totalFrames {
            let remaining = totalFrames - engine.manualRenderingSampleTime
            let framesToRender = AVAudioFrameCount(min(AVAudioFramePosition(bufferSize), remaining))
            do {
                let status = try engine.renderOffline(framesToRender, to: renderBuffer)
                switch status {
                case .success:
                    try outputFile.write(from: renderBuffer)
                case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                    // Player scheduled the file synchronously so these shouldn't
                    // persist — but bail out after one tick to avoid hangs.
                    break
                case .error:
                    throw EnhanceError.renderFailed("renderOffline reported error")
                @unknown default:
                    break
                }
            } catch {
                engine.stop()
                throw EnhanceError.renderFailed(error.localizedDescription)
            }
        }

        player.stop()
        engine.stop()
        return destinationURL
    }
}
