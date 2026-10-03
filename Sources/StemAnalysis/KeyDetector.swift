import Foundation

public enum PitchClass {
    /// ASCII names: safe in filenames.
    public static let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    public static func name(_ pc: Int) -> String { names[((pc % 12) + 12) % 12] }
}

public struct MusicalKey: Codable, Equatable, Sendable {
    public var tonic: Int      // pitch class 0 = C
    public var minor: Bool

    public init(tonic: Int, minor: Bool) {
        self.tonic = ((tonic % 12) + 12) % 12
        self.minor = minor
    }

    /// "Am", "F#", "Eb".
    public var name: String { PitchClass.name(tonic) + (minor ? "m" : "") }
    /// "A minor".
    public var longName: String { PitchClass.name(tonic) + (minor ? " minor" : " major") }

    /// Camelot wheel code, e.g. A minor → "8A", C major → "8B".
    public var camelot: String {
        let majorTonic = minor ? tonic + 3 : tonic  // relative major shares the number
        let number = ((majorTonic * 7) % 12 + 7) % 12 + 1
        return "\(number)\(minor ? "A" : "B")"
    }

    public func transposed(_ semitones: Int) -> MusicalKey { MusicalKey(tonic: tonic + semitones, minor: minor) }
}

public struct KeyResult: Codable, Equatable, Sendable {
    public var key: MusicalKey
    public var runnerUp: MusicalKey
    /// Pearson correlation of the best profile, 0...1.
    public var confidence: Double
}

/// Mean chroma → correlation with Krumhansl-Kessler profiles in 24 rotations.
public enum KeyDetector {
    static let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// nil when there's no tonal center (drums only, noise, silence).
    public static func detect(chroma frames: [[Float]]) -> KeyResult? {
        var mean = [Double](repeating: 0, count: 12)
        var used = 0
        for f in frames where f.contains(where: { $0 > 0 }) {
            for i in 0..<12 { mean[i] += Double(f[i]) }
            used += 1
        }
        guard used > 0 else { return nil }
        let spread = mean.max()! / max(mean.min()!, 1e-9)
        guard spread > 1.15 else { return nil }  // flat chroma = no pitch content

        var scored: [(MusicalKey, Double)] = []
        for tonic in 0..<12 {
            for isMinor in [false, true] {
                let profile = isMinor ? minor : major
                let rotated = (0..<12).map { profile[(($0 - tonic) % 12 + 12) % 12] }
                scored.append((MusicalKey(tonic: tonic, minor: isMinor), pearson(mean, rotated)))
            }
        }
        scored.sort { $0.1 > $1.1 }
        guard scored[0].1 > 0.3 else { return nil }
        return KeyResult(key: scored[0].0, runnerUp: scored[1].0, confidence: max(0, min(1, scored[0].1)))
    }

    static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<12 {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        return num / max(sqrt(da * db), 1e-12)
    }
}
