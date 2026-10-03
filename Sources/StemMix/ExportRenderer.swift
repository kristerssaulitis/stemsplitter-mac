import AVFoundation

public struct ExportFormat: Codable, Equatable, Sendable {
    public enum Container: String, Codable, CaseIterable, Sendable { case wav, aiff, flac }
    public enum Depth: Int, Codable, CaseIterable, Sendable { case int16 = 16, int24 = 24, float32 = 32 }

    public var container: Container = .wav
    /// nil = match the source file's original rate.
    public var sampleRate: Double? = nil
    public var depth: Depth = .int24

    public init(container: Container = .wav, sampleRate: Double? = nil, depth: Depth = .int24) {
        self.container = container
        self.sampleRate = sampleRate
        self.depth = depth
    }

    public var fileExtension: String { container == .aiff ? "aif" : container.rawValue }

    func settings(sampleRate: Double) -> [String: Any] {
        var s: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2]
        switch container {
        case .flac:
            s[AVFormatIDKey] = kAudioFormatFLAC
            s[AVEncoderBitDepthHintKey] = depth == .int16 ? 16 : 24  // FLAC has no float
        case .wav, .aiff:
            s[AVFormatIDKey] = kAudioFormatLinearPCM
            s[AVLinearPCMBitDepthKey] = depth.rawValue
            s[AVLinearPCMIsFloatKey] = depth == .float32
            s[AVLinearPCMIsBigEndianKey] = container == .aiff
            s[AVLinearPCMIsNonInterleaved] = false
        }
        return s
    }
}

public enum ExportRenderer {
    /// Renders through a fresh graph (playback is untouched). `only` = one stem, nil = full mixdown.
    /// Partial files are deleted on failure or cancel.
    public static func render(stems: [(name: String, url: URL)], settings: MixSettings, bpm: Double?,
                              only: String?, range: ClosedRange<Double>?, format: ExportFormat,
                              sourceSampleRate: Double?, to url: URL,
                              progress: (Double) -> Void = { _ in }) throws {
        let graph = try MixGraph(stems: stems, settings: settings, bpm: bpm)
        let rate = format.sampleRate ?? sourceSampleRate ?? graph.format.sampleRate
        let r = range ?? 0...graph.duration
        try? FileManager.default.removeItem(at: url)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings(sampleRate: rate),
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try graph.renderOffline(range: r, only: only, sampleRate: rate, write: { try file.write(from: $0) }, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error is CancellationError ? error : MixError.render(error.localizedDescription)
        }
    }

    /// Source video + new audio track → .mov. Video is passed through (no re-encode); audio stays LPCM.
    public static func replaceAudio(video: URL, audio: URL, range: ClosedRange<Double>?, to url: URL) async throws {
        let comp = AVMutableComposition()
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        guard let vt = try await v.loadTracks(withMediaType: .video).first,
              let at = try await a.loadTracks(withMediaType: .audio).first else {
            throw MixError.render("source has no video track")
        }
        let start = CMTime(seconds: range?.lowerBound ?? 0, preferredTimescale: 600)
        let audioDuration = try await a.load(.duration)
        let videoDuration = try await v.load(.duration)
        let len = CMTimeMinimum(audioDuration, CMTimeSubtract(videoDuration, start))
        let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try cv.insertTimeRange(CMTimeRange(start: start, duration: len), of: vt, at: .zero)
        cv.preferredTransform = try await vt.load(.preferredTransform)
        let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: len), of: at, at: .zero)

        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw MixError.render("no export session")
        }
        do {
            try await session.export(to: url, as: .mov)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw MixError.render(error.localizedDescription)
        }
    }
}
