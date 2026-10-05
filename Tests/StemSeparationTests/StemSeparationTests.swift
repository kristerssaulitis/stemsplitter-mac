import AVFoundation
import XCTest
@testable import StemSeparation

/// Fixtures come from tools/convert_htdemucs.py and tools/convert_melband.py (Models/ is
/// not in git). Tests skip without them.
let modelsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Models").standardized

func loadF32(_ file: String) throws -> [Float] {
    let url = modelsDir.appendingPathComponent("reference/\(file).f32")
    guard let d = try? Data(contentsOf: url) else { throw XCTSkip("missing fixture \(url.path)") }
    return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

func snr(_ ref: ArraySlice<Float>, _ got: ArraySlice<Float>) -> Double {
    var s = 0.0, n = 0.0
    for (a, b) in zip(ref, got) { s += Double(a * a); n += Double((a - b) * (a - b)) }
    return 10 * log10(s / max(n, 1e-30))
}

final class StemSeparationTests: XCTestCase {

    func testSTFTMatchesTorch() throws {
        let mix = try loadF32("htdemucs-mix"), spec = try loadF32("htdemucs-spec")
        let L = mix.count / 2, T = DemucsSTFT.frameCount(L), plane = DemucsSTFT.bins * T
        XCTAssertEqual(spec.count, 4 * plane)
        var got = [Float](repeating: 0, count: 4 * plane)
        let stft = DemucsSTFT()
        mix.withUnsafeBufferPointer { m in
            got.withUnsafeMutableBufferPointer { g in
                for ch in 0..<2 {
                    stft.forward(UnsafeBufferPointer(rebasing: m[(ch * L)..<((ch + 1) * L)]),
                                 re: g.baseAddress! + 2 * ch * plane, im: g.baseAddress! + (2 * ch + 1) * plane)
                }
            }
        }
        XCTAssertGreaterThan(snr(spec[...], got[...]), 80)
    }

    func testISTFTRoundTrip() {
        let L = 20_000
        let x = (0..<L).map { Float(sin(Double($0) * 0.01) + 0.1 * cos(Double($0) * 0.37)) }
        let T = DemucsSTFT.frameCount(L), plane = DemucsSTFT.bins * T
        var re = [Float](repeating: 0, count: plane), im = re, y = [Float](repeating: 0, count: L)
        let stft = DemucsSTFT()
        x.withUnsafeBufferPointer { stft.forward($0, re: &re, im: &im) }
        stft.inverseAdd(re: re, im: im, frames: T, into: &y, length: L)
        // demucs _ispec pads zero frames: outer ~hop*1.5 samples attenuated by design (pipeline
        // triangle weights hide it). Interior must be exact.
        let edge = 3 * DemucsSTFT.hop
        XCTAssertGreaterThan(snr(x[edge..<(L - edge)], y[edge..<(L - edge)]), 60)
    }

    func testModelMatchesTorchEndToEnd() throws {
        let url = modelsDir.appendingPathComponent("htdemucs.mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no compiled model") }
        let mix = try loadF32("htdemucs-mix"), full = try loadF32("htdemucs-full")
        let sep = try HTDemucsSeparator(modelURL: url)
        XCTAssertEqual(sep.sources, ["drums", "bass", "other", "vocals"])
        let out = try sep.separate(mix)
        XCTAssertEqual(out.count, full.count)
        // fp16 GPU vs fp32 torch, measured against the mix's energy: some synthetic-fixture
        // sources are near-silent, so per-source SNR would measure nothing useful.
        let n = 2 * sep.segmentLength
        let mixEnergy = mix.reduce(0.0) { $0 + Double($1 * $1) }
        for s in 0..<4 {
            var err = 0.0
            for i in (s * n)..<((s + 1) * n) { err += Double((full[i] - out[i]) * (full[i] - out[i])) }
            XCTAssertGreaterThan(10 * log10(mixEnergy / err), 35, "source \(sep.sources[s])")
        }
    }

    /// Gains sum to 1, so stems must sum back to the input.
    final class GainSeparator: MultiStemSeparator {
        let sources = ["drums", "bass", "other", "vocals"]
        let segmentLength = 4_000
        let gains: [Float] = [0.1, 0.2, 0.3, 0.4]
        func separate(_ segment: [Float]) throws -> [Float] {
            gains.flatMap { g in segment.map { $0 * g } }
        }
    }

    final class HalvesSeparator: MultiStemSeparator {
        let sources = ["vocals", "instrumental"]
        let segmentLength = 4_000
        let k: Float = 0.5
        func separate(_ segment: [Float]) throws -> [Float] {
            segment.map { $0 * k } + segment.map { $0 * (1 - k) }
        }
    }

    func makeTone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID()).wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let n = AVAudioFrameCount(seconds * 44_100)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        for i in 0..<Int(n) {
            buf.floatChannelData![0][i] = 0.5 * sin(Float(i) * 0.05)
            buf.floatChannelData![1][i] = 0.25 * sin(Float(i) * 0.031)
        }
        try file.write(from: buf)
        return url
    }

    func readStereo(_ url: URL) throws -> (l: [Float], r: [Float]) {
        let f = try AVAudioFile(forReading: url)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: b)
        let n = Int(b.frameLength)
        return (Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: n)),
                Array(UnsafeBufferPointer(start: b.floatChannelData![1], count: n)))
    }

    func testPipelineStemsSumToInputAndKeepLength() async throws {
        let src = try makeTone(seconds: 1.3)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("split-\(UUID())")
        let result = try await SplitPipeline(separator: GainSeparator()).run(SplitRequest(source: src, outputDirectory: out))
        XCTAssertEqual(result.frames, Int(1.3 * 44_100))
        let input = try readStereo(src)
        let stems = try result.stems.map { try readStereo($0.url) }
        XCTAssertEqual(stems[0].l.count, input.l.count)
        var sumL = [Float](repeating: 0, count: input.l.count)
        for s in stems { for i in 0..<sumL.count { sumL[i] += s.l[i] } }
        XCTAssertGreaterThan(snr(input.l[...], sumL[...]), 60)  // 24-bit storage floor
        XCTAssertEqual(stems[3].r[1000], input.r[1000] * 0.4, accuracy: 1e-4)
        let peaks = try Data(contentsOf: SplitPipeline.peaksURL(out, "vocals"))
        XCTAssertEqual(peaks.count / 4, Int((1.3 * 50).rounded(.up)))
    }

    func testPipelineTwoStemAndRange() async throws {
        let src = try makeTone(seconds: 2)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("split-\(UUID())")
        let req = SplitRequest(source: src, outputDirectory: out, range: 0.5...1.0, layout: .two)
        let result = try await SplitPipeline(separator: GainSeparator()).run(req)
        XCTAssertEqual(result.stems.map(\.name), ["vocals", "instrumental"])
        XCTAssertEqual(result.frames, 22_050)
        let input = try readStereo(src), inst = try readStereo(result.stems[1].url)
        XCTAssertEqual(inst.l[100], input.l[22_050 + 100] * 0.6, accuracy: 1e-4)
    }

    func testMelBandSTFTMatchesTorch() throws {
        let mix = try loadF32("melband-roformer-mix"), spec = try loadF32("melband-roformer-spec")
        let L = mix.count / 2, T = MelBandSTFT.frameCount(L), plane = MelBandSTFT.bins * T
        XCTAssertEqual(spec.count, 4 * plane)
        var got = [Float](repeating: 0, count: 4 * plane)
        let stft = MelBandSTFT()
        mix.withUnsafeBufferPointer { m in
            got.withUnsafeMutableBufferPointer { g in
                for ch in 0..<2 {
                    stft.forward(UnsafeBufferPointer(rebasing: m[(ch * L)..<((ch + 1) * L)]),
                                 re: g.baseAddress! + 2 * ch * plane, im: g.baseAddress! + (2 * ch + 1) * plane)
                }
            }
        }
        XCTAssertGreaterThan(snr(spec[...], got[...]), 80)
    }

    func testMelBandRoformerMatchesTorchEndToEnd() throws {
        let url = modelsDir.appendingPathComponent("melband-roformer.mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no compiled model") }
        let mix = try loadF32("melband-roformer-mix"), full = try loadF32("melband-roformer-full")
        let sep = try MelBandRoformerSeparator(modelURL: url)
        XCTAssertEqual(sep.sources, ["vocals", "instrumental"])
        let out = try sep.separate(mix)
        let L = sep.segmentLength
        XCTAssertEqual(out.count, 4 * L)
        XCTAssertEqual(full.count, 2 * L)
        // fp16 GPU vs fp32 torch, measured against mix energy (as above).
        let mixEnergy = mix.reduce(0.0) { $0 + Double($1 * $1) }
        func energySNR(_ ref: ArraySlice<Float>, _ got: ArraySlice<Float>) -> Double {
            var err = 0.0
            for (a, b) in zip(ref, got) { err += Double((a - b) * (a - b)) }
            return 10 * log10(mixEnergy / max(err, 1e-30))
        }
        XCTAssertGreaterThan(energySNR(full[...], out[0..<(2 * L)]), 35, "vocals")
        // instrumental = mix - vocals (torch residual)
        var residual = [Float](repeating: 0, count: 2 * L)
        for i in 0..<(2 * L) { residual[i] = mix[i] - full[i] }
        XCTAssertGreaterThan(energySNR(residual[...], out[(2 * L)...]), 35, "instrumental")
        var sum = [Float](repeating: 0, count: 2 * L)
        for i in 0..<(2 * L) { sum[i] = out[i] + out[2 * L + i] }
        XCTAssertGreaterThan(snr(mix[...], sum[...]), 120)
    }

    func testPipelineOmitStems() async throws {
        let src = try makeTone(seconds: 1)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("split-\(UUID())")
        var req = SplitRequest(source: src, outputDirectory: out)
        req.omitStems = ["vocals", "other"]
        let result = try await SplitPipeline(separator: GainSeparator()).run(req)
        XCTAssertEqual(result.stems.map(\.name), ["drums", "bass"])
        let files = (try FileManager.default.contentsOfDirectory(atPath: out.path)).sorted()
        XCTAssertEqual(files, ["bass.wav", "drums.wav", "peaks-bass.f32", "peaks-drums.f32"])
        let input = try readStereo(src), drums = try readStereo(result.stems[0].url)
        XCTAssertEqual(drums.l[500], input.l[500] * 0.1, accuracy: 1e-4)
    }

    func testCascadeFourStem() async throws {
        let src = try makeTone(seconds: 1.1)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("split-\(UUID())")
        let cascade = CascadePipeline(vocals: HalvesSeparator(), residual: GainSeparator())
        let result = try await cascade.run(SplitRequest(source: src, outputDirectory: out))
        XCTAssertEqual(result.stems.map(\.name), ["drums", "bass", "other", "vocals"])
        XCTAssertEqual(result.frames, Int(1.1 * 44_100))
        // Stage 2 ran on the instrumental (0.5·input): drums = 0.1·0.5·input.
        let input = try readStereo(src)
        let drums = try readStereo(out.appendingPathComponent("drums.wav"))
        let other = try readStereo(out.appendingPathComponent("other.wav"))
        let vocals = try readStereo(out.appendingPathComponent("vocals.wav"))
        XCTAssertEqual(drums.l[800], input.l[800] * 0.05, accuracy: 1e-3)
        XCTAssertEqual(other.l[800], input.l[800] * 0.15, accuracy: 1e-3)
        XCTAssertEqual(vocals.l[800], input.l[800] * 0.5, accuracy: 1e-3)
        // Stems sum to 0.5·input + (0.1+0.2+0.3)·0.5·input; the mock's "vocals" gain 0.4 is
        // dropped (the real htdemucs head is near-silent on an instrumental).
        var sumL = [Float](repeating: 0, count: input.l.count)
        for stem in [drums, other, vocals, try readStereo(out.appendingPathComponent("bass.wav"))] {
            for i in 0..<sumL.count { sumL[i] += stem.l[i] }
        }
        let expectedL = input.l.map { $0 * 0.8 }
        XCTAssertGreaterThan(snr(expectedL[...], sumL[...]), 60)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("stage1").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("instrumental.wav").path))
    }

    func testCancelDeletesPartialOutput() async throws {
        let src = try makeTone(seconds: 3)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("split-\(UUID())")
        let task = Task { try await SplitPipeline(separator: GainSeparator()).run(SplitRequest(source: src, outputDirectory: out)) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancel")
        } catch {}
        let left = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        XCTAssertTrue(left.isEmpty, "partial files left: \(left)")
    }
}
