import Accelerate
import AVFoundation

public enum SplitError: Error, LocalizedError, Equatable {
    case noAudio
    case unreadable
    case cancelled
    case write(String)

    public var errorDescription: String? {
        switch self {
        case .noAudio: "No audio track found in this file."
        case .unreadable: "This file can't be read as audio or video."
        case .cancelled: "Cancelled."
        case .write(let m): "Couldn't write stems: \(m)"
        }
    }
}

/// Any AVFoundation-readable file (audio or video) → planar stereo Float32 at 44.1 kHz.
/// AVAssetReader does the resample and mono→stereo upmix.
/// ponytail: duplicates ../stemsplitter StemCore.AudioExtractor (~60 lines) so this build doesn't
/// break whenever the iOS repo is mid-edit. Re-unify once both apps share one package.
public final class AudioDecoder {
    public let duration: Double
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    public init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration).seconds
        } catch {
            throw SplitError.unreadable
        }
        guard let track = tracks.first else { throw SplitError.noAudio }
        do { reader = try AVAssetReader(asset: asset) } catch { throw SplitError.unreadable }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw SplitError.unreadable }
    }

    /// Next block as (left, right), or nil at end of file.
    public func next() throws -> (l: [Float], r: [Float])? {
        while true {
            guard let sb = output.copyNextSampleBuffer() else {
                if reader.status == .failed { throw SplitError.unreadable }
                return nil
            }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let n = bytes / 8
            if n == 0 { continue }
            var interleaved = [Float](repeating: 0, count: 2 * n)
            let status = interleaved.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
            }
            guard status == noErr else { throw SplitError.unreadable }
            var l = [Float](repeating: 0, count: n), r = l
            interleaved.withUnsafeBufferPointer { p in
                var z: Float = 0
                vDSP_vsadd(p.baseAddress!, 2, &z, &l, 1, vDSP_Length(n))
                vDSP_vsadd(p.baseAddress! + 1, 2, &z, &r, 1, vDSP_Length(n))
            }
            return (l, r)
        }
    }

    public func cancel() { reader.cancelReading() }
}

/// Streaming 24-bit stereo WAV via AVAudioFile, fed planar Float32.
final class StemWriter {
    let url: URL
    private var file: AVAudioFile?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!

    init(url: URL) throws {
        self.url = url
        do {
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw SplitError.write(error.localizedDescription)
        }
    }

    func append(l: [Float], r: [Float]) throws {
        guard let file, !l.isEmpty else { return }
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(l.count))!
        buf.frameLength = AVAudioFrameCount(l.count)
        buf.floatChannelData![0].update(from: l, count: l.count)
        buf.floatChannelData![1].update(from: r, count: r.count)
        do { try file.write(from: buf) } catch { throw SplitError.write(error.localizedDescription) }
    }

    func finalize() { file = nil }  // AVAudioFile patches the header on close

    func abortAndDelete() {
        file = nil
        try? FileManager.default.removeItem(at: url)
    }
}
