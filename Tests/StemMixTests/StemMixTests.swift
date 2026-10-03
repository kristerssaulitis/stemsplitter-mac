import AVFoundation
import XCTest
@testable import StemMix

func writeStem(_ name: String, freq: Float, seconds: Double = 2) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID()).wav")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
                                                           AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24],
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let n = AVAudioFrameCount(seconds * 44_100)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
    buf.frameLength = n
    for i in 0..<Int(n) {
        let v = 0.3 * sin(2 * Float.pi * freq * Float(i) / 44_100)
        buf.floatChannelData![0][i] = v
        buf.floatChannelData![1][i] = v * 0.5
    }
    try file.write(from: buf)
    return url
}

func read(_ url: URL) throws -> (l: [Float], r: [Float], rate: Double) {
    let f = try AVAudioFile(forReading: url)
    let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: b)
    let n = Int(b.frameLength)
    return (Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: n)),
            Array(UnsafeBufferPointer(start: b.floatChannelData![1], count: n)), f.processingFormat.sampleRate)
}

func peakDB(_ a: [Float], _ b: [Float]) -> Double {
    var m: Float = 0
    for i in 0..<min(a.count, b.count) { m = max(m, abs(a[i] - b[i])) }
    return 20 * log10(Double(max(m, 1e-12)))
}

final class StemMixTests: XCTestCase {
    var stems: [(name: String, url: URL)] = []

    override func setUpWithError() throws {
        stems = [("vocals", try writeStem("vocals", freq: 440)), ("bass", try writeStem("bass", freq: 55))]
    }

    func out(_ ext: String = "wav") -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mix-\(UUID()).\(ext)") }

    /// Plan success criterion: FX bypassed + pitch 0 → exported stem nulls against the source (< -90 dBFS).
    func testNeutralStemExportNullTests() throws {
        let url = out()
        try ExportRenderer.render(stems: stems, settings: MixSettings(), bpm: 120, only: "vocals", range: nil,
                                  format: ExportFormat(depth: .float32), sourceSampleRate: nil, to: url)
        let src = try read(stems[0].url), got = try read(url)
        XCTAssertEqual(got.l.count, src.l.count)
        XCTAssertLessThan(peakDB(src.l, got.l), -90)
        XCTAssertLessThan(peakDB(src.r, got.r), -90)
    }

    func testMixdownIsSumAtFaderLevels() throws {
        var s = MixSettings()
        s["bass"].volume = 0.5
        let url = out()
        try ExportRenderer.render(stems: stems, settings: s, bpm: nil, only: nil, range: nil,
                                  format: ExportFormat(depth: .float32), sourceSampleRate: nil, to: url)
        let v = try read(stems[0].url), b = try read(stems[1].url), got = try read(url)
        let want = zip(v.l, b.l).map { $0 + 0.5 * $1 }
        XCTAssertLessThan(peakDB(want, got.l), -90)
    }

    func testMuteSoloGain() {
        var s = MixSettings()
        s["vocals"].solo = true
        XCTAssertEqual(s.effectiveGain("bass"), 0)
        XCTAssertEqual(s.effectiveGain("vocals"), 1)
        s["vocals"].mute = true
        XCTAssertEqual(s.effectiveGain("vocals"), 0)
    }

    func testRegionRateFormatAndTempo() throws {
        var s = MixSettings()
        s.tempo = 0.5
        let url = out("flac")
        try ExportRenderer.render(stems: stems, settings: s, bpm: nil, only: "vocals", range: 0.5...1.5,
                                  format: ExportFormat(container: .flac, sampleRate: 48_000, depth: .int24),
                                  sourceSampleRate: nil, to: url)
        let got = try read(url)
        XCTAssertEqual(got.rate, 48_000)
        XCTAssertEqual(Double(got.l.count), 2 * 48_000, accuracy: 10)  // 1 s at half speed
    }

    func testPitchUpOctaveDoublesFrequency() throws {
        var s = MixSettings()
        s.pitch = 12
        let url = out()
        try ExportRenderer.render(stems: stems, settings: s, bpm: nil, only: "vocals", range: nil,
                                  format: ExportFormat(depth: .float32), sourceSampleRate: nil, to: url)
        let got = try read(url).l
        // Zero crossings over the middle second ≈ 2 × 880.
        let mid = Array(got[22_050..<66_150])
        var crossings = 0
        for i in 1..<mid.count where (mid[i - 1] < 0) != (mid[i] < 0) { crossings += 1 }
        XCTAssertEqual(Double(crossings), 1760, accuracy: 40)
    }

    func testFXChangeOutputAndAddTail() throws {
        var s = MixSettings()
        s["vocals"].reverb.enabled = true
        s["vocals"].eq.high = 6
        let url = out()
        try ExportRenderer.render(stems: stems, settings: s, bpm: 120, only: "vocals", range: nil,
                                  format: ExportFormat(depth: .float32), sourceSampleRate: nil, to: url)
        let got = try read(url), src = try read(stems[0].url)
        XCTAssertEqual(got.l.count, src.l.count + 2 * 44_100)
        XCTAssertGreaterThan(peakDB(src.l, got.l), -40)
    }

    func testDelayBeatSync() {
        var d = DelaySettings()
        d.beats = 0.5
        XCTAssertEqual(d.seconds(bpm: 120, tempo: 1), 0.25, accuracy: 1e-9)
        d.beats = nil
        d.milliseconds = 300
        XCTAssertEqual(d.seconds(bpm: 120, tempo: 1), 0.3, accuracy: 1e-9)
    }

    func testClipOps() {
        let d = 10.0
        var c = Clips.split(Clips.whole(d), at: 4)
        XCTAssertEqual(c.map(\.start), [0, 4])
        XCTAssertEqual(c[1].offset, 4)
        c = Clips.carve(c, 2...6)
        XCTAssertEqual(c.map(\.end), [2, 10])
        // Reversing 0...10 mirrors: the clip at 6...10 lands at 0...4, playing source 6...10 backwards.
        let r = Clips.reverse(c, 0...d)
        XCTAssertEqual(r[0].start, 0, accuracy: 1e-9)
        XCTAssertTrue(r[0].reversed)
        XCTAssertEqual(r[0].sourceTime(0), 10, accuracy: 1e-9)
        XCTAssertEqual(Clips.reverse(r, 0...d), c)  // twice = identity
        // Duplicate 0...2 → copy at 2...4 over the gap.
        let dup = Clips.duplicate(c, 0...2, duration: d)
        XCTAssertEqual(dup.map(\.start), [0, 2, 6])
        XCTAssertEqual(dup[1].offset, 0)
        // Trim can't grow past the source: left edge of clip at offset 6 stops at timeline 0 (offset 0).
        let t = Clips.trim(c, index: 1, leftEdge: true, to: -5, sourceLength: d, duration: d)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(t[0].offset, 0, accuracy: 1e-9)
        let m = Clips.move(c, index: 0, by: 7, duration: d)  // lands on 7...9, overwriting it
        XCTAssertEqual(m.map(\.start), [6, 7, 9])
    }

    /// Clips render sample-accurately: gap silent, reversed clip reads the reversed file.
    func testClipsRender() throws {
        let rev = StemEdit.reversedURL(stems[0].url)
        try StemEdit.writeReversed(from: stems[0].url, to: rev)
        var s = MixSettings()
        s["vocals"].clips = [Clip(start: 0, offset: 0, length: 0.5), Clip(start: 1, offset: 1, length: 1, reversed: true)]
        let url = out()
        try ExportRenderer.render(stems: stems, settings: s, bpm: nil, only: "vocals", range: nil,
                                  format: ExportFormat(depth: .float32), sourceSampleRate: nil, to: url)
        let src = try read(stems[0].url), got = try read(url)
        let sr = 44_100, n = src.l.count
        XCTAssertLessThan(peakDB(Array(src.l[0..<sr / 2]), Array(got.l[0..<sr / 2])), -90)
        XCTAssertLessThan(peakDB([Float](repeating: 0, count: sr / 2), Array(got.l[sr / 2..<sr])), -90)
        XCTAssertLessThan(peakDB(Array(src.l[sr..<n].reversed()), Array(got.l[sr..<n])), -90)
    }
}
