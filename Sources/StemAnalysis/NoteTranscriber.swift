import CoreML
import Foundation

public struct NoteEvent: Codable, Equatable, Sendable {
    public var start: Double     // seconds
    public var end: Double
    public var pitch: Int        // MIDI note number
    public var velocity: Double  // 0...1 (model amplitude)

    public init(start: Double, end: Double, pitch: Int, velocity: Double) {
        self.start = start
        self.end = end
        self.pitch = pitch
        self.velocity = velocity
    }
}

/// Spotify basic-pitch (Apache-2.0) Core ML model + a port of its `output_to_notes_polyphonic`.
/// Constants mirror basic_pitch/constants.py and inference.py v0.4.0.
public final class NoteTranscriber {
    static let sampleRate = 22_050.0
    static let fftHop = 256
    static let windowSamples = 43_844            // 2 s * 22050 - 256
    static let overlapFrames = 30
    static let overlapSamples = overlapFrames * fftHop
    static let hopSamples = windowSamples - overlapSamples
    static let framesPerWindow = 172
    static let midiOffset = 21
    static let pitches = 88

    public struct Options: Sendable {
        public var onsetThreshold: Float = 0.5
        public var frameThreshold: Float = 0.3
        public var minNoteFrames = 11            // round(127.7 ms * 86.13 fps)
        public var energyTolerance = 11
        public var melodiaTrick = true
        /// MIDI pitch limits (upstream min_freq/max_freq): drops bleed outside the instrument's range.
        public var pitchRange = 21...108
        public init() {}
    }

    private let model: MLModel

    /// `url`: compiled basic-pitch `.mlmodelc`.
    public init(modelURL url: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: config)
    }

    /// `x`: mono at 22.05 kHz. Polyphonic notes, sorted by start.
    public func transcribe(_ x: [Float], options: Options = Options()) throws -> [NoteEvent] {
        let (frames, onsets) = try activations(x)
        return Self.notes(frames: frames, onsets: onsets, options: options)
    }

    /// Model activations, unwrapped: (note, onset), each [frame][88].
    func activations(_ x: [Float]) throws -> ([[Float]], [[Float]]) {
        var audio = [Float](repeating: 0, count: Self.overlapSamples / 2) + x
        let windows = max(1, Int((Double(audio.count) / Double(Self.hopSamples)).rounded(.up)))
        audio += [Float](repeating: 0, count: max(0, (windows - 1) * Self.hopSamples + Self.windowSamples - audio.count))
        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples), 1], dataType: .float32)
        let olap = Self.overlapFrames / 2
        var note: [[Float]] = [], onset: [[Float]] = []
        for w in 0..<windows {
            try Task.checkCancellation()
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
                audio.withUnsafeBufferPointer { a in p.baseAddress!.update(from: a.baseAddress! + w * Self.hopSamples, count: Self.windowSamples) }
            }
            let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_2": input]))
            for (name, dst) in [("Identity_1", 0), ("Identity_2", 1)] {
                guard let arr = out.featureValue(for: name)?.multiArrayValue else { continue }
                let strides = arr.strides.map(\.intValue)
                arr.withUnsafeBufferPointer(ofType: Float.self) { p in
                    for f in olap..<(Self.framesPerWindow - olap) {
                        let row = (0..<Self.pitches).map { p[f * strides[1] + $0 * strides[2]] }
                        if dst == 0 { note.append(row) } else { onset.append(row) }
                    }
                }
            }
        }
        let keep = Int(Double(x.count) * (Self.sampleRate / Double(Self.fftHop)) / Self.sampleRate)
        return (Array(note.prefix(keep)), Array(onset.prefix(keep)))
    }

    /// basic-pitch frame → seconds, including its per-window offset correction.
    static func time(_ frame: Int) -> Double {
        let fps = Double(Int(sampleRate) / fftHop)  // 86 (integer division, as upstream)
        let original = Double(frame) * Double(fftHop) / sampleRate
        let annotFrames = fps * 2
        let windowOffset = (Double(fftHop) / sampleRate) * (annotFrames - Double(windowSamples) / Double(fftHop)) + 0.0018
        return original - windowOffset * floor(Double(frame) / annotFrames)
    }

    static func notes(frames: [[Float]], onsets: [[Float]], options o: Options) -> [NoteEvent] {
        let n = frames.count
        guard n > 2 else { return [] }
        let P = pitches

        var onsets = onsets, frames = frames
        for t in 0..<n {
            for p in 0..<P where !o.pitchRange.contains(p + midiOffset) {
                onsets[t][p] = 0
                frames[t][p] = 0
            }
        }
        // Inferred onsets: min over 1- and 2-frame rises, rescaled to the onset max.
        var diff = [[Float]](repeating: [Float](repeating: 0, count: P), count: n)
        var maxDiff: Float = 0, maxOnset: Float = 0
        for t in 0..<n {
            for p in 0..<P {
                maxOnset = max(maxOnset, onsets[t][p])
                guard t >= 2 else { continue }
                let d1 = frames[t][p] - frames[t - 1][p], d2 = frames[t][p] - frames[t - 2][p]
                let d = max(0, min(d1, d2))
                diff[t][p] = d
                maxDiff = max(maxDiff, d)
            }
        }
        if maxDiff > 0 {
            for t in 0..<n { for p in 0..<P { onsets[t][p] = max(onsets[t][p], maxOnset * diff[t][p] / maxDiff) } }
        }

        // Onset peaks (local maxima in time) above threshold, processed latest first.
        var peaks: [(Int, Int)] = []
        for t in 1..<(n - 1) {
            for p in 0..<P where onsets[t][p] >= o.onsetThreshold && onsets[t][p] > onsets[t - 1][p] && onsets[t][p] > onsets[t + 1][p] {
                peaks.append((t, p))
            }
        }
        peaks.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 > $1.1 }

        var energy = frames
        var events: [(Int, Int, Int, Float)] = []
        func clear(_ t: Int, _ p: Int) {
            energy[t][p] = 0
            if p < P - 1 { energy[t][p + 1] = 0 }
            if p > 0 { energy[t][p - 1] = 0 }
        }
        func amplitude(_ a: Int, _ b: Int, _ p: Int) -> Float {
            var s: Float = 0
            for t in a..<b { s += frames[t][p] }
            return s / Float(max(1, b - a))
        }
        for (start, p) in peaks {
            if start >= n - 1 { continue }
            var i = start + 1, k = 0
            while i < n - 1 && k < o.energyTolerance {
                k = energy[i][p] < o.frameThreshold ? k + 1 : 0
                i += 1
            }
            i -= k
            if i - start <= o.minNoteFrames { continue }
            for t in start..<i { clear(t, p) }
            events.append((start, i, p, amplitude(start, i, p)))
        }

        if o.melodiaTrick {
            // Upstream re-scans for the argmax each iteration. Energy only ever drops to 0, so visiting
            // cells once in descending order (skipping zeroed ones) yields the same sequence in O(k log k).
            var cells: [(Float, Int, Int)] = []
            for t in 0..<n { for p in 0..<P where energy[t][p] > o.frameThreshold { cells.append((energy[t][p], t, p)) } }
            cells.sort { $0.0 > $1.0 }
            for (_, bt, bp) in cells {
                guard energy[bt][bp] > o.frameThreshold else { continue }
                energy[bt][bp] = 0
                var i = bt + 1, k = 0
                while i < n - 1 && k < o.energyTolerance {
                    k = energy[i][bp] < o.frameThreshold ? k + 1 : 0
                    clear(i, bp)
                    i += 1
                }
                let end = i - 1 - k
                i = bt - 1
                k = 0
                while i > 0 && k < o.energyTolerance {
                    k = energy[i][bp] < o.frameThreshold ? k + 1 : 0
                    clear(i, bp)
                    i -= 1
                }
                let start = i + 1 + k
                if end - start <= o.minNoteFrames { continue }
                events.append((start, end, bp, amplitude(start, end, bp)))
            }
        }

        return events
            .map { NoteEvent(start: time($0.0), end: time($0.1), pitch: $0.2 + midiOffset, velocity: Double($0.3)) }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.pitch < $1.pitch }
    }

    /// One note at a time (vocal melody): on overlap the louder note wins, the other is trimmed or dropped.
    public static func monophonic(_ notes: [NoteEvent]) -> [NoteEvent] {
        var out: [NoteEvent] = []
        for note in notes.sorted(by: { $0.start < $1.start }) {
            guard var last = out.last, note.start < last.end else { out.append(note); continue }
            if note.velocity > last.velocity {
                last.end = note.start
                out[out.count - 1] = last
                if last.end - last.start < 0.06 { out.removeLast() }
                out.append(note)
            } else if note.end > last.end {
                var trimmed = note
                trimmed.start = last.end
                if trimmed.end - trimmed.start >= 0.06 { out.append(trimmed) }
            }
        }
        return out
    }
}
