import Accelerate
import AVFoundation

/// Reversed clips read a pre-rendered backwards copy of the stem,
/// so playback and export never reverse in real time.
public enum StemEdit {
    /// `.rev-vocals.wav` beside `vocals.wav`. Shared by every clip and duplicate of that file.
    public static func reversedURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".rev-" + url.lastPathComponent)
    }

    /// Streams `src` backwards into a 24-bit WAV at `dst`. Memory is O(chunk).
    public static func writeReversed(from src: URL, to dst: URL) throws {
        let file = try AVAudioFile(forReading: src)
        let fmt = file.processingFormat, len = file.length
        let out = try AVAudioFile(forWriting: dst, settings: wavSettings(fmt), commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: Int64 = 65_536
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk))!
        var pending = len
        while pending > 0 {
            let n = min(chunk, pending)
            file.framePosition = pending - n
            try file.read(into: buf, frameCount: AVAudioFrameCount(n))
            for c in 0..<Int(fmt.channelCount) { vDSP_vrvrs(buf.floatChannelData![c], 1, vDSP_Length(buf.frameLength)) }
            try out.write(from: buf)
            pending -= n
        }
    }

    /// Same 24-bit format as split stems.
    public static func wavSettings(_ fmt: AVAudioFormat) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate,
         AVNumberOfChannelsKey: fmt.channelCount, AVLinearPCMBitDepthKey: 24,
         AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    }
}
