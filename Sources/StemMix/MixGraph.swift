import Accelerate
import AVFoundation

public enum MixError: Error, LocalizedError {
    case engineStart(String)
    case render(String)

    public var errorDescription: String? {
        switch self {
        case .engineStart(let m): "Audio engine couldn't start: \(m)"
        case .render(let m): "Export failed: \(m)"
        }
    }
}

/// One builder for playback and offline export, so what you hear is what you export.
///
/// per stem:  Player → EQ → Delay → Reverb → StemMixer(vol, pan)
/// all stems → Bus → TimePitch(pitch, rate) → MasterEQ → main mixer → output
public final class MixGraph {
    public let engine = AVAudioEngine()
    public let names: [String]
    public let duration: Double
    let files: [String: AVAudioFile]
    private var reversedFiles: [String: AVAudioFile] = [:]
    let format: AVAudioFormat
    private var players: [String: AVAudioPlayerNode] = [:]
    private var eqs: [String: AVAudioUnitEQ] = [:]
    private var delays: [String: AVAudioUnitDelay] = [:]
    private var reverbs: [String: AVAudioUnitReverb] = [:]
    private var mixers: [String: AVAudioMixerNode] = [:]
    private var rooms: [String: ReverbSettings.Room] = [:]  // loadFactoryPreset resets state: only on change
    private let bus = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let masterEQ = AVAudioUnitEQ(numberOfBands: 3)
    public private(set) var settings: MixSettings
    public var bpm: Double?
    private var startTime: Double = 0
    private var loop: ClosedRange<Double>?
    public private(set) var isPlaying = false

    public init(stems: [(name: String, url: URL)], settings: MixSettings = MixSettings(), bpm: Double? = nil) throws {
        names = stems.map(\.name)
        var files: [String: AVAudioFile] = [:]
        for s in stems { files[s.name] = try AVAudioFile(forReading: s.url) }
        self.files = files
        let first = files[names[0]]!
        format = first.processingFormat
        duration = Double(first.length) / format.sampleRate
        self.settings = settings
        self.bpm = bpm

        engine.attach(bus)
        engine.attach(timePitch)
        engine.attach(masterEQ)
        for name in names {
            let p = AVAudioPlayerNode(), eq = AVAudioUnitEQ(numberOfBands: 3)
            let d = AVAudioUnitDelay(), r = AVAudioUnitReverb(), m = AVAudioMixerNode()
            [p, eq, d, r, m].forEach { engine.attach($0) }
            engine.connect(p, to: eq, format: format)
            engine.connect(eq, to: d, format: format)
            engine.connect(d, to: r, format: format)
            engine.connect(r, to: m, format: format)
            engine.connect(m, to: bus, format: format)
            players[name] = p; eqs[name] = eq; delays[name] = d; reverbs[name] = r; mixers[name] = m
            Self.configureBands(eq)
        }
        engine.connect(bus, to: timePitch, format: format)
        engine.connect(timePitch, to: masterEQ, format: format)
        engine.connect(masterEQ, to: engine.mainMixerNode, format: format)
        Self.configureBands(masterEQ)
        apply(settings)
    }

    static func configureBands(_ eq: AVAudioUnitEQ) {
        let b = eq.bands
        b[0].filterType = .lowShelf; b[0].frequency = 120
        b[1].filterType = .parametric; b[1].frequency = 1000; b[1].bandwidth = 1.5
        b[2].filterType = .highShelf; b[2].frequency = 6000
        b.forEach { $0.bypass = false; $0.gain = 0 }
    }

    static func set(_ eq: AVAudioUnitEQ, _ s: EQSettings) {
        eq.bands[0].gain = Float(s.low)
        eq.bands[1].gain = Float(s.mid)
        eq.bands[2].gain = Float(s.high)
        eq.bypass = s.isFlat
    }

    static func preset(_ room: ReverbSettings.Room) -> AVAudioUnitReverbPreset {
        switch room {
        case .room: .mediumRoom
        case .plate: .plate
        case .hall: .largeHall
        case .cathedral: .cathedral
        }
    }

    /// Safe while playing.
    public func apply(_ s: MixSettings) {
        let tempoChanged = s.tempo != settings.tempo
        let clipsChanged = names.contains { s[$0].clips != settings[$0].clips }
        settings = s
        for name in names {
            let st = s[name]
            Self.set(eqs[name]!, st.eq)
            let d = delays[name]!
            d.delayTime = st.delay.seconds(bpm: bpm)
            d.feedback = Float(st.delay.feedback)
            d.wetDryMix = Float(st.delay.mix)
            d.bypass = !st.delay.enabled
            let r = reverbs[name]!
            if rooms[name] != st.reverb.room {
                r.loadFactoryPreset(Self.preset(st.reverb.room))
                rooms[name] = st.reverb.room
            }
            r.wetDryMix = Float(st.reverb.wet)
            r.bypass = !st.reverb.enabled
            let m = mixers[name]!
            m.outputVolume = s.effectiveGain(name)
            m.pan = Float(st.pan)
        }
        timePitch.pitch = Float(s.pitch * 100)
        timePitch.rate = Float(s.tempo)
        timePitch.bypass = s.pitch == 0 && s.tempo == 1
        Self.set(masterEQ, s.masterEQ)
        if (tempoChanged || clipsChanged) && isPlaying { play(from: currentTime, loop: loop) }
    }

    // MARK: Playback

    public func start() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        do { try engine.start() } catch { throw MixError.engineStart(error.localizedDescription) }
    }

    /// Seconds into the source (not wall clock: tempo-independent).
    public var currentTime: Double {
        guard isPlaying, let p = players[names[0]], let nodeTime = p.lastRenderTime,
              let t = p.playerTime(forNodeTime: nodeTime) else { return startTime }
        var pos = startTime + Double(t.sampleTime) / t.sampleRate
        if let loop, pos > loop.upperBound {
            let len = loop.upperBound - loop.lowerBound
            pos = loop.lowerBound + (pos - loop.upperBound).truncatingRemainder(dividingBy: max(len, 0.01))
        }
        return min(pos, duration)
    }

    /// Starts all players sample-aligned. With `loop`, plays to its end then loops it forever.
    public func play(from seconds: Double, loop: ClosedRange<Double>? = nil) {
        stopPlayers()
        var from = max(0, min(seconds, duration))
        if let loop, !loop.contains(from) { from = loop.lowerBound }
        startTime = from
        self.loop = loop
        let sr = format.sampleRate
        for name in names {
            schedule(name, from: from, to: loop?.upperBound ?? duration)
            if let loop, let buf = arrangement(name, frame(loop.lowerBound), frame(loop.upperBound) - frame(loop.lowerBound)) {
                let at = AVAudioTime(sampleTime: frame(loop.upperBound) - frame(from), atRate: sr)
                players[name]!.scheduleBuffer(buf, at: at, options: .loops)
            }
        }
        do { try start() } catch { return }
        // One shared start time keeps stems phase-aligned.
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        names.forEach { players[$0]!.play(at: when) }
        isPlaying = true
    }

    public func pause() {
        let t = currentTime
        stopPlayers()
        startTime = t
    }

    private func stopPlayers() {
        names.forEach { players[$0]?.stop() }
        isPlaying = false
    }

    // MARK: Clips

    func frame(_ seconds: Double) -> AVAudioFramePosition { AVAudioFramePosition((seconds * format.sampleRate).rounded()) }

    func clips(_ name: String) -> [Clip] { settings[name].clips ?? Clips.whole(duration) }

    /// Opened on demand: the app writes `.rev-<stem>.wav` the first time a clip is reversed.
    private func reversedFile(_ name: String) -> AVAudioFile? {
        if let f = reversedFiles[name] { return f }
        let f = try? AVAudioFile(forReading: StemEdit.reversedURL(files[name]!.url))
        reversedFiles[name] = f
        return f
    }

    /// File and frames a clip reads. Reversed clips read the reversed file at the mirrored position.
    private func source(_ name: String, _ c: Clip) -> (file: AVAudioFile, start: AVAudioFramePosition, count: AVAudioFramePosition)? {
        let fwd = files[name]!, len = fwd.length
        let a = max(0, frame(c.offset))
        let n = min(frame(c.offset + c.length) - a, len - a)
        guard n > 0 else { return nil }
        if !c.reversed { return (fwd, a, n) }
        guard let rev = reversedFile(name) else { return nil }
        return (rev, len - a - n, n)
    }

    /// Schedules the clips heard in timeline [from, to). Player sample time 0 = `from`.
    private func schedule(_ name: String, from: Double, to: Double) {
        let p = players[name]!
        for clip in clips(name) {
            guard let c = clip.slice(from, to), let src = source(name, c) else { continue }
            p.scheduleSegment(src.file, startingFrame: src.start, frameCount: AVAudioFrameCount(src.count),
                              at: AVAudioTime(sampleTime: frame(c.start) - frame(from), atRate: format.sampleRate))
        }
    }

    /// `count` frames of the stem as arranged, starting at timeline frame `start` (gaps silent).
    func arrangement(_ name: String, _ start: AVAudioFramePosition, _ count: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        guard count > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        out.frameLength = AVAudioFrameCount(count)
        let channels = Int(format.channelCount)
        for ch in 0..<channels { vDSP_vclr(out.floatChannelData![ch], 1, vDSP_Length(count)) }
        let sr = format.sampleRate
        for clip in clips(name) {
            guard let c = clip.slice(Double(start) / sr, Double(start + count) / sr), let src = source(name, c),
                  let tmp = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(src.count)) else { continue }
            src.file.framePosition = src.start
            try? src.file.read(into: tmp, frameCount: AVAudioFrameCount(src.count))
            let at = Int(frame(c.start) - start)
            let n = min(Int(tmp.frameLength), Int(count) - at)
            guard at >= 0, n > 0 else { continue }
            for ch in 0..<channels { (out.floatChannelData![ch] + at).update(from: tmp.floatChannelData![ch], count: n) }
        }
        return out
    }

    /// Writes the stem as arranged (gaps silent) to a 24-bit WAV.
    public func bounce(_ name: String, to url: URL) throws {
        let out = try AVAudioFile(forWriting: url, settings: StemEdit.wavSettings(format), commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = files[name]!.length, step = frame(10)
        var at: AVAudioFramePosition = 0
        while at < total {
            if let b = arrangement(name, at, min(step, total - at)) { try out.write(from: b) }
            at += step
        }
    }

    // MARK: Offline render

    /// Renders `range` (source seconds) of the mix into `out` in the graph's float format.
    /// `only` routes one stem through its chain; nil is the full mix.
    func renderOffline(range: ClosedRange<Double>, only: String?, sampleRate: Double,
                       write: (AVAudioPCMBuffer) throws -> Void, progress: (Double) -> Void) throws {
        var s = settings
        if let only {
            for n in names { s.stems[n, default: StemSettings()].solo = n == only; s.stems[n, default: StemSettings()].mute = n != only }
            s.stems[only, default: StemSettings()].volume = 1
        }
        apply(s)
        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
        defer { engine.stop(); engine.disableManualRenderingMode() }
        for name in names { schedule(name, from: range.lowerBound, to: range.upperBound) }
        do { try engine.start() } catch { throw MixError.engineStart(error.localizedDescription) }
        names.forEach { players[$0]!.play() }

        let tailSeconds = names.contains { s[$0].delay.enabled || s[$0].reverb.enabled } ? 2.0 : 0
        let total = AVAudioFramePosition(((range.upperBound - range.lowerBound) / s.tempo + tailSeconds) * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        while engine.manualRenderingSampleTime < total {
            try Task.checkCancellation()
            let want = AVAudioFrameCount(min(Int64(buffer.frameCapacity), total - engine.manualRenderingSampleTime))
            let status = try engine.renderOffline(want, to: buffer)
            switch status {
            case .success: try write(buffer)
            case .error: throw MixError.render("render error")
            default: break
            }
            progress(Double(engine.manualRenderingSampleTime) / Double(total))
        }
        names.forEach { players[$0]!.stop() }
    }
}
