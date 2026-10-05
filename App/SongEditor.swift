import Accelerate
import AVFoundation
import Foundation
import StemAnalysis
import StemMix
import StemSeparation

enum EditError: Error, LocalizedError {
    case emptyResult
    var errorDescription: String? { "That edit would leave no audio" }
}

private protocol StartEnd {
    var start: Double { get set }
    var end: Double { get set }
}
extension NoteEvent: StartEnd {}
extension ChordSegment: StartEnd {}

/// Edits that change the audio land as new library entries: plain files stay the database
/// and the original song folder is never touched.
enum SongEditor {
    /// Snapshot of the source song, taken on the main actor before the file work runs.
    struct Payload {
        let stems: [(name: String, url: URL)]
        let peaks: [String: [Float]]
        let notes: [String: [NoteEvent]]
        let analysis: AnalysisResult?
        let mix: MixSettings
        let info: SongInfo
    }

    // MARK: Edits (return the new duration)

    static func writeReversed(_ p: Payload, to folder: URL) throws -> Double {
        let d = p.info.duration
        var duration = 0.0
        for (name, url) in p.stems {
            duration = try rewriteWAV(from: url, to: folder.appendingPathComponent("\(name).wav"), cut: nil, reverse: true)
        }
        var peaks = p.peaks, notes = p.notes
        for (name, v) in p.peaks { peaks[name] = Array(v.reversed()) }
        for (name, v) in p.notes { notes[name] = v.map { mirrored($0, duration: d) }.sorted { $0.start < $1.start } }
        try writeSidecars(peaks: peaks, notes: notes, analysis: p.analysis.map { reversedAnalysis($0, duration: d) },
                          mix: p.mix, to: folder)
        return duration
    }

    static func writeCut(_ p: Payload, range: ClosedRange<Double>, to folder: URL) throws -> Double {
        var duration = 0.0
        for (name, url) in p.stems {
            duration = try rewriteWAV(from: url, to: folder.appendingPathComponent("\(name).wav"), cut: range, reverse: false)
        }
        var peaks = p.peaks, notes = p.notes
        for (name, v) in p.peaks { peaks[name] = cutPeaks(v, range: range) }
        for (name, v) in p.notes { notes[name] = cut(v, range: range, minDuration: 0.01) }
        var analysis = p.analysis
        if var a = analysis {
            a.chords = cut(a.chords, range: range, minDuration: 0.05)
            if var t = a.tempo { t.beats = cutBeats(t.beats, range: range); a.tempo = t }
            analysis = a
        }
        try writeSidecars(peaks: peaks, notes: notes, analysis: analysis, mix: p.mix, to: folder)
        return duration
    }

    // MARK: Audio copy

    /// Streams one stem into a new 24-bit WAV, optionally dropping a time range and/or reversing.
    /// Memory is O(chunk): a reversed 30-minute song never sits in RAM whole.
    static func rewriteWAV(from src: URL, to dst: URL, cut: ClosedRange<Double>?, reverse: Bool) throws -> Double {
        let file = try AVAudioFile(forReading: src)
        let fmt = file.processingFormat, sr = fmt.sampleRate
        let length = file.length
        var spans: [(Int64, Int64)] = []  // [start, end) of kept audio
        if let cut {
            let lo = min(max(0, cut.lowerBound * sr), Double(length))
            let hi = min(max(0, cut.upperBound * sr), Double(length))
            if lo > 0 { spans.append((0, Int64(lo.rounded(.down)))) }
            if hi < Double(length) { spans.append((Int64(hi.rounded(.up)), length)) }
        } else {
            spans.append((0, length))
        }
        guard !spans.isEmpty else { throw EditError.emptyResult }

        let out = try AVAudioFile(forWriting: dst, settings: StemEdit.wavSettings(fmt),
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: Int64 = 65_536
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk))!
        var frames = 0

        func move(_ at: Int64, _ n: Int64) throws {
            file.framePosition = at
            buf.frameLength = 0
            try file.read(into: buf, frameCount: AVAudioFrameCount(n))
            if reverse {
                for c in 0..<Int(fmt.channelCount) {
                    if let ch = buf.floatChannelData?[c] { vDSP_vrvrs(ch, 1, vDSP_Length(buf.frameLength)) }
                }
            }
            try out.write(from: buf)
            frames += Int(buf.frameLength)
        }

        for (spanStart, spanEnd) in spans {
            if reverse {
                var pending = spanEnd
                while pending > spanStart {
                    let n = min(chunk, pending - spanStart)
                    try move(pending - n, n)
                    pending -= n
                }
            } else {
                var at = spanStart
                while at < spanEnd {
                    let n = min(chunk, spanEnd - at)
                    try move(at, n)
                    at += n
                }
            }
        }
        return Double(frames) / sr
    }

    static func writeSidecars(peaks: [String: [Float]], notes: [String: [NoteEvent]],
                              analysis: AnalysisResult?, mix: MixSettings, to folder: URL) throws {
        for (name, p) in peaks {
            try p.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
                .write(to: SplitPipeline.peaksURL(folder, name))
        }
        let enc = JSONEncoder()
        for (name, n) in notes { try enc.encode(n).write(to: folder.appendingPathComponent("notes-\(name).json")) }
        if let analysis { try enc.encode(analysis).write(to: folder.appendingPathComponent("analysis.json")) }
        try enc.encode(mix).write(to: folder.appendingPathComponent("mix.json"))
    }

    // MARK: Sidecar remaps

    private static func mirrored<T: StartEnd>(_ n: T, duration: Double) -> T {
        var m = n
        m.start = max(0, duration - n.end)
        m.end = max(m.start, duration - n.start)
        return m
    }

    static func reversedAnalysis(_ a: AnalysisResult, duration: Double) -> AnalysisResult {
        var r = a
        if var t = r.tempo {
            t.beats = t.beats.map { duration - $0 }.filter { $0 >= 0 }.sorted()
            r.tempo = t
        }
        r.chords = a.chords.map { mirrored($0, duration: duration) }.sorted { $0.start < $1.start }
        return r
    }

    /// A segment (or note) straddling the cut is split into its before and after parts.
    private static func cut<T: StartEnd>(_ list: [T], range: ClosedRange<Double>, minDuration: Double) -> [T] {
        let len = range.upperBound - range.lowerBound
        var out: [T] = []
        for n in list {
            if n.start < range.lowerBound {
                var l = n; l.end = min(n.end, range.lowerBound); out.append(l)
            }
            if n.end > range.upperBound {
                var r = n; r.start = max(n.start, range.upperBound) - len; r.end -= len; out.append(r)
            }
        }
        return out.filter { $0.end - $0.start > minDuration }.sorted { $0.start < $1.start }
    }

    static func cutBeats(_ beats: [Double], range: ClosedRange<Double>) -> [Double] {
        let len = range.upperBound - range.lowerBound
        return beats.compactMap { b in b >= range.upperBound ? b - len : (b < range.lowerBound ? b : nil) }
    }

    /// Drops the peak bins covered by the range (bins are 1/50 s, edges land at bin granularity).
    static func cutPeaks(_ peaks: [Float], range: ClosedRange<Double>) -> [Float] {
        let pps = Double(SplitPipeline.peaksPerSecond)
        return peaks.enumerated().compactMap { i, v in
            let binStart = Double(i) / pps, binEnd = Double(i + 1) / pps
            return binEnd <= range.lowerBound || binStart >= range.upperBound ? v : nil
        }
    }
}
