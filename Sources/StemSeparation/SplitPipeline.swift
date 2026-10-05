import Accelerate
import Foundation

public enum StemLayout: String, Codable, Sendable, CaseIterable {
    case four  // drums, bass, other, vocals
    case two   // vocals, instrumental
}

public struct SplitRequest: Sendable {
    public var source: URL
    public var outputDirectory: URL
    /// Seconds into the source. `nil` = whole file.
    public var range: ClosedRange<Double>?
    public var layout: StemLayout
    /// Sources to skip writing (`.four` only): the cascade's residual split drops htdemucs's
    /// own vocals head, near-silent on an instrumental.
    public var omitStems: Set<String>

    public init(source: URL, outputDirectory: URL, range: ClosedRange<Double>? = nil, layout: StemLayout = .four,
                omitStems: Set<String> = []) {
        self.source = source
        self.outputDirectory = outputDirectory
        self.range = range
        self.layout = layout
        self.omitStems = omitStems
    }
}

public struct SplitResult: Sendable {
    /// Stem name → 24-bit 44.1 kHz stereo WAV.
    public var stems: [(name: String, url: URL)]
    public var frames: Int
    public var elapsed: TimeInterval
    public var duration: Double { Double(frames) / SplitPipeline.sampleRate }
}

/// Decode → overlapping segments → model → triangle-weighted overlap-add → WAV.
/// Streams: memory is O(segment), not O(song).
public final class SplitPipeline {
    public static let sampleRate = 44_100.0
    /// Waveform peaks per second written beside each stem as `peaks-<stem>.f32`.
    public static let peaksPerSecond = 50
    public static let overlap = 0.25

    private let separator: MultiStemSeparator

    public init(separator: MultiStemSeparator) {
        self.separator = separator
    }

    public static func stemNames(_ layout: StemLayout, sources: [String]) -> [String] {
        layout == .four ? sources : ["vocals", "instrumental"]
    }

    /// `progress` gets 0...1. Cancellation (Task.cancel) deletes partial output and throws `SplitError.cancelled`.
    public func run(_ request: SplitRequest, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SplitResult {
        let started = Date()
        let L = separator.segmentLength
        let stride = Int(Double(L) * (1 - Self.overlap))
        let S = separator.sources.count
        let decoder = try await AudioDecoder(url: request.source)
        defer { decoder.cancel() }

        let sr = Self.sampleRate
        let skip = Int((request.range?.lowerBound ?? 0) * sr)
        let wanted = request.range.map { Int(($0.upperBound - $0.lowerBound) * sr) } ?? Int.max
        let expected = max(1, min(wanted, Int(decoder.duration * sr) - skip))

        let names = Self.stemNames(request.layout, sources: separator.sources).filter { !request.omitStems.contains($0) }
        guard !names.isEmpty else { throw SplitError.write("all stems omitted") }
        guard request.layout == .four || separator.sources.contains("vocals") else {
            throw SplitError.write("two-stem mode needs a vocals source")
        }
        let vocalsIndex = separator.sources.firstIndex(of: "vocals") ?? 0
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let urls = names.map { request.outputDirectory.appendingPathComponent("\($0).wav") }
        var writers: [StemWriter] = []
        do {
            for u in urls { writers.append(try StemWriter(url: u)) }
        } catch {
            writers.forEach { $0.abortAndDelete() }
            throw error
        }
        let peaks = names.map { _ in PeakAccumulator(binSize: Int(sr) / Self.peaksPerSecond) }

        // Triangle weights, as demucs `apply_model`.
        var weight = [Float](repeating: 0, count: L)
        for i in 0..<L { weight[i] = Float(i < L / 2 ? i + 1 : L - i) }
        var maxW = weight.max()!
        vDSP_vsdiv(weight, 1, &maxW, &weight, 1, vDSP_Length(L))

        var bufL: [Float] = [], bufR: [Float] = []
        var bufStart = 0      // absolute (post-trim) index of bufL[0]
        var consumed = 0      // decoded samples seen, pre-trim
        var eof = false
        var acc = [Float](repeating: 0, count: S * 2 * L)
        var wsum = [Float](repeating: 0, count: L)
        var emitted = 0

        func fail(_ e: Error) -> Error {
            writers.forEach { $0.abortAndDelete() }
            for n in names { try? FileManager.default.removeItem(at: Self.peaksURL(request.outputDirectory, n)) }
            if e is CancellationError { return SplitError.cancelled }
            return e
        }

        do {
            var seg = 0
            while true {
                try Task.checkCancellation()
                let segStart = seg * stride
                while !eof && bufStart + bufL.count < segStart + L {
                    guard let block = try decoder.next() else { eof = true; break }
                    let n = block.l.count
                    let from = max(0, skip - consumed)
                    consumed += n
                    guard from < n else { continue }
                    let take = min(n - from, wanted - (bufStart + bufL.count))
                    if take <= 0 { eof = true; break }
                    bufL.append(contentsOf: block.l[from..<(from + take)])
                    bufR.append(contentsOf: block.r[from..<(from + take)])
                }
                let total = bufStart + bufL.count
                let available = min(L, total - segStart)
                if available <= 0 {
                    if seg == 0 { throw SplitError.noAudio }
                    break
                }

                var input = [Float](repeating: 0, count: 2 * L)
                let o = segStart - bufStart
                input.replaceSubrange(0..<available, with: bufL[o..<(o + available)])
                input.replaceSubrange(L..<(L + available), with: bufR[o..<(o + available)])
                let out = try separator.separate(input)

                for k in 0..<(S * 2) {
                    out.withUnsafeBufferPointer { op in
                        acc.withUnsafeMutableBufferPointer { ap in
                            vDSP_vma(op.baseAddress! + k * L, 1, weight, 1, ap.baseAddress! + k * L, 1,
                                     ap.baseAddress! + k * L, 1, vDSP_Length(L))
                        }
                    }
                }
                vDSP_vadd(wsum, 1, weight, 1, &wsum, 1, vDSP_Length(L))

                let isLast = eof && segStart + L >= total
                let final = isLast ? total - segStart : stride
                try emit(acc: acc, wsum: wsum, count: final, L: L, S: S, layout: request.layout,
                         vocalsIndex: vocalsIndex, writers: writers, peaks: peaks, omit: request.omitStems)
                emitted += final
                progress(min(1, Double(emitted) / Double(expected)))
                if isLast { break }

                for k in 0..<(S * 2) {
                    acc.withUnsafeMutableBufferPointer { ap in
                        let b = ap.baseAddress! + k * L
                        b.update(from: b + stride, count: L - stride)
                        (b + L - stride).update(repeating: 0, count: stride)
                    }
                }
                wsum.withUnsafeMutableBufferPointer { w in
                    w.baseAddress!.update(from: w.baseAddress! + stride, count: L - stride)
                    (w.baseAddress! + L - stride).update(repeating: 0, count: stride)
                }
                let drop = min(stride, bufL.count)
                bufL.removeFirst(drop)
                bufR.removeFirst(drop)
                bufStart += drop
                seg += 1
            }
            writers.forEach { $0.finalize() }
            for (i, n) in names.enumerated() {
                try peaks[i].finish().withUnsafeBufferPointer { Data(buffer: $0) }
                    .write(to: Self.peaksURL(request.outputDirectory, n))
            }
        } catch {
            throw fail(error)
        }
        return SplitResult(stems: Array(zip(names, urls)).map { ($0.0, $0.1) }, frames: emitted,
                           elapsed: Date().timeIntervalSince(started))
    }

    public static func peaksURL(_ dir: URL, _ stem: String) -> URL {
        dir.appendingPathComponent("peaks-\(stem).f32")
    }

    private func emit(acc: [Float], wsum: [Float], count: Int, L: Int, S: Int, layout: StemLayout,
                      vocalsIndex: Int, writers: [StemWriter], peaks: [PeakAccumulator], omit: Set<String>) throws {
        var inv = [Float](repeating: 0, count: count)
        var one: Float = 1
        vDSP_svdiv(&one, wsum, 1, &inv, 1, vDSP_Length(count))
        func channel(_ s: Int, _ c: Int) -> [Float] {
            var r = [Float](repeating: 0, count: count)
            acc.withUnsafeBufferPointer { a in
                vDSP_vmul(a.baseAddress! + (s * 2 + c) * L, 1, inv, 1, &r, 1, vDSP_Length(count))
            }
            return r
        }
        var outputs: [[[Float]]]  // [stem][channel][sample], aligned with `writers`
        switch layout {
        case .four:
            outputs = (0..<S).filter { !omit.contains(separator.sources[$0]) }.map { s in [channel(s, 0), channel(s, 1)] }
        case .two:
            let vocals = [channel(vocalsIndex, 0), channel(vocalsIndex, 1)]
            var inst = [[Float](repeating: 0, count: count), [Float](repeating: 0, count: count)]
            for s in 0..<S where s != vocalsIndex {
                for c in 0..<2 { vDSP_vadd(inst[c], 1, channel(s, c), 1, &inst[c], 1, vDSP_Length(count)) }
            }
            outputs = [vocals, inst]
        }
        for (i, stem) in outputs.enumerated() {
            try writers[i].append(l: stem[0], r: stem[1])
            peaks[i].add(left: stem[0], right: stem[1])
        }
    }
}

/// Max |sample| per bin, mono. Carries partial bins across calls.
final class PeakAccumulator {
    let binSize: Int
    private var peaks: [Float] = []
    private var current: Float = 0
    private var filled = 0

    init(binSize: Int) { self.binSize = binSize }

    func add(left: [Float], right: [Float]) {
        var i = 0
        while i < left.count {
            let n = min(binSize - filled, left.count - i)
            var a: Float = 0, b: Float = 0
            left.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress! + i, 1, &a, vDSP_Length(n)) }
            right.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress! + i, 1, &b, vDSP_Length(n)) }
            current = max(current, a, b)
            filled += n
            i += n
            if filled == binSize {
                peaks.append(current)
                current = 0
                filled = 0
            }
        }
    }

    func finish() -> [Float] {
        if filled > 0 { peaks.append(current) }
        return peaks
    }
}
