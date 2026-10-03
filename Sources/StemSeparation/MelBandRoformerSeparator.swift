import Accelerate
import CoreML
import Foundation

/// Mel-Band RoFormer vocals core (KimberleyJSN weights, MIT) converted by
/// tools/convert_melband.py. The Core ML graph is everything between the STFT and the
/// band scatter: it estimates a complex mask per mel-band entry. Here: STFT, scatter-
/// average the entries onto the (freq × channel) grid, complex-multiply the mix
/// spectrogram, zero DC, iSTFT. `instrumental` is the mix minus the vocals, so the two
/// outputs always sum back to the input exactly.
public final class MelBandRoformerSeparator: MultiStemSeparator {
    public let sources = ["vocals", "instrumental"]
    public let segmentLength: Int
    private let model: MLModel
    private let stft = MelBandSTFT()
    private let bins: Int
    private let frames: Int
    private let entries: Int
    /// Entry indices bucketed by grid slot j = freq*2 + channel (CSR layout).
    private let entryStart: [Int]  // 2*bins + 1 prefix sums
    private let entryIdx: [Int]    // entries
    private let bandsPerFreq: [Float]

    /// `url`: compiled `.mlmodelc`. GPU: the graph's attention runs there; like htdemucs,
    /// the ANE compiler rejects it.
    public init(modelURL url: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw SeparatorError.modelMissing(url.path) }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: config)
        let meta = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        func intMeta(_ key: String) throws -> Int {
            guard let v = meta[key].flatMap(Int.init) else { throw SeparatorError.badModel("missing \(key) metadata") }
            return v
        }
        segmentLength = try intMeta("segment_samples")
        bins = try intMeta("stft_bins")
        frames = try intMeta("frames")
        entries = try intMeta("entries")
        guard let hop = meta["stft_hop"].flatMap(Int.init), let nfft = meta["stft_nfft"].flatMap(Int.init),
              hop == MelBandSTFT.hop, nfft == MelBandSTFT.nfft, bins == MelBandSTFT.bins,
              frames == MelBandSTFT.frameCount(segmentLength),
              let bpf = meta["bands_per_freq_b64"].flatMap({ Data(base64Encoded: $0) }),
              let idx = meta["freq_indices_b64"].flatMap({ Data(base64Encoded: $0) }),
              bpf.count == bins * 4, idx.count == entries * 4 else {
            throw SeparatorError.badModel("STFT/band metadata does not match MelBandSTFT")
        }
        bandsPerFreq = bpf.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let freqIndices = idx.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)).map(Int.init) }
        var start = [Int](repeating: 0, count: 2 * bins + 1)
        for g in freqIndices { start[g + 1] += 1 }
        for j in 1...(2 * bins) { start[j] += start[j - 1] }
        entryStart = start
        var cursor = start
        var sorted = [Int](repeating: 0, count: entries)
        for (e, g) in freqIndices.enumerated() { sorted[cursor[g]] = e; cursor[g] += 1 }
        entryIdx = sorted
    }

    public func separate(_ segment: [Float]) throws -> [Float] {
        let L = segmentLength, T = frames, B = bins, E = entries
        precondition(segment.count == 2 * L)
        let plane = B * T

        let spec = try MLMultiArray(shape: [1, 4, NSNumber(value: B), NSNumber(value: T)], dataType: .float32)
        var cac = [Float](repeating: 0, count: 4 * plane)  // planes [L.re, L.im, R.re, R.im]
        segment.withUnsafeBufferPointer { seg in
            cac.withUnsafeMutableBufferPointer { c in
                for ch in 0..<2 {
                    let x = UnsafeBufferPointer(rebasing: seg[(ch * L)..<((ch + 1) * L)])
                    stft.forward(x, re: c.baseAddress! + (2 * ch) * plane, im: c.baseAddress! + (2 * ch + 1) * plane)
                }
            }
        }
        try spec.writeDense(cac)

        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["spec": spec]))
        guard let mask = out.featureValue(for: "mask")?.multiArrayValue else {
            throw SeparatorError.badModel("missing mask output")
        }
        let m = try mask.readDense(count: 2 * E * T)  // planes [re, im], each [entry][frame]

        // Per channel: scatter-average entry masks onto the grid, complex-multiply the mix
        // spec, zero DC, synthesize. Layout mirrors the model: grid slot f*2 + ch.
        var result = [Float](repeating: 0, count: 2 * 2 * L)  // [vocals L/R, instrumental L/R]
        var accRe = [Float](repeating: 0, count: T)
        var accIm = [Float](repeating: 0, count: T)
        var prod = [Float](repeating: 0, count: T)
        var maskedRe = [Float](repeating: 0, count: plane)
        var maskedIm = [Float](repeating: 0, count: plane)
        for ch in 0..<2 {
            maskedRe.withUnsafeMutableBufferPointer { mr in
                maskedIm.withUnsafeMutableBufferPointer { mi in
                    m.withUnsafeBufferPointer { mask in
                        cac.withUnsafeBufferPointer { spec in
                            let mRe = mask.baseAddress!, mIm = mask.baseAddress! + E * T
                            let sRe = spec.baseAddress! + (2 * ch) * plane, sIm = sRe + plane
                            for f in 0..<B {
                                let j = f * 2 + ch
                                accRe.withUnsafeMutableBufferPointer { ar in
                                    accIm.withUnsafeMutableBufferPointer { ai in
                                        ar.baseAddress!.update(repeating: 0, count: T)
                                        ai.baseAddress!.update(repeating: 0, count: T)
                                        for e in entryStart[j]..<entryStart[j + 1] {
                                            let o = entryIdx[e] * T
                                            vDSP_vadd(ar.baseAddress!, 1, mRe + o, 1, ar.baseAddress!, 1, vDSP_Length(T))
                                            vDSP_vadd(ai.baseAddress!, 1, mIm + o, 1, ai.baseAddress!, 1, vDSP_Length(T))
                                        }
                                        var denom = bandsPerFreq[f]
                                        vDSP_vsdiv(ar.baseAddress!, 1, &denom, ar.baseAddress!, 1, vDSP_Length(T))
                                        vDSP_vsdiv(ai.baseAddress!, 1, &denom, ai.baseAddress!, 1, vDSP_Length(T))
                                        // (mre + i·mim)(sre + i·sim)
                                        prod.withUnsafeMutableBufferPointer { p in
                                            vDSP_vmul(ai.baseAddress!, 1, sIm + f * T, 1, p.baseAddress!, 1, vDSP_Length(T))
                                            vDSP_vmsb(ar.baseAddress!, 1, sRe + f * T, 1, p.baseAddress!, 1,
                                                      mr.baseAddress! + f * T, 1, vDSP_Length(T))
                                            vDSP_vmul(ar.baseAddress!, 1, sIm + f * T, 1, p.baseAddress!, 1, vDSP_Length(T))
                                            vDSP_vma(ai.baseAddress!, 1, sRe + f * T, 1, p.baseAddress!, 1,
                                                     mi.baseAddress! + f * T, 1, vDSP_Length(T))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // zero_dc: bin 0 of both channels is zeroed before the iSTFT.
            maskedIm.withUnsafeMutableBufferPointer { mi in maskedRe.withUnsafeMutableBufferPointer { mr in
                mr.baseAddress![0] = 0
                mi.baseAddress![0] = 0
            } }
            maskedRe.withUnsafeBufferPointer { mr in
                maskedIm.withUnsafeBufferPointer { mi in
                    result.withUnsafeMutableBufferPointer { r in
                        stft.inverse(re: mr.baseAddress!, im: mi.baseAddress!, frames: T,
                                     into: r.baseAddress! + ch * L, length: L)
                    }
                }
            }
        }
        // instrumental = mix - vocals, per channel. vDSP_vsub's C = B - A (reversed!).
        result.withUnsafeMutableBufferPointer { r in
            segment.withUnsafeBufferPointer { s in
                for ch in 0..<2 {
                    vDSP_vsub(r.baseAddress! + ch * L, 1, s.baseAddress! + ch * L, 1,
                              r.baseAddress! + (2 + ch) * L, 1, vDSP_Length(L))
                }
            }
        }
        return result
    }
}
