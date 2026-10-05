import Foundation

/// Everything the mix graph needs, persisted as mix.json beside the stems.
public struct MixSettings: Codable, Equatable, Sendable {
    public var stems: [String: StemSettings] = [:]
    /// Semitones, -12...12. Applied on the master so stems stay aligned.
    public var pitch: Double = 0
    /// Playback rate, 0.5...1.5.
    public var tempo: Double = 1
    public var masterEQ = EQSettings()

    public init() {}

    public subscript(stem: String) -> StemSettings {
        get { stems[stem] ?? StemSettings() }
        set { stems[stem] = newValue }
    }

    public var anySolo: Bool { stems.values.contains { $0.solo } }

    /// Linear gain a stem actually plays at after mute/solo.
    public func effectiveGain(_ stem: String) -> Float {
        let s = self[stem]
        if s.mute || (anySolo && !s.solo) { return 0 }
        return Float(s.volume)
    }

    /// True when the graph is an identity for this stem (export can null-test against the source).
    public func isNeutral(_ stem: String) -> Bool {
        let s = self[stem]
        return pitch == 0 && tempo == 1 && masterEQ.isFlat && s.eq.isFlat && !s.delay.enabled && !s.reverb.enabled && s.pan == 0
            && s.clips == nil
    }
}

public struct StemSettings: Codable, Equatable, Sendable {
    public var volume: Double = 1     // 0...2 linear
    public var pan: Double = 0        // -1...1
    public var mute = false
    public var solo = false
    public var eq = EQSettings()
    public var delay = DelaySettings()
    public var reverb = ReverbSettings()
    /// Arrangement. nil = one clip spanning the whole file.
    public var clips: [Clip]?
    /// Duplicated tracks play another stem's file ("other 2" → "other"). nil = own file.
    public var source: String?
    public init() {}
}

public struct EQSettings: Codable, Equatable, Sendable {
    public var low: Double = 0    // dB, shelf at 120 Hz
    public var mid: Double = 0    // dB, peak at 1 kHz
    public var high: Double = 0   // dB, shelf at 6 kHz
    public var bypass = false
    public init() {}
    public var isFlat: Bool { bypass || (low == 0 && mid == 0 && high == 0) }
}

public struct DelaySettings: Codable, Equatable, Sendable {
    public var enabled = false
    /// Beat-synced note value in quarter notes (0.5 = 1/8). nil = free time in `milliseconds`.
    public var beats: Double? = 0.5
    public var milliseconds: Double = 250
    public var feedback: Double = 30  // %
    public var mix: Double = 20       // % wet
    public init() {}

    /// Seconds, following detected BPM (the delay sits pre-TimePitch: source time).
    public func seconds(bpm: Double?) -> Double {
        if let beats, let bpm, bpm > 0 { return min(2, 60 / bpm * beats) }
        return min(2, milliseconds / 1000)
    }
}

public struct ReverbSettings: Codable, Equatable, Sendable {
    public enum Room: String, Codable, CaseIterable, Sendable { case room, plate, hall, cathedral }
    public var enabled = false
    public var room: Room = .hall
    public var wet: Double = 25  // %
    public init() {}
}
