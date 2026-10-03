import Accelerate
import AVFoundation

public enum AudioLoader {
    /// Analysis rate. Key/BPM/chords/notes don't need 44.1 kHz stereo.
    public static let sampleRate = 22_050.0

    /// Sum of one or more files, downmixed to mono at `sampleRate`.
    public static func mono(_ urls: [URL], sampleRate: Double = sampleRate) throws -> [Float] {
        var sum: [Float] = []
        for url in urls {
            let x = try mono(url, sampleRate: sampleRate)
            if sum.isEmpty { sum = x; continue }
            let n = min(sum.count, x.count)
            vDSP_vadd(sum, 1, x, 1, &sum, 1, vDSP_Length(n))
        }
        return sum
    }

    public static func mono(_ url: URL, sampleRate: Double = sampleRate) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return [] }
        let inCap: AVAudioFrameCount = 1 << 16
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCap)!
        let outCap = AVAudioFrameCount(Double(inCap) * sampleRate / file.processingFormat.sampleRate) + 1024
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * sampleRate / file.processingFormat.sampleRate) + 1024)
        var done = false
        while true {
            let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap)!
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, inputStatus in
                if done { inputStatus.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: inBuf, frameCount: inCap)
                } catch {
                    done = true
                }
                if inBuf.frameLength == 0 { done = true; inputStatus.pointee = .endOfStream; return nil }
                inputStatus.pointee = .haveData
                return inBuf
            }
            if let error { throw error }
            out.append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
            if status == .endOfStream || status == .error || (outBuf.frameLength == 0 && done) { break }
        }
        return out
    }
}

/// Real FFT magnitudes of Hann-windowed frames. Shared by chroma and onset detection.
final class MagnitudeSTFT {
    let size: Int
    let hop: Int
    private let window: [Float]
    private let setup: vDSP_DFT_Setup
    private var evens: [Float], odds: [Float], re: [Float], im: [Float], frame: [Float]

    init(size: Int, hop: Int) {
        self.size = size
        self.hop = hop
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
        evens = [Float](repeating: 0, count: size / 2)
        odds = evens; re = evens; im = evens
        frame = [Float](repeating: 0, count: size)
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    var bins: Int { size / 2 }

    func frameCount(_ n: Int) -> Int { n < size ? (n > 0 ? 1 : 0) : 1 + (n - size) / hop }

    /// Calls `body(frameIndex, magnitudes[0..<size/2])` per frame.
    func forEachFrame(_ x: [Float], _ body: (Int, UnsafeBufferPointer<Float>) -> Void) {
        var mag = [Float](repeating: 0, count: bins)
        let count = frameCount(x.count)
        x.withUnsafeBufferPointer { xp in
            for f in 0..<count {
                let start = f * hop
                let avail = min(size, x.count - start)
                frame.withUnsafeMutableBufferPointer { fr in
                    vDSP_vmul(xp.baseAddress! + start, 1, window, 1, fr.baseAddress!, 1, vDSP_Length(avail))
                    if avail < size { (fr.baseAddress! + avail).update(repeating: 0, count: size - avail) }
                    var z: Float = 0
                    vDSP_vsadd(fr.baseAddress!, 2, &z, &evens, 1, vDSP_Length(size / 2))
                    vDSP_vsadd(fr.baseAddress! + 1, 2, &z, &odds, 1, vDSP_Length(size / 2))
                }
                vDSP_DFT_Execute(setup, evens, odds, &re, &im)
                im[0] = 0  // packed Nyquist; irrelevant for analysis
                re.withUnsafeMutableBufferPointer { r in
                    im.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(bins))
                    }
                }
                mag.withUnsafeBufferPointer { body(f, $0) }
            }
        }
    }
}

/// 12-bin pitch-class energy per frame.
public enum Chroma {
    public static let fftSize = 8192  // 2.7 Hz bins at 22.05 kHz: resolves semitones down to ~50 Hz
    public static let hop = 2048

    public static func frameDuration(sampleRate: Double = AudioLoader.sampleRate) -> Double { Double(hop) / sampleRate }

    /// Returns frames × 12, each frame unit-L2 (all-zero frames stay zero). Spectrally flat frames
    /// (noise, cymbals, silence) are zeroed: they have no pitch to contribute.
    public static func frames(_ x: [Float], sampleRate: Double = AudioLoader.sampleRate) -> [[Float]] {
        let stft = MagnitudeSTFT(size: fftSize, hop: hop)
        // bin → pitch class, 50 Hz ... 4 kHz
        var pc = [Int](repeating: -1, count: stft.bins)
        for k in 1..<stft.bins {
            let f = Double(k) * sampleRate / Double(fftSize)
            guard f >= 50, f <= 4000 else { continue }
            let midi = 69 + 12 * log2(f / 440)
            pc[k] = (Int(midi.rounded()) % 12 + 12) % 12
        }
        var out = [[Float]](repeating: [Float](repeating: 0, count: 12), count: stft.frameCount(x.count))
        let lo = pc.firstIndex { $0 >= 0 }!, hi = pc.lastIndex { $0 >= 0 }!
        stft.forEachFrame(x) { f, mag in
            // Spectral flatness (geometric / arithmetic mean of power) over the chroma band.
            var logSum: Double = 0, sum: Double = 0
            for k in lo...hi {
                let p = Double(mag[k] * mag[k]) + 1e-12
                logSum += log(p)
                sum += p
            }
            let count = Double(hi - lo + 1)
            if exp(logSum / count) / (sum / count) > 0.3 { return }
            var c = [Float](repeating: 0, count: 12)
            for k in 1..<mag.count where pc[k] >= 0 { c[pc[k]] += mag[k] * mag[k] }
            let total = c.reduce(0, +)
            if total > 1e-6 { for i in 0..<12 { c[i] = sqrt(c[i] / total) } }
            out[f] = c
        }
        return out
    }

    /// Frame energy, for silence gating.
    public static func energy(_ x: [Float], sampleRate: Double = AudioLoader.sampleRate) -> [Float] {
        let n = x.count / hop
        return (0..<n).map { i in
            var e: Float = 0
            x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + i * hop, 1, &e, vDSP_Length(min(hop, x.count - i * hop))) }
            return e
        }
    }
}
