import Foundation

public struct Chord: Codable, Equatable, Sendable {
    public enum Quality: String, Codable, CaseIterable, Sendable {
        case major = "", minor = "m", seventh = "7", major7 = "maj7", minor7 = "m7", dim = "dim", sus2 = "sus2", sus4 = "sus4"

        var intervals: [Int] {
            switch self {
            case .major: [0, 4, 7]
            case .minor: [0, 3, 7]
            case .seventh: [0, 4, 7, 10]
            case .major7: [0, 4, 7, 11]
            case .minor7: [0, 3, 7, 10]
            case .dim: [0, 3, 6]
            case .sus2: [0, 2, 7]
            case .sus4: [0, 5, 7]
            }
        }
    }

    public var root: Int
    public var quality: Quality

    public init(root: Int, quality: Quality) {
        self.root = ((root % 12) + 12) % 12
        self.quality = quality
    }

    public var name: String { PitchClass.name(root) + quality.rawValue }
    public func transposed(_ semitones: Int) -> Chord { Chord(root: root + semitones, quality: quality) }
}

public struct ChordSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    /// nil = no chord (silence / drums only).
    public var chord: Chord?
    /// Mean template similarity over the segment, 0...1. UI dims < 0.6.
    public var confidence: Double
}

/// Beat-synchronous chroma → cosine match against 96 chord templates + "no chord" → Viterbi smoothing.
public enum ChordTracker {
    static let templates: [(Chord, [Float])] = {
        var t: [(Chord, [Float])] = []
        for q in Chord.Quality.allCases {
            for root in 0..<12 {
                var v = [Float](repeating: 0, count: 12)
                for i in q.intervals { v[(root + i) % 12] = 1 }
                let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
                t.append((Chord(root: root, quality: q), v.map { $0 / norm }))
            }
        }
        return t
    }()

    /// `beats`: beat times (seconds). Empty → fixed 0.5 s frames.
    /// `energy`: per-chroma-frame RMS; frames under the threshold become "no chord".
    public static func track(chroma: [[Float]], energy: [Float], frameDuration: Double, beats: [Double]) -> [ChordSegment] {
        guard !chroma.isEmpty else { return [] }
        let total = Double(chroma.count) * frameDuration
        var bounds = beats.filter { $0 < total }
        if bounds.count < 2 { bounds = Array(stride(from: 0, to: total, by: 0.5)) }
        if bounds.first! > 0 { bounds.insert(0, at: 0) }
        bounds.append(total)

        let peakEnergy = energy.max() ?? 0
        // Observation per beat: averaged chroma + silence flag.
        var obs: [([Float], Bool)] = []
        for i in 0..<(bounds.count - 1) {
            let a = Int(bounds[i] / frameDuration), b = max(a + 1, Int(bounds[i + 1] / frameDuration))
            var c = [Float](repeating: 0, count: 12)
            var e: Float = 0
            for f in a..<min(b, chroma.count) {
                for k in 0..<12 { c[k] += chroma[f][k] }
                if f < energy.count { e = max(e, energy[f]) }
            }
            let norm = sqrt(c.reduce(0) { $0 + $1 * $1 })
            obs.append((norm > 0 ? c.map { $0 / norm } : c, norm == 0 || e < peakEnergy * 0.05))
        }

        // States: templates + no-chord (last). Emission = sharpened similarity.
        let S = templates.count + 1
        let beta: Float = 30
        func emission(_ o: ([Float], Bool)) -> [Float] {
            var e = [Float](repeating: 0, count: S)
            for (s, (chord, tpl)) in templates.enumerated() {
                var sim: Float = 0
                for k in 0..<12 { sim += o.0[k] * tpl[k] }
                let bias: Float = chord.quality.intervals.count == 3 && (chord.quality == .major || chord.quality == .minor) ? 0 : -0.04
                e[s] = beta * (sim + bias)
            }
            e[S - 1] = o.1 ? beta : beta * 0.45
            return e
        }
        // Switching costs log(S-1) ≈ 4.6 nats; at beta 30 a chord needs ~0.08 better similarity
        // over one beat (or 0.04 over two) to win. Enough to stop flicker, not to swallow 2-beat chords.
        let stay: Float = log(0.5), move: Float = log(0.5 / Float(S - 1))
        var score = emission(obs[0])
        var back = [[Int]]()
        for t in 1..<obs.count {
            let em = emission(obs[t])
            let bestPrev = score.indices.max { score[$0] < score[$1] }!
            var next = [Float](repeating: 0, count: S)
            var ptr = [Int](repeating: 0, count: S)
            for s in 0..<S {
                let viaStay = score[s] + stay, viaMove = score[bestPrev] + move
                if viaStay >= viaMove { next[s] = viaStay + em[s]; ptr[s] = s } else { next[s] = viaMove + em[s]; ptr[s] = bestPrev }
            }
            back.append(ptr)
            score = next
        }
        var path = [Int](repeating: 0, count: obs.count)
        path[obs.count - 1] = score.indices.max { score[$0] < score[$1] }!
        for t in stride(from: obs.count - 1, to: 0, by: -1) { path[t - 1] = back[t - 1][path[t]] }

        var segments: [ChordSegment] = []
        for t in 0..<obs.count {
            let s = path[t]
            let chord: Chord? = s == S - 1 ? nil : templates[s].0
            var sim: Float = 0
            if s < S - 1 { for k in 0..<12 { sim += obs[t].0[k] * templates[s].1[k] } }
            if let last = segments.last, last.chord == chord {
                let n = (last.end - last.start)
                let d = bounds[t + 1] - bounds[t]
                segments[segments.count - 1].confidence = (last.confidence * n + Double(sim) * d) / (n + d)
                segments[segments.count - 1].end = bounds[t + 1]
            } else {
                segments.append(ChordSegment(start: bounds[t], end: bounds[t + 1], chord: chord, confidence: chord == nil ? 1 : Double(sim)))
            }
        }
        return segments
    }
}
