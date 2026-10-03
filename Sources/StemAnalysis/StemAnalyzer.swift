import Foundation

/// Written beside the stems as analysis.json. Bump `currentVersion` when an algorithm changes:
/// older files re-analyze on open.
public struct AnalysisResult: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = AnalysisResult.currentVersion
    public var tempo: TempoResult?
    public var key: KeyResult?
    public var chords: [ChordSegment]

    public init(tempo: TempoResult?, key: KeyResult?, chords: [ChordSegment]) {
        self.tempo = tempo
        self.key = key
        self.chords = chords
    }
}

public enum StemAnalyzer {
    /// `rhythm`: stems to read the beat from (drums; instrumental in 2-stem mode).
    /// `harmony`: stems to read key/chords from (bass + other; instrumental in 2-stem mode).
    public static func analyze(rhythm: [URL], harmony: [URL]) throws -> AnalysisResult {
        let drums = try AudioLoader.mono(rhythm)
        let tonal = try AudioLoader.mono(harmony)
        let tempo = TempoDetector.detect(drums)
        let chroma = Chroma.frames(tonal)
        let key = KeyDetector.detect(chroma: chroma)
        let chords = key == nil ? [] : ChordTracker.track(chroma: chroma, energy: Chroma.energy(tonal),
                                                          frameDuration: Chroma.frameDuration(), beats: tempo?.beats ?? [])
        return AnalysisResult(tempo: tempo, key: key, chords: chords)
    }

    /// Which stems feed which analysis, by stem name.
    public static func inputs(stems: [String: URL]) -> (rhythm: [URL], harmony: [URL]) {
        if let drums = stems["drums"] {
            return ([drums], [stems["bass"], stems["other"]].compactMap { $0 })
        }
        let inst = stems["instrumental"].map { [$0] } ?? Array(stems.values)
        return (inst, inst)
    }

    /// Stems worth transcribing: melody, bass line, harmony.
    public static let transcribable = ["vocals", "bass", "other"]

    public static func transcribe(stem: String, url: URL, with transcriber: NoteTranscriber) throws -> [NoteEvent] {
        var options = NoteTranscriber.Options()
        switch stem {
        case "vocals": options.pitchRange = 40...84   // E2–C6
        case "bass": options.pitchRange = 23...64     // B0–E4
        default: break
        }
        let notes = try transcriber.transcribe(AudioLoader.mono(url), options: options)
        return stem == "vocals" || stem == "bass" ? NoteTranscriber.monophonic(notes) : notes
    }
}
