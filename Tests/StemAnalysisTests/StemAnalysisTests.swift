import XCTest
@testable import StemAnalysis

let sr = 22_050.0
let modelsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Models").standardized

func midiHz(_ m: Int) -> Double { 440 * pow(2, Double(m - 69) / 12) }

func addTone(_ x: inout [Float], midi: Int, start: Double, dur: Double, amp: Float = 0.15) {
    let f = midiHz(midi), a = Int(start * sr), n = Int(dur * sr)
    for i in 0..<n where a + i < x.count {
        let t = Double(i) / sr
        let env = Float(min(1, t / 0.01) * exp(-1.5 * t))
        var s = 0.0
        for h in 1...4 { s += sin(2 * .pi * f * Double(h) * t) / Double(h) }
        x[a + i] += amp * env * Float(s)
    }
}

func clicks(bpm: Double, seconds: Double) -> [Float] {
    var x = [Float](repeating: 0, count: Int(seconds * sr))
    var t = 0.25
    var k = 0
    while t < seconds {
        let a = Int(t * sr)
        let accent: Float = k % 4 == 0 ? 1 : 0.6
        var seed: UInt32 = 1
        for i in 0..<400 where a + i < x.count {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(Int(seed >> 9) - 4_194_304) / 4_194_304
            x[a + i] += accent * noise * exp(-Float(i) / 60)
        }
        t += 60 / bpm
        k += 1
    }
    return x
}

final class StemAnalysisTests: XCTestCase {

    func testChromaA440() {
        var x = [Float](repeating: 0, count: Int(sr))
        for i in 0..<x.count { x[i] = sin(2 * .pi * 440 * Float(i) / Float(sr)) }
        let frames = Chroma.frames(x)
        let c = frames[frames.count / 2]
        XCTAssertEqual(c.indices.max { c[$0] < c[$1] }, 9)
    }

    func testTempoClickTracks() throws {
        for bpm in [90.0, 120.0, 128.0, 140.0, 174.0] {
            let r = try XCTUnwrap(TempoDetector.detect(clicks(bpm: bpm, seconds: 30)), "\(bpm)")
            // Octave errors are what the ½×/2× toggle is for; expect exact here.
            XCTAssertEqual(r.bpm, bpm, accuracy: 1, "\(bpm) → \(r.bpm)")
            XCTAssertEqual(r.beats.first ?? -1, 0.25, accuracy: 0.03)
        }
    }

    func testTempoSilenceAndToneHaveNoBeat() {
        XCTAssertNil(TempoDetector.detect([Float](repeating: 0, count: Int(sr * 10))))
        var tone = [Float](repeating: 0, count: Int(sr * 10))
        for i in 0..<tone.count { tone[i] = 0.3 * sin(2 * .pi * 220 * Float(i) / Float(sr)) }
        XCTAssertNil(TempoDetector.detect(tone))
    }

    /// I-IV-V-I (major) or i-iv-V-i (minor, raised leading tone), 1 s per chord, 4 rounds.
    func cadence(tonic: Int, minor: Bool) -> [Float] {
        let third = minor ? 3 : 4
        let chords: [[Int]] = [[0, third, 7], [5, minor ? 8 : 9, 12], [7, 11, 14], [0, third, 7]]
        var x = [Float](repeating: 0, count: Int(sr * 16))
        for round in 0..<4 {
            for (i, ch) in chords.enumerated() {
                let start = Double(round * 4 + i)
                for iv in ch { addTone(&x, midi: 60 + tonic + iv, start: start, dur: 1) }
                addTone(&x, midi: 48 + tonic + ch[0], start: start, dur: 1)
            }
        }
        return x
    }

    func testKeyAll24() throws {
        var misses: [String] = []
        for tonic in 0..<12 {
            for minor in [false, true] {
                let r = try XCTUnwrap(KeyDetector.detect(chroma: Chroma.frames(cadence(tonic: tonic, minor: minor))))
                let want = MusicalKey(tonic: tonic, minor: minor)
                if r.key != want { misses.append("\(want.name)→\(r.key.name)") }
            }
        }
        XCTAssertEqual(misses, [])
    }

    func testKeyNoTonalCenter() {
        var seed: UInt32 = 7
        let noise: [Float] = (0..<Int(sr * 5)).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int(seed >> 9) - 4_194_304) / 4_194_304 * 0.3
        }
        XCTAssertNil(KeyDetector.detect(chroma: Chroma.frames(noise)))
        XCTAssertNil(KeyDetector.detect(chroma: Chroma.frames([Float](repeating: 0, count: Int(sr)))))
    }

    func testCamelotAndTranspose() {
        XCTAssertEqual(MusicalKey(tonic: 9, minor: true).camelot, "8A")
        XCTAssertEqual(MusicalKey(tonic: 0, minor: false).camelot, "8B")
        XCTAssertEqual(MusicalKey(tonic: 11, minor: false).camelot, "1B")
        XCTAssertEqual(MusicalKey(tonic: 8, minor: true).camelot, "1A")
        XCTAssertEqual(MusicalKey(tonic: 4, minor: false).camelot, "12B")
        XCTAssertEqual(MusicalKey(tonic: 9, minor: true).transposed(2).name, "Bm")
        XCTAssertEqual(Chord(root: 11, quality: .minor7).transposed(1).name, "Cm7")
    }

    func testChordsCGAmF() {
        // 2 beats (1 s) per chord at 120 BPM, 3 rounds.
        let prog: [(Int, [Int])] = [(0, [0, 4, 7]), (7, [7, 11, 14]), (9, [9, 12, 16]), (5, [5, 9, 12])]
        var x = [Float](repeating: 0, count: Int(sr * 12))
        for round in 0..<3 {
            for (i, (root, notes)) in prog.enumerated() {
                let start = Double(round * 4 + i)
                for nn in notes { addTone(&x, midi: 60 + nn, start: start, dur: 1) }
                addTone(&x, midi: 48 + root, start: start, dur: 1)
            }
        }
        let beats = stride(from: 0.0, to: 12, by: 0.5).map { $0 }
        let segs = ChordTracker.track(chroma: Chroma.frames(x), energy: Chroma.energy(x),
                                      frameDuration: Chroma.frameDuration(), beats: beats)
        let want = ["C", "G", "Am", "F"]
        var correct = 0
        for s in 0..<12 {
            let t = Double(s) + 0.5
            if segs.first(where: { $0.start <= t && t < $0.end })?.chord?.name == want[s % 4] { correct += 1 }
        }
        XCTAssertGreaterThanOrEqual(correct, 11, segs.map { "\($0.chord?.name ?? "N")@\($0.start)" }.joined(separator: " "))
    }

    func testChordsFallbackWithoutBeats() {
        var x = [Float](repeating: 0, count: Int(sr * 3))
        for nn in [60, 64, 67] { addTone(&x, midi: nn, start: 0, dur: 3) }
        let segs = ChordTracker.track(chroma: Chroma.frames(x), energy: Chroma.energy(x),
                                      frameDuration: Chroma.frameDuration(), beats: [])
        XCTAssertEqual(segs.first?.chord?.name, "C")
    }

    func testTranscribeCMajorScale() throws {
        let url = modelsDir.appendingPathComponent("basic-pitch.mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no basic-pitch model") }
        let scale = [60, 62, 64, 65, 67, 69, 71, 72]
        var x = [Float](repeating: 0, count: Int(sr * 5))
        for (i, m) in scale.enumerated() { addTone(&x, midi: m, start: 0.25 + Double(i) * 0.5, dur: 0.45, amp: 0.3) }
        let notes = NoteTranscriber.monophonic(try NoteTranscriber(modelURL: url).transcribe(x))
        XCTAssertEqual(notes.map(\.pitch), scale)
        for (i, n) in notes.enumerated() { XCTAssertEqual(n.start, 0.25 + Double(i) * 0.5, accuracy: 0.05) }
    }

    func testMIDIWriter() {
        let notes = [NoteEvent(start: 0, end: 0.5, pitch: 60, velocity: 1), NoteEvent(start: 0.5, end: 1, pitch: 60, velocity: 0.5)]
        let d = [UInt8](MIDIWriter.data(notes: notes, bpm: 120))
        XCTAssertEqual(Array(d[0..<4]), Array("MThd".utf8))
        XCTAssertEqual(Array(d[8..<14]), [0, 1, 0, 2, 0x01, 0xE0])  // type 1, 2 tracks, 480 ppq
        XCTAssertEqual(Array(d[14..<18]), Array("MTrk".utf8))
        // 120 BPM tempo meta = 500000 µs.
        XCTAssertNotNil(d.firstRange(of: [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]))
        // 0.5 s at 120 BPM = 480 ticks; note-off precedes the retrigger at the same tick.
        XCTAssertNotNil(d.firstRange(of: [0x83, 0x60, 0x80, 60, 0, 0x00, 0x90, 60, 64]))
        let empty = [UInt8](MIDIWriter.data(notes: [], bpm: 0))
        XCTAssertEqual(Array(empty[0..<4]), Array("MThd".utf8))
        XCTAssertEqual(Array(empty.suffix(3)), [0xFF, 0x2F, 0x00])
    }
}
