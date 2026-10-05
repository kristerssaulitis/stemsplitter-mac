import Accelerate

/// Mel-Band RoFormer STFT/iSTFT: unnormalized, center=True with reflect padding. All bins
/// kept (DC and Nyquist are real: im = 0). Unlike `DemucsSTFT`, hop does not divide the
/// window, so the inverse normalizes each sample by the actual summed window² (what
/// torch.istft does) instead of a constant.
///
/// Frame `f` covers padded samples `f*hop ..< f*hop+nfft`, the input reflect-padded by
/// nfft/2 on both sides.
public final class MelBandSTFT {
    public static let nfft = 2048
    public static let hop = 441
    public static let bins = 1025
    static let leftPad = nfft / 2

    private let window: [Float]
    private let windowOLA: [Float]  // window / nfft, for the inverse's output scaling
    private let windowSq: [Float]
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    // Scratch, reused across frames.
    private var evens = [Float](repeating: 0, count: nfft / 2)
    private var odds = [Float](repeating: 0, count: nfft / 2)
    private var outR = [Float](repeating: 0, count: nfft / 2)
    private var outI = [Float](repeating: 0, count: nfft / 2)
    private var frame = [Float](repeating: 0, count: nfft)
    // Frame-major [frame][bin] staging; the model wants [bin][frame]. One vDSP_mtrans beats strided access.
    private var stageR: [Float] = []
    private var stageI: [Float] = []
    // Inverse OLA scratch over the padded domain.
    private var ola: [Float] = []
    private var wsum: [Float] = []

    public init() {
        let n = Self.nfft
        window = (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n)) }  // periodic
        let inv = 1 / Float(n)  // vDSP inverse = n·irfft
        windowOLA = window.map { $0 * inv }
        windowSq = window.map { $0 * $0 }
        forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        inverse = vDSP_DFT_zrop_CreateSetup(forward, vDSP_Length(n), .INVERSE)!
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    public static func frameCount(_ length: Int) -> Int { length / hop + 1 }

    /// Reflect-padded read (torch "reflect": edge sample not repeated).
    @inline(__always)
    static func reflect(_ i: Int, _ length: Int) -> Int {
        var i = i
        if i < 0 { i = -i }
        if i >= length { i = 2 * (length - 1) - i }
        return i
    }

    /// One channel → re/im planes, `[bin][frame]`, `bins * frames` floats each.
    /// Unnormalized DFT: vDSP forward = 2·DFT, hence the 0.5.
    public func forward(_ x: UnsafeBufferPointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        let n = Self.nfft, half = n / 2, frames = Self.frameCount(x.count)
        var halfScale: Float = 0.5
        let B = Self.bins
        if stageR.count < frames * B {
            stageR = [Float](repeating: 0, count: frames * B)
            stageI = stageR
        }
        for f in 0..<frames {
            let start = f * Self.hop - Self.leftPad
            if start >= 0 && start + n <= x.count {
                vDSP_vmul(x.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))
            } else {
                for k in 0..<n { frame[k] = x[Self.reflect(start + k, x.count)] * window[k] }
            }
            frame.withUnsafeBufferPointer { fr in
                var z: Float = 0
                vDSP_vsadd(fr.baseAddress!, 2, &z, &evens, 1, vDSP_Length(half))
                vDSP_vsadd(fr.baseAddress! + 1, 2, &z, &odds, 1, vDSP_Length(half))
            }
            vDSP_DFT_Execute(forward, evens, odds, &outR, &outI)
            let o = f * B
            stageR.withUnsafeMutableBufferPointer { s in
                vDSP_vsmul(outR, 1, &halfScale, s.baseAddress! + o, 1, vDSP_Length(half))
                s[o + B - 1] = outI[0] * halfScale                                        // Nyquist, real
            }
            stageI.withUnsafeMutableBufferPointer { s in
                outI.withUnsafeBufferPointer { oi in
                    vDSP_vsmul(oi.baseAddress! + 1, 1, &halfScale, s.baseAddress! + o + 1, 1, vDSP_Length(half - 1))
                }
                s[o] = 0
                s[o + B - 1] = 0
            }
        }
        vDSP_mtrans(stageR, 1, re, 1, vDSP_Length(B), vDSP_Length(frames))
        vDSP_mtrans(stageI, 1, im, 1, vDSP_Length(B), vDSP_Length(frames))
    }

    /// re/im planes → one channel of `length` samples, written into `out` (overwrites).
    /// torch.istft: OLA of windowed irfft frames, divided by the summed window², cropped
    /// to the center.
    public func inverse(re: UnsafePointer<Float>, im: UnsafePointer<Float>, frames: Int,
                        into out: UnsafeMutablePointer<Float>, length: Int) {
        let n = Self.nfft, half = n / 2
        let B = Self.bins, pad = Self.leftPad
        if stageR.count < frames * B {
            stageR = [Float](repeating: 0, count: frames * B)
            stageI = stageR
        }
        if ola.count < length + 2 * pad {
            ola = [Float](repeating: 0, count: length + 2 * pad)
            wsum = ola
        }
        ola.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(length + 2 * pad)) }
        wsum.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(length + 2 * pad)) }

        vDSP_mtrans(re, 1, &stageR, 1, vDSP_Length(frames), vDSP_Length(B))
        vDSP_mtrans(im, 1, &stageI, 1, vDSP_Length(frames), vDSP_Length(B))
        for f in 0..<frames {
            stageR.withUnsafeBufferPointer { s in outR.withUnsafeMutableBufferPointer {
                $0.baseAddress!.update(from: s.baseAddress! + f * B, count: half) } }
            stageI.withUnsafeBufferPointer { s in outI.withUnsafeMutableBufferPointer {
                $0.baseAddress!.update(from: s.baseAddress! + f * B, count: half) } }
            // DC imaginary must be 0 for the halfcomplex layout.
            outI[0] = 0
            vDSP_DFT_Execute(inverse, outR, outI, &evens, &odds)
            frame.withUnsafeMutableBufferPointer { fr in
                var z: Float = 0
                vDSP_vsadd(evens, 1, &z, fr.baseAddress!, 2, vDSP_Length(half))
                vDSP_vsadd(odds, 1, &z, fr.baseAddress! + 1, 2, vDSP_Length(half))
            }
            let start = f * Self.hop  // in the padded domain
            frame.withUnsafeBufferPointer { fr in
                ola.withUnsafeMutableBufferPointer { o in
                    vDSP_vma(fr.baseAddress!, 1, windowOLA, 1, o.baseAddress! + start, 1,
                             o.baseAddress! + start, 1, vDSP_Length(n))
                }
                wsum.withUnsafeMutableBufferPointer { w in
                    windowSq.withUnsafeBufferPointer { sq in
                        vDSP_vma(sq.baseAddress!, 1, sq.baseAddress!, 1, w.baseAddress! + start, 1,
                                 w.baseAddress! + start, 1, vDSP_Length(n))
                    }
                }
            }
        }
        // out = ola / max(wsum, 1e-8) on the cropped region. Where wsum is tiny torch
        // yields 0; the crop starts at `pad`, where wsum = window[pad]² = 1, so a plain
        // clamp matches.
        var floor: Float = 1e-8
        wsum.withUnsafeMutableBufferPointer { w in
            vDSP_vthr(w.baseAddress! + pad, 1, &floor, w.baseAddress! + pad, 1, vDSP_Length(length))
        }
        ola.withUnsafeBufferPointer { o in wsum.withUnsafeBufferPointer { w in
            vDSP_vdiv(w.baseAddress! + pad, 1, o.baseAddress! + pad, 1, out, 1, vDSP_Length(length))
        } }
    }
}
