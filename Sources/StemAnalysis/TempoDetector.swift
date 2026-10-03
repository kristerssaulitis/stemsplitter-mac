import Accelerate
import Foundation

public struct TempoResult: Codable, Equatable, Sendable {
    public var bpm: Double
    /// Beat times in seconds (fixed grid at `bpm`).
    public var beats: [Double]
    /// Normalized autocorrelation peak, 0...1.
    public var confidence: Double
}

/// Onset envelope (spectral flux) → autocorrelation tempogram with a log-normal prior at 120 BPM
/// (librosa-style) → comb refinement to 0.05 BPM → best-phase fixed grid.
/// ponytail: fixed grid assumes steady tempo. Add a DP beat tracker if live/rubato input matters.
public enum TempoDetector {
    static let fftSize = 1024
    static let hop = 256

    /// Returns nil when there is no steady beat (a cappella, ambient, silence).
    public static func detect(_ x: [Float], sampleRate: Double = AudioLoader.sampleRate) -> TempoResult? {
        let fps = sampleRate / Double(hop)
        let env = onsetEnvelope(x)
        guard env.count > Int(fps * 4) else { return nil }
        let mean = env.reduce(0, +) / Float(env.count)
        // Absolute strength gate: steady tones leak tiny periodic flux (p99 ≈ 20); real hits are
        // > 300 (vocal phrases) to > 1000 (drums). Measured on click tracks and a split house track.
        let p99 = env.sorted()[env.count * 99 / 100]
        guard mean > 1e-4, p99 > 100 else { return nil }

        let minLag = Int(60 * fps / 200), maxLag = Int(60 * fps / 60) + 1
        var ac = [Float](repeating: 0, count: maxLag + 2)
        let n = env.count
        // Zero-mean, or a noisy-but-flat envelope autocorrelates at every lag.
        let centered = env.map { $0 - mean }
        centered.withUnsafeBufferPointer { e in
            for lag in 0..<ac.count where lag < n {
                var s: Float = 0
                vDSP_dotpr(e.baseAddress!, 1, e.baseAddress! + lag, 1, &s, vDSP_Length(n - lag))
                ac[lag] = s / Float(n - lag)
            }
        }
        guard ac[0] > 0 else { return nil }
        var best = minLag, bestScore = -Float.infinity
        for lag in minLag...maxLag {
            let bpm = 60 * fps / Double(lag)
            let prior = Float(exp(-0.5 * pow(log2(bpm / 120), 2)))
            let score = ac[lag] * prior
            if score > bestScore { bestScore = score; best = lag }
        }
        let confidence = Double(ac[best] / ac[0])
        guard confidence > 0.1 else { return nil }

        // Parabolic peak, then comb refinement over the whole envelope.
        var lag = Double(best)
        if best > minLag && best < maxLag {
            let a = ac[best - 1], b = ac[best], c = ac[best + 1]
            let d = a - 2 * b + c
            if d != 0 { lag += Double(0.5 * (a - c) / d) }
        }
        var bpm = 60 * fps / lag
        var bestPhase = 0.0
        var bestComb = -Double.infinity
        for cand in stride(from: bpm - 1.5, through: bpm + 1.5, by: 0.05) {
            let (phase, score) = bestPhaseScore(env, period: 60 * fps / cand)
            if score > bestComb { bestComb = score; bpm = cand; bestPhase = phase }
        }
        // Snap to a whole BPM when it's within the measurement noise: most music is produced on one.
        if abs(bpm - bpm.rounded()) < 0.15 {
            let snapped = bpm.rounded()
            bestPhase = bestPhaseScore(env, period: 60 * fps / snapped).phase
            bpm = snapped
        }
        let period = 60 * fps / bpm
        let duration = Double(x.count) / sampleRate
        var beats: [Double] = []
        var t = bestPhase / fps
        while t < duration {
            beats.append(t)
            t += period / fps
        }
        return TempoResult(bpm: bpm, beats: beats, confidence: min(1, confidence))
    }

    static func bestPhaseScore(_ env: [Float], period: Double) -> (phase: Double, score: Double) {
        var best = (0.0, -Double.infinity)
        let steps = max(1, Int(period.rounded()))
        for p in 0..<steps {
            var s = 0.0, k = 0
            var pos = Double(p)
            while Int(pos) < env.count {
                s += Double(env[Int(pos)])
                k += 1
                pos += period
            }
            let score = s / Double(max(k, 1))
            if score > best.1 { best = (Double(p), score) }
        }
        return best
    }

    /// Half-wave rectified log-spectral flux, locally mean-removed. One value per hop.
    static func onsetEnvelope(_ x: [Float]) -> [Float] {
        let stft = MagnitudeSTFT(size: fftSize, hop: hop)
        let bins = stft.bins
        var prev = [Float](repeating: 0, count: bins)
        var cur = [Float](repeating: 0, count: bins)
        var env = [Float](repeating: 0, count: stft.frameCount(x.count))
        stft.forEachFrame(x) { f, mag in
            var flux: Float = 0
            for k in 0..<bins {
                cur[k] = log1p(1000 * mag[k])
                let d = cur[k] - prev[k]
                if d > 0 && f > 0 { flux += d }
            }
            env[f] = flux
            swap(&prev, &cur)
        }
        // Subtract a ~0.5 s moving average so slow loudness changes don't read as beats.
        let w = 43
        var out = [Float](repeating: 0, count: env.count)
        var acc: Float = 0
        for i in 0..<env.count {
            acc += env[i]
            if i >= w { acc -= env[i - w] }
            let avg = acc / Float(min(i + 1, w))
            out[i] = max(0, env[i] - avg)
        }
        return out
    }
}
