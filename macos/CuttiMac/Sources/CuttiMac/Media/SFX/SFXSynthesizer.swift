import Foundation

/// Pure-Swift DSP generators for the built-in sound-effect library,
/// tuned for **口播 / 访谈 / 播客** editing. Every effect is normalized
/// to a 0.85 peak and stored as 48kHz mono Float32 samples which
/// `SFXRenderer` writes out as a 16-bit WAV.
///
/// None of these pretend to be studio-grade — the goal is that every
/// effect is *recognizable as its category archetype* (e.g. "this
/// sounds like a sub drop", not "this sounds like *that specific*
/// Netflix drop") so editors can slot them in while prototyping and
/// swap for licensed samples later if they care to.
enum SFXSynthesizer {
    static let sampleRate: Double = 48_000
    private static let twoPi = 2.0 * Double.pi

    static func render(_ kind: SFXKind) -> [Float] {
        switch kind {
        case .braaam:       return braaam()
        case .subDrop:      return subDrop()
        case .impactHit:    return impactHit()
        case .riser:        return riser()
        case .whoosh:       return whoosh()
        case .swish:        return swish()
        case .glitch:       return glitch()
        case .tapeStop:     return tapeStop()
        case .softChime:    return softChime()
        case .pluck:        return pluck()
        case .shimmer:      return shimmer()
        case .pop:          return pop()
        case .typewriter:   return typewriter()
        case .tick:         return tick()
        case .notification: return notification()
        case .beep:         return beep()
        case .vinylCrackle: return vinylCrackle()
        case .heartbeat:    return heartbeat()
        }
    }

    // MARK: - Primitives

    private static func sampleCount(_ seconds: Double) -> Int {
        Int(seconds * sampleRate)
    }

    /// Attack-hold-exponential-release envelope.
    private static func adsrEnvelope(n: Int, attack: Double, release: Double) -> [Float] {
        let atk = max(1, Int(attack * sampleRate))
        let rel = max(1, Int(release * sampleRate))
        let sustainEnd = max(atk, n - rel)
        var env = [Float](repeating: 0, count: n)
        for i in 0..<n {
            if i < atk {
                env[i] = Float(Double(i) / Double(atk))
            } else if i < sustainEnd {
                env[i] = 1.0
            } else {
                let t = Double(i - sustainEnd) / Double(max(1, n - sustainEnd))
                env[i] = Float(exp(-5.0 * t))
            }
        }
        return env
    }

    /// Seeded xorshift PRNG so the cache key stays stable.
    private struct SeededNoise {
        var state: UInt32
        init(seed: UInt32) { state = seed == 0 ? 0xDEADBEEF : seed }
        mutating func next() -> Float {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return Float(Int32(bitPattern: state)) / Float(Int32.max)
        }
    }

    private static func lowPass(_ samples: [Float], cutoffHz: Double) -> [Float] {
        let rc = 1.0 / (twoPi * cutoffHz)
        let dt = 1.0 / sampleRate
        let alpha = Float(dt / (rc + dt))
        var out = [Float](repeating: 0, count: samples.count)
        var prev: Float = 0
        for i in 0..<samples.count {
            prev += alpha * (samples[i] - prev)
            out[i] = prev
        }
        return out
    }

    private static func highPass(_ samples: [Float], cutoffHz: Double) -> [Float] {
        let rc = 1.0 / (twoPi * cutoffHz)
        let dt = 1.0 / sampleRate
        let alpha = Float(rc / (rc + dt))
        var out = [Float](repeating: 0, count: samples.count)
        var prevIn: Float = 0, prevOut: Float = 0
        for i in 0..<samples.count {
            let y = alpha * (prevOut + samples[i] - prevIn)
            out[i] = y
            prevIn = samples[i]
            prevOut = y
        }
        return out
    }

    private static func normalize(_ samples: [Float], target: Float = 0.85) -> [Float] {
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        guard peak > 0 else { return samples }
        let gain = target / peak
        return samples.map { $0 * gain }
    }

    // MARK: - Cinematic

    /// Inception-style "BRAAAM". Low brass hit: fundamental at ~55Hz
    /// with detuned partners and slow-pitched-down harmonics. Long
    /// release tail for that "dread hanging in the air" feel.
    private static func braaam() -> [Float] {
        let n = sampleCount(2.2)
        let fundamentals = [55.0, 55.0 * 1.003, 82.5] // slight detune + perfect-fifth
        var out = [Float](repeating: 0, count: n)
        for f0 in fundamentals {
            var phase: Double = 0
            for i in 0..<n {
                let t = Double(i) / sampleRate
                // Pitch dips ~3 semitones in the first 0.3s then holds
                let bend = t < 0.3 ? (1.0 - 0.08 * (1.0 - t / 0.3)) : 1.0
                let f = f0 * bend
                phase += twoPi * f / sampleRate
                // Brass = odd + even harmonics, rolling off
                var s = 0.0
                for k in 1...6 {
                    s += sin(phase * Double(k)) / Double(k * k)
                }
                out[i] += Float(s * 0.5)
            }
        }
        let env = adsrEnvelope(n: n, attack: 0.12, release: 1.4)
        for i in 0..<n { out[i] *= env[i] }
        return normalize(out)
    }

    /// Clean sub-bass drop. Sine sweep from 180Hz → 40Hz over 0.8s,
    /// then holds the 40Hz tone with exponential decay. Not punchy
    /// like Vine Boom — more like a sub kick rolled into a topic
    /// change.
    private static func subDrop() -> [Float] {
        let n = sampleCount(1.5)
        var out = [Float](repeating: 0, count: n)
        var phase: Double = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let f = t < 0.8 ? (180.0 * pow(40.0 / 180.0, t / 0.8)) : 40.0
            phase += twoPi * f / sampleRate
            out[i] = Float(sin(phase))
        }
        let env = adsrEnvelope(n: n, attack: 0.02, release: 0.9)
        for i in 0..<n { out[i] *= env[i] }
        return normalize(out)
    }

    /// Cinematic impact — a low thud + broadband "crunch" burst at t=0.
    /// Sits under bold statements or reveals.
    private static func impactHit() -> [Float] {
        let n = sampleCount(0.9)

        // Low thud: 70Hz sine dropping to 45Hz in 100ms
        var thud = [Float](repeating: 0, count: n)
        var phase: Double = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let f = max(45.0, 70.0 - 250.0 * t)
            phase += twoPi * f / sampleRate
            thud[i] = Float(sin(phase))
        }
        let thudEnv = adsrEnvelope(n: n, attack: 0.003, release: 0.7)
        for i in 0..<n { thud[i] *= thudEnv[i] * 0.9 }

        // Crunch: 30ms noise burst low-passed
        var noise = SeededNoise(seed: 0x1AA7)
        let crunchLen = sampleCount(0.03)
        var crunch = [Float](repeating: 0, count: crunchLen)
        for i in 0..<crunchLen {
            crunch[i] = noise.next() * Float(exp(-Double(i) / 60.0))
        }
        let filteredCrunch = lowPass(crunch, cutoffHz: 1500)

        var out = thud
        for i in 0..<filteredCrunch.count { out[i] += filteredCrunch[i] * 0.6 }
        return normalize(out)
    }

    /// Tension riser — white noise with slowly-rising high-pass cutoff
    /// + rising sine tone. Tuned subtler than the MLG version: quieter
    /// top-end so it doesn't drown the speaker.
    private static func riser() -> [Float] {
        let n = sampleCount(2.0)
        var noise = SeededNoise(seed: 0xF15E)
        var raw = [Float](repeating: 0, count: n)
        for i in 0..<n { raw[i] = noise.next() * 0.35 }

        let blockSize = 128
        var noiseOut = [Float](repeating: 0, count: n)
        var hpIn: Float = 0, hpOut: Float = 0
        for blockStart in stride(from: 0, to: n, by: blockSize) {
            let t = Double(blockStart) / Double(n)
            let cutoff = 300.0 + t * 3500.0
            let rc = 1.0 / (twoPi * cutoff)
            let dt = 1.0 / sampleRate
            let alpha = Float(rc / (rc + dt))
            for j in blockStart..<min(blockStart + blockSize, n) {
                let y = alpha * (hpOut + raw[j] - hpIn)
                hpIn = raw[j]; hpOut = y
                noiseOut[j] = y
            }
        }

        // Rising sine — 110Hz to 440Hz (2 octaves, gentler than before)
        var sine = [Float](repeating: 0, count: n)
        var phase: Double = 0
        for i in 0..<n {
            let t = Double(i) / Double(n)
            let f = 110.0 * pow(4.0, t)
            phase += twoPi * f / sampleRate
            sine[i] = Float(sin(phase) * 0.25)
        }

        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = noiseOut[i] + sine[i] }
        for i in 0..<n {
            let t = Double(i) / Double(n)
            out[i] *= Float(t * t)
        }
        return normalize(out)
    }

    // MARK: - Transitions

    /// Clean air whoosh — band-pass swept noise with parabolic
    /// amplitude envelope. No mid-band emphasis that would sound
    /// "laser-y"; meant to cross-fade B-roll without drawing attention.
    private static func whoosh() -> [Float] {
        let n = sampleCount(0.7)
        var noise = SeededNoise(seed: 0x1057)
        var raw = [Float](repeating: 0, count: n)
        for i in 0..<n { raw[i] = noise.next() }

        let blockSize = 64
        var out = [Float](repeating: 0, count: n)
        var hpIn: Float = 0, hpOut: Float = 0, lpPrev: Float = 0
        for blockStart in stride(from: 0, to: n, by: blockSize) {
            let t = Double(blockStart) / Double(n)
            let parabola = 1.0 - pow(2 * t - 1, 2)
            let centerHz = 350.0 + parabola * 2200.0
            let hpRC = 1.0 / (twoPi * (centerHz * 0.5))
            let lpRC = 1.0 / (twoPi * (centerHz * 1.8))
            let dt = 1.0 / sampleRate
            let hpA = Float(hpRC / (hpRC + dt))
            let lpA = Float(dt / (lpRC + dt))
            for j in blockStart..<min(blockStart + blockSize, n) {
                let y = hpA * (hpOut + raw[j] - hpIn)
                hpIn = raw[j]; hpOut = y
                lpPrev += lpA * (y - lpPrev)
                out[j] = lpPrev
            }
        }
        for i in 0..<n {
            let t = Double(i) / Double(n)
            let amp = 1.0 - pow(2 * t - 1, 2)
            out[i] *= Float(amp * 1.6)
        }
        return normalize(out)
    }

    /// Soft quick swish — a much shorter, subtler sibling of whoosh.
    /// Good for quick cut accents where a full whoosh would be too
    /// much.
    private static func swish() -> [Float] {
        let n = sampleCount(0.35)
        var noise = SeededNoise(seed: 0x5415)
        var raw = [Float](repeating: 0, count: n)
        for i in 0..<n { raw[i] = noise.next() }

        // Band-pass centered around 2.5kHz the whole way, amplitude
        // envelope does the heavy lifting
        let hp = highPass(raw, cutoffHz: 1200)
        let bp = lowPass(hp, cutoffHz: 5000)
        var out = bp
        for i in 0..<n {
            let t = Double(i) / Double(n)
            // Quick attack, longer-tail decay
            let amp = t < 0.2
                ? (t / 0.2)
                : exp(-3.0 * (t - 0.2))
            out[i] *= Float(amp)
        }
        return normalize(out, target: 0.7)
    }

    /// Digital glitch — short stuttering burst of bit-crushed noise,
    /// perfect for masking jump cuts in talking-head footage.
    private static func glitch() -> [Float] {
        let n = sampleCount(0.35)
        var noise = SeededNoise(seed: 0xA11C)
        var out = [Float](repeating: 0, count: n)

        // Stutter pattern: 5 ms chunks, each with a random amplitude
        // from a 4-level quantized set. This gives the "hzzt-krt-zzt"
        // feel without real bitcrushing.
        let chunkLen = sampleCount(0.005)
        var i = 0
        while i < n {
            let levelIdx = Int(abs(noise.next()) * 4) % 4
            let levels: [Float] = [0.0, 0.3, 0.6, 0.9]
            let level = levels[levelIdx]
            let end = min(n, i + chunkLen)
            for j in i..<end {
                out[j] = noise.next() * level
            }
            i = end
        }
        let filtered = highPass(out, cutoffHz: 500)
        let env = adsrEnvelope(n: n, attack: 0.002, release: 0.08)
        var result = filtered
        for k in 0..<n { result[k] *= env[k] }
        return normalize(result)
    }

    /// Tape stop — pitch + rate both slow down to zero. Classic
    /// "tape's dragging to a halt" effect on a fixed tone.
    private static func tapeStop() -> [Float] {
        let n = sampleCount(1.0)
        var out = [Float](repeating: 0, count: n)
        var phase: Double = 0
        // Start at 440Hz (A4), slow down cubically to ~40Hz
        for i in 0..<n {
            let t = Double(i) / Double(n)
            let slowdown = pow(1.0 - t, 1.8)
            let f = 40.0 + (440.0 - 40.0) * slowdown
            phase += twoPi * f / sampleRate
            // Subtract even harmonic to give it a "tape-y" hollow tone
            let s = sin(phase) + 0.3 * sin(phase * 2) + 0.15 * sin(phase * 3)
            out[i] = Float(s * 0.45)
        }
        let env = adsrEnvelope(n: n, attack: 0.01, release: 0.3)
        for i in 0..<n { out[i] *= env[i] }
        return normalize(out)
    }

    // MARK: - Highlight stingers

    /// Soft chime — warm bell with multiple harmonics and a long
    /// exponential tail. Lower/mellower than a notification tone.
    /// Use to underline a key quote.
    private static func softChime() -> [Float] {
        let n = sampleCount(1.4)
        let partials: [(freq: Double, amp: Double, release: Double)] = [
            (523.25, 0.55, 1.1),  // C5 fundamental
            (1046.5, 0.30, 0.9),  // octave
            (1568.0, 0.18, 0.7),  // octave + fifth
            (2093.0, 0.10, 0.5),  // two octaves
        ]
        var out = [Float](repeating: 0, count: n)
        for p in partials {
            let env = adsrEnvelope(n: n, attack: 0.004, release: p.release)
            var phase: Double = 0
            for i in 0..<n {
                phase += twoPi * p.freq / sampleRate
                out[i] += Float(sin(phase) * p.amp * Double(env[i]))
            }
        }
        return normalize(out)
    }

    /// Plucked-string stinger using Karplus-Strong (a delay line
    /// seeded with noise, averaging two samples each pass → natural
    /// string decay). Classic "quote callout" sound in podcasts.
    private static func pluck() -> [Float] {
        let n = sampleCount(1.0)
        let freq: Double = 329.63 // E4
        let delayLen = max(1, Int(sampleRate / freq))
        var noise = SeededNoise(seed: 0xD17C)
        var buffer = [Float](repeating: 0, count: delayLen)
        for i in 0..<delayLen { buffer[i] = noise.next() * 0.8 }

        var out = [Float](repeating: 0, count: n)
        var idx = 0
        for i in 0..<n {
            let current = buffer[idx]
            out[i] = current
            let next = (current + buffer[(idx + 1) % delayLen]) * 0.498
            buffer[idx] = next
            idx = (idx + 1) % delayLen
        }
        // Gentle fade
        let env = adsrEnvelope(n: n, attack: 0.002, release: 0.6)
        for i in 0..<n { out[i] *= env[i] }
        return normalize(out)
    }

    /// Shimmer — sparse, high-frequency bell partials with long decay.
    /// Ethereal "sparkle" that works well over text overlays.
    private static func shimmer() -> [Float] {
        let n = sampleCount(1.8)
        let freqs = [2093.0, 2637.0, 3136.0, 3951.0, 4698.0] // C7, E7, G7, B7, D8
        var out = [Float](repeating: 0, count: n)
        for (k, f) in freqs.enumerated() {
            // Stagger onset so it sparkles rather than hits as a chord
            let onset = Double(k) * 0.05
            let partialN = sampleCount(1.8 - onset)
            let envLocal = adsrEnvelope(n: partialN, attack: 0.005, release: max(0.4, 1.4 - Double(k) * 0.15))
            var phase: Double = 0
            let startIdx = sampleCount(onset)
            for i in 0..<partialN {
                phase += twoPi * f / sampleRate
                let j = startIdx + i
                if j < n {
                    out[j] += Float(sin(phase) * 0.22 * Double(envLocal[i]))
                }
            }
        }
        return normalize(out, target: 0.75)
    }

    /// Subtle bubble pop — used as a very small accent, not the main
    /// stinger. Sine sweep with short envelope.
    private static func pop() -> [Float] {
        let n = sampleCount(0.25)
        var out = [Float](repeating: 0, count: n)
        let env = adsrEnvelope(n: n, attack: 0.003, release: 0.2)
        var phase: Double = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let f = 900 - 700 * (t / 0.25)
            phase += twoPi * f / sampleRate
            out[i] = Float(0.7 * sin(phase) * Double(env[i]))
        }
        return normalize(out, target: 0.7)
    }

    // MARK: - UI / captions

    /// Typewriter — 6 random clicks spaced like real typing, plus a
    /// little carriage bell at the end.
    private static func typewriter() -> [Float] {
        let n = sampleCount(1.4)
        var out = [Float](repeating: 0, count: n)
        var noise = SeededNoise(seed: 0x7497)

        let clickTimes = [0.00, 0.18, 0.35, 0.55, 0.78, 1.00]
        for t0 in clickTimes {
            let start = sampleCount(t0)
            let clickLen = sampleCount(0.04)
            for i in 0..<clickLen {
                let decay = exp(-Double(i) / 20.0)
                let s = noise.next() * Float(decay)
                let j = start + i
                if j < n { out[j] += s * 0.6 }
            }
        }
        let bell = { () -> [Float] in
            let bN = sampleCount(0.2)
            let env = adsrEnvelope(n: bN, attack: 0.002, release: 0.18)
            var phase: Double = 0
            var b = [Float](repeating: 0, count: bN)
            for i in 0..<bN {
                phase += twoPi * 2093 / sampleRate
                b[i] = Float(sin(phase) * 0.3 * Double(env[i]))
            }
            return b
        }()
        let bellStart = sampleCount(1.2)
        for i in 0..<bell.count {
            let j = bellStart + i
            if j < n { out[j] += bell[i] }
        }
        return normalize(highPass(out, cutoffHz: 800))
    }

    /// Clock tick-tock. Two short filtered clicks with the classic
    /// "tick" / "tock" timbre (slight pitch difference).
    private static func tick() -> [Float] {
        let n = sampleCount(1.2)
        var out = [Float](repeating: 0, count: n)
        // 6 alternating tick/tock at 0.2s cadence — a classic "countdown"
        // pattern that's useful as a transition or tension builder.
        let hits: [(t: Double, hi: Bool)] = [
            (0.00, true), (0.20, false), (0.40, true),
            (0.60, false), (0.80, true), (1.00, false)
        ]
        var noise = SeededNoise(seed: 0x71C2)
        for hit in hits {
            let start = sampleCount(hit.t)
            let clickLen = sampleCount(0.04)
            for i in 0..<clickLen {
                let decay = exp(-Double(i) / 120.0)
                let s = noise.next() * Float(decay)
                let j = start + i
                if j < n { out[j] += s }
            }
        }
        // "tick" has more high end, "tock" more low — apply by mixing
        // a bandpass version weighted per-hit
        let bp = highPass(out, cutoffHz: 1500)
        let lp = lowPass(out, cutoffHz: 1500)
        var result = [Float](repeating: 0, count: n)
        for (idx, hit) in hits.enumerated() {
            let start = sampleCount(hit.t)
            let clickLen = sampleCount(0.12)
            for i in 0..<clickLen {
                let j = start + i
                if j < n {
                    result[j] += hit.hi ? bp[j] : lp[j]
                }
            }
            _ = idx
        }
        return normalize(result, target: 0.7)
    }

    /// Gentle three-note ascending triad (C major).
    private static func notification() -> [Float] {
        let notes = [523.25, 659.25, 783.99] // C5, E5, G5
        let n = sampleCount(0.8)
        var out = [Float](repeating: 0, count: n)
        for (idx, f) in notes.enumerated() {
            let start = sampleCount(Double(idx) * 0.15)
            let dur = 0.45
            let cnt = sampleCount(dur)
            let env = adsrEnvelope(n: cnt, attack: 0.005, release: 0.35)
            var phase: Double = 0
            for i in 0..<cnt {
                phase += twoPi * f / sampleRate
                let s = sin(phase) + 0.1 * sin(phase * 2)
                let j = start + i
                if j < n { out[j] += Float(s * 0.5 * Double(env[i])) }
            }
        }
        return normalize(out)
    }

    /// Censor beep — 1kHz sine, steady amplitude, short fade at edges.
    /// The TV/radio bleep.
    private static func beep() -> [Float] {
        let n = sampleCount(0.6)
        var out = [Float](repeating: 0, count: n)
        var phase: Double = 0
        for i in 0..<n {
            phase += twoPi * 1000.0 / sampleRate
            out[i] = Float(sin(phase))
        }
        // Short fade in/out so we don't click
        let fade = sampleCount(0.008)
        for i in 0..<fade {
            let amp = Float(Double(i) / Double(fade))
            out[i] *= amp
            out[n - 1 - i] *= amp
        }
        return normalize(out, target: 0.6)
    }

    // MARK: - Atmosphere

    /// Vinyl crackle — low-amplitude noise bed with sparse high-freq
    /// "ticks" modeling dust hits on a record. Loopable background
    /// texture for retro / nostalgic segments.
    private static func vinylCrackle() -> [Float] {
        let n = sampleCount(2.5)
        var noise = SeededNoise(seed: 0x7111)
        var out = [Float](repeating: 0, count: n)
        // Continuous quiet noise floor
        for i in 0..<n {
            out[i] = noise.next() * 0.15
        }
        // Sparse "pops" — Poisson-ish spacing
        var pos = 0
        while pos < n {
            // gap 20–200ms
            let gap = 0.02 + 0.18 * abs(Double(noise.next()))
            pos += sampleCount(gap)
            if pos >= n { break }
            let popLen = sampleCount(0.004)
            let amp = 0.4 + 0.5 * abs(noise.next())
            for i in 0..<popLen {
                let decay = exp(-Double(i) / 20.0)
                let j = pos + i
                if j < n {
                    out[j] += noise.next() * Float(amp) * Float(decay)
                }
            }
        }
        return normalize(highPass(out, cutoffHz: 400), target: 0.65)
    }

    /// Heartbeat — pair of low "lub-dub" thumps at a tense tempo (~72
    /// BPM). 60Hz sine + short noise transient per hit.
    private static func heartbeat() -> [Float] {
        let n = sampleCount(2.0)
        var out = [Float](repeating: 0, count: n)
        // Two "lub-dub" pairs: hits at (0.10, 0.25) and (0.95, 1.10).
        // The "lub" (S1) is slightly longer/lower than the "dub" (S2).
        let hits: [(t: Double, f: Double, len: Double)] = [
            (0.10, 58.0, 0.16),
            (0.25, 65.0, 0.12),
            (0.95, 58.0, 0.16),
            (1.10, 65.0, 0.12),
        ]
        for hit in hits {
            let start = sampleCount(hit.t)
            let cnt = sampleCount(hit.len)
            let env = adsrEnvelope(n: cnt, attack: 0.005, release: hit.len * 0.8)
            var phase: Double = 0
            for i in 0..<cnt {
                phase += twoPi * hit.f / sampleRate
                let s = sin(phase)
                let j = start + i
                if j < n { out[j] += Float(s * 0.9 * Double(env[i])) }
            }
        }
        return normalize(out)
    }
}
