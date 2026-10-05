import Accelerate
import CoreML
import Foundation

/// Fixed-length segment in, N stereo waveforms out. Exists so `SplitPipeline` can be tested
/// without a 100 MB model (see `PassthroughSeparator` in tests).
public protocol MultiStemSeparator: AnyObject {
    /// Source names in output order, e.g. ["drums", "bass", "other", "vocals"].
    var sources: [String] { get }
    /// Samples per channel the model consumes per call.
    var segmentLength: Int { get }
    /// `segment`: planar stereo `[L..., R...]`, `2 * segmentLength` floats.
    /// Returns planar `[source][channel][sample]`, `sources.count * 2 * segmentLength` floats.
    func separate(_ segment: [Float]) throws -> [Float]
}

public enum SeparatorError: Error, LocalizedError {
    case modelMissing(String)
    case badModel(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let p): "Separation model not found at \(p). Run tools/convert_htdemucs.py / convert_melband.py."
        case .badModel(let m): "Separation model is not usable: \(m)"
        }
    }
}

/// htdemucs core converted by tools/convert_htdemucs.py. STFT/iSTFT happen here.
public final class HTDemucsSeparator: MultiStemSeparator {
    public let sources: [String]
    public let segmentLength: Int
    private let model: MLModel
    private let stft = DemucsSTFT()
    private let frames: Int

    /// `url`: compiled `.mlmodelc`. GPU is the fast path on Mac: the ANE compiler rejects this graph.
    public init(modelURL url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw SeparatorError.modelMissing(url.path) }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: url, configuration: config)
        let meta = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        guard let names = meta["sources"], let seg = meta["segment_samples"].flatMap(Int.init) else {
            throw SeparatorError.badModel("missing sources/segment_samples metadata")
        }
        sources = names.split(separator: ",").map(String.init)
        segmentLength = seg
        frames = DemucsSTFT.frameCount(seg)
    }

    public func separate(_ segment: [Float]) throws -> [Float] {
        let L = segmentLength, T = frames, B = DemucsSTFT.bins, S = sources.count
        precondition(segment.count == 2 * L)

        let plane = B * T
        var cac = [Float](repeating: 0, count: 4 * plane)
        segment.withUnsafeBufferPointer { seg in
            cac.withUnsafeMutableBufferPointer { c in
                for ch in 0..<2 {
                    let x = UnsafeBufferPointer(rebasing: seg[(ch * L)..<((ch + 1) * L)])
                    stft.forward(x, re: c.baseAddress! + (2 * ch) * plane, im: c.baseAddress! + (2 * ch + 1) * plane)
                }
            }
        }
        let mix = MLMultiArray(MLShapedArray(scalars: segment, shape: [1, 2, L]))
        let spec = MLMultiArray(MLShapedArray(scalars: cac, shape: [1, 4, B, T]))

        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mix": mix, "spec": spec]))
        guard let freq = out.featureValue(for: "freq")?.multiArrayValue,
              let time = out.featureValue(for: "time")?.multiArrayValue else {
            throw SeparatorError.badModel("missing freq/time outputs")
        }
        // time: (1, S*2, L) → result directly; freq: (1, S*4, B, T) → iSTFT added on top.
        // NB: MLShapedArray.count is unreliable after converting: — check shape instead.
        let timeArray = MLShapedArray<Float>(converting: time)
        guard timeArray.shape == [1, S * 2, L] else {
            throw SeparatorError.badModel("unexpected time output shape \(time.shape)")
        }
        var result = Array(timeArray.scalars)
        let freqArray = MLShapedArray<Float>(converting: freq)
        guard freqArray.shape == [1, S * 4, B, T] else {
            throw SeparatorError.badModel("unexpected freq output shape \(freq.shape)")
        }
        let freqFlat = Array(freqArray.scalars)
        freqFlat.withUnsafeBufferPointer { f in
            result.withUnsafeMutableBufferPointer { r in
                for s in 0..<S {
                    for ch in 0..<2 {
                        let base = f.baseAddress! + (s * 4 + ch * 2) * plane
                        stft.inverseAdd(re: base, im: base + plane, frames: T,
                                        into: r.baseAddress! + (s * 2 + ch) * L, length: L)
                    }
                }
            }
        }
        return result
    }
}
