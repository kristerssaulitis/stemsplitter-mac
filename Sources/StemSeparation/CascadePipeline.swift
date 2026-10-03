import Foundation

/// Two-stage split, the MVSEP production recipe: a vocals model pulls the vocals, then the
/// 4-stem model splits the instrumental residual into drums/bass/other (its own vocals
/// head sees an instrumental and stays near-silent, so it is omitted). `.two` stops after
/// stage 1 — the Mel-Band RoFormer is a native vocals/instrumental model.
///
/// Stage 2 runs as a second streaming pass over the residual WAV, so both stages keep the
/// overlap-add quality of a full-file pass; memory stays O(segment) per stage.
public final class CascadePipeline {
    private let vocals: MultiStemSeparator    // sources: [vocals, instrumental]
    private let residual: MultiStemSeparator  // sources: e.g. htdemucs's [drums, bass, other, vocals]
    /// Stage-1 share of reported progress, measured on M3 Max GPU: 2-stem pass ≈ 47.6 s
    /// vs 62.2 s for the full cascade on the same song.
    static let stageOneWeight = 0.77

    public init(vocals: MultiStemSeparator, residual: MultiStemSeparator) {
        self.vocals = vocals
        self.residual = residual
    }

    public func run(_ request: SplitRequest, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SplitResult {
        guard request.layout == .four else {
            return try await SplitPipeline(separator: vocals).run(request, progress: progress)
        }
        let started = Date()
        let stage1 = request.outputDirectory.appendingPathComponent("stage1", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage1) }
        do {
            let first = SplitRequest(source: request.source, outputDirectory: stage1, range: request.range, layout: .two)
            _ = try await SplitPipeline(separator: vocals).run(first) { p in progress(Self.stageOneWeight * p) }

            // Keep the roformer vocals; its instrumental becomes stage 2's input.
            try? FileManager.default.removeItem(at: request.outputDirectory.appendingPathComponent("vocals.wav"))
            try? FileManager.default.removeItem(at: SplitPipeline.peaksURL(request.outputDirectory, "vocals"))
            try FileManager.default.moveItem(at: stage1.appendingPathComponent("vocals.wav"),
                                             to: request.outputDirectory.appendingPathComponent("vocals.wav"))
            try FileManager.default.moveItem(at: SplitPipeline.peaksURL(stage1, "vocals"),
                                             to: SplitPipeline.peaksURL(request.outputDirectory, "vocals"))

            let second = SplitRequest(source: stage1.appendingPathComponent("instrumental.wav"),
                                      outputDirectory: request.outputDirectory, layout: .four,
                                      omitStems: ["vocals"])
            let two = try await SplitPipeline(separator: residual).run(second) { p in
                progress(Self.stageOneWeight + (1 - Self.stageOneWeight) * p)
            }
            var stems = two.stems
            stems.append(("vocals", request.outputDirectory.appendingPathComponent("vocals.wav")))
            return SplitResult(stems: stems, frames: two.frames, elapsed: Date().timeIntervalSince(started))
        } catch {
            // The vocals moved out of stage1 is partial output too.
            try? FileManager.default.removeItem(at: request.outputDirectory.appendingPathComponent("vocals.wav"))
            try? FileManager.default.removeItem(at: SplitPipeline.peaksURL(request.outputDirectory, "vocals"))
            throw error
        }
    }
}
