import AVKit
import StemAnalysis
import SwiftUI

enum StemStyle {
    /// "vocals 2" → "vocals": duplicates look like their source.
    static func base(_ stem: String) -> String { String(stem.split(separator: " ").first ?? Substring(stem)) }

    static func color(_ stem: String) -> Color {
        switch base(stem) {
        case "vocals": Color(red: 0.98, green: 0.42, blue: 0.62)
        case "drums": Color(red: 1.0, green: 0.62, blue: 0.25)
        case "bass": Color(red: 0.58, green: 0.48, blue: 1.0)
        case "other": Color(red: 0.36, green: 0.84, blue: 0.58)
        default: Color(red: 0.35, green: 0.78, blue: 0.95)
        }
    }

    static func icon(_ stem: String) -> String {
        switch base(stem) {
        case "vocals": "music.mic"
        case "drums": "cylinder.split.1x2"
        case "bass": "guitars"
        case "other": "pianokeys"
        default: "waveform"
        }
    }
}

struct SongView: View {
    @Bindable var player: PlayerModel
    @FocusState private var focused: Bool

    var song: Song { player.song }

    var body: some View {
        // TEMP bisect B: pick SongView sub-layout via SS_SONGVIEW.
        let variant = ProcessInfo.processInfo.environment["SS_SONGVIEW"] ?? "full"
        let inner = Group {
            switch variant {
            case "header": HeaderView(player: player)
            case "transport": ScrollView { TransportBar(player: player).padding(20) }
            case "timeline": ScrollView { TimelineView(player: player) }
            case "chords": ScrollView { VStack(alignment: .leading, spacing: 12) { TimelineView(player: player) }.padding(20) }
            case "stepper": HStack { Spacer(); Stepper("Semitones", value: .constant(0), in: -12...12) }
            case "steppers": HStack(spacing: 8) {
                Stepper(value: .constant(0), in: -12...12) { Text("+0 st").font(.body.monospacedDigit()) }
                Stepper(value: .constant(100), in: 50...150) { Text("100 bpm").font(.body.monospacedDigit()) }
            }
            case "scrolltext": ScrollView { Text("hello hello hello hello hello hello hello hello hello") }
            case "transportbare": TransportBar(player: player)
            case "timelinebare": TimelineView(player: player)
            case "stepperbare": Stepper("Semitones", value: .constant(0), in: -12...12)
            case "steppersbare": HStack(spacing: 8) {
                Stepper(value: .constant(0), in: -12...12) { Text("+0 st").font(.body.monospacedDigit()) }
                Stepper(value: .constant(100), in: 50...150) { Text("100 bpm").font(.body.monospacedDigit()) }
            }
            case "buttonsbare": HStack(spacing: 10) {
                ForEach(0..<8, id: \.self) { i in
                    Button { } label: { Image(systemName: "scissors") }
                        .buttonStyle(.borderless)
                }
            }
            case "buttons3": HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    Button { } label: { Image(systemName: "scissors") }
                        .buttonStyle(.borderless)
                }
            }
            case "buttons5": HStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { i in
                    Button { } label: { Image(systemName: "scissors") }
                        .buttonStyle(.borderless)
                }
            }
            case "texts6": HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { i in Text("item \(i)") }
            }
            case "icons6": HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { i in Image(systemName: "scissors") }
            }
            case "space600": Color.clear.frame(width: 600, height: 10)
            case "buttons": HStack(spacing: 10) {
                ForEach(0..<8, id: \.self) { i in
                    Button { } label: { Image(systemName: "scissors") }
                        .buttonStyle(.borderless)
                }
            }
            default: VStack(alignment: .leading, spacing: 12) {
                if song.info.isVideo { VideoPreview(player: player).frame(maxHeight: 220) }
                TransportBar(player: player)
                TimelineView(player: player)
            }
            .padding(20)
            }
        }
        VStack(spacing: 0) {
            if variant == "full" {
                HeaderView(player: player)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                Divider()
            }
            if variant == "header" || variant.hasSuffix("bare") {
                inner
            } else {
                ScrollView { inner.padding(.vertical, variant == "full" ? 0 : 12) }
            }
        }
        .modifier(TEMPFocusStrip(player: player, handleKey: { c in handleKey(c) }))

        .alert("Playback problem", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(player.errorMessage ?? "") }
    }

    /// TEMP bisect F: drop focusable/focused/key handlers via SS_NOFOCUS.
    struct TEMPFocusStrip: ViewModifier {
        @Bindable var player: PlayerModel
        var handleKey: (String) -> KeyPress.Result
        @FocusState private var focused: Bool

        @ViewBuilder
        func body(content: Content) -> some View {
            if ProcessInfo.processInfo.environment["SS_NOFOCUS"] != nil {
                content
            } else {
                content
                    .focusable()
                    .focused($focused)
                    .focusEffectDisabled()
                    .onKeyPress(.space) { player.togglePlay(); return .handled }
                    .onKeyPress(.delete) {
                        guard player.selection != nil else { return .ignored }
                        player.deleteRegion()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard player.selection != nil || player.selectedStem != nil else { return .ignored }
                        if player.selection != nil { player.selection = nil; player.looping = false } else { player.selectedStem = nil }
                        return .handled
                    }
                    .onKeyPress(characters: .init(charactersIn: "smnior123456789")) { press in handleKey(press.characters) }
            }
        }
    }

    private func handleKey(_ c: String) -> KeyPress.Result {
        let names = song.stemNames
        switch c {
        case "r": player.reverse()  // Ableton's R
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            let i = Int(c)! - 1
            guard i < names.count else { return .ignored }
            player.selectedStem = names[i]
        case "s": if let s = player.selectedStem { player.toggleSolo(s) }
        case "m": if let s = player.selectedStem { player.toggleMute(s) }
        case "n":
            if let s = player.selectedStem, StemAnalyzer.transcribable.contains(s) {
                if player.showNotes.contains(s) { player.showNotes.remove(s) } else { player.showNotes.insert(s) }
            }
        case "i": player.setLoopStart()
        case "o": player.setLoopEnd()
        default: return .ignored
        }
        return .handled
    }
}

struct HeaderView: View {
    @Bindable var player: PlayerModel
    var song: Song { player.song }

    var body: some View {
        // TEMP bisect D: pick header sub-layout via SS_HEADER.
        let variant = ProcessInfo.processInfo.environment["SS_HEADER"] ?? "all"
        Group {
            switch variant {
            case "title": Text(song.title).font(.title2.weight(.semibold)).lineLimit(1)
            case "bpm": HStack { Spacer(); BPMBadge(player: player) }
            case "key": HStack { Spacer(); KeyBadge(song: song) }
            case "pitch": HStack { Spacer(); PitchControl(player: player) }
            default:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: 18) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.title).font(.title2.weight(.semibold)).lineLimit(1)
                            Text("\(Format.time(song.info.duration)) · \(song.stemNames.count) stems · split in \(String(format: "%.0f", song.info.splitSeconds)) s")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        BPMBadge(player: player)
                        KeyBadge(song: song)
                        PitchControl(player: player)
                    }
                }
            }
        }
    }
}

struct BPMBadge: View {
    @Bindable var player: PlayerModel
    var song: Song { player.song }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("BPM").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if song.analyzing {
                Text("Detecting…").font(.title3).redacted(reason: .placeholder)
            } else if let tempo = song.analysis?.tempo {
                HStack(spacing: 6) {
                    Text(String(format: "%.0f", tempo.bpm * song.mix.tempo))
                        .font(.title3.monospacedDigit().weight(.semibold))
                    // Octave errors are the common failure: one click to fix.
                    Button("½×") { setBPM(tempo.bpm / 2) }.help("Half time")
                    Button("2×") { setBPM(tempo.bpm * 2) }.help("Double time")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                Text("—").font(.title3).help("No steady beat found")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tempo")
    }

    private func setBPM(_ bpm: Double) {
        guard var a = song.analysis, var t = a.tempo else { return }
        let period = 60 / bpm
        let first = t.beats.first ?? 0
        t.bpm = bpm
        t.beats = Array(stride(from: first, to: song.info.duration, by: period))
        a.tempo = t
        song.analysis = a
        song.saveAnalysis()
        player.graph?.bpm = bpm
        player.updateMix { _ in }  // re-sync beat-locked delays
    }
}

struct KeyBadge: View {
    let song: Song

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("KEY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if song.analyzing {
                Text("Detecting key…").font(.title3).redacted(reason: .placeholder)
            } else if let result = song.analysis?.key, let key = song.key {
                HStack(alignment: .center, spacing: 6) {
                    Text(key.longName).font(.title3.weight(.semibold))
                    Text(key.camelot).font(.callout.monospaced()).foregroundStyle(.secondary)
                    if result.confidence < 0.6 {
                        Text("or \(result.runnerUp.transposed(song.semitones).name)")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("Low confidence: runner-up key")
                    }
                }
                .help(String(format: "Confidence %.2f", result.confidence))
            } else {
                Text("—").font(.title3).help("No clear key")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PitchControl: View {
    @Bindable var player: PlayerModel
    var song: Song { player.song }
    private var detected: Double? { song.analysis?.tempo?.bpm }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("PITCH · TEMPO").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Stepper(value: Binding(get: { song.mix.pitch }, set: { v in player.updateMix { $0.pitch = v } }),
                        in: -12...12, step: 1) {
                    Text(String(format: "%+.0f st", song.mix.pitch)).font(.body.monospacedDigit()).frame(width: 46, alignment: .trailing)
                }
                .accessibilityLabel("Pitch in semitones")
                if let detected {
                    Stepper(value: bpm, in: (detected * 0.5).rounded(.up)...(detected * 1.5).rounded(.down), step: 1) {
                        HStack(alignment: .center, spacing: 2) {
                            Text(String(Int((detected * song.mix.tempo).rounded()))).font(.body.monospacedDigit())
                            Text("bpm").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Tempo in BPM")
                    .help("Speed up or slow down (⌘→ / ⌘←)")
                } else {
                    Stepper(value: percent, in: 50...150, step: 1) {
                        Text("\(Int((song.mix.tempo * 100).rounded()))%").font(.body.monospacedDigit())
                    }
                    .accessibilityLabel("Tempo percent")
                    .help("Speed up or slow down (⌘→ / ⌘←)")
                }
                if song.mix.tempo != 1 {
                    Button { player.updateMix { $0.tempo = 1 } } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .help("Reset tempo to 100%")
                        .accessibilityLabel("Reset tempo")
                }
            }
        }
    }

    private var bpm: Binding<Double> {
        guard let detected else { return .constant(100) }
        return Binding(get: { (detected * song.mix.tempo).rounded() },
                       set: { v in player.updateMix { $0.tempo = v / detected } })
    }

    private var percent: Binding<Double> {
        Binding(get: { (song.mix.tempo * 100).rounded() },
                set: { v in player.updateMix { $0.tempo = v / 100 } })
    }
}

struct TransportBar: View {
    @Bindable var player: PlayerModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(width: 30)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.toggleLoop() } label: {
                    Image(systemName: "repeat").foregroundStyle(player.looping ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Loop selection (I / O set points)")
                .accessibilityLabel(player.looping ? "Looping on" : "Looping off")
                EditTools(player: player)
                if let job = AppModel.shared.editJob {
                    ProgressView().controlSize(.small)
                    Text("Making \(job.title)…").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(Format.precise(player.currentTime)) / \(Format.time(player.duration))")
                    .font(.body.monospacedDigit())
                if let sel = player.selection {
                    Text("Selection \(Format.precise(sel.lowerBound))–\(Format.precise(sel.upperBound))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button { player.selection = nil; player.looping = false } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear selection")
                    Button { player.zoomToSelection() } label: { Image(systemName: "arrow.left.and.right.square") }
                        .buttonStyle(.borderless)
                        .help("Zoom to selection (⇧⌘=)")
                        .accessibilityLabel("Zoom to selection")
                }
                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    Button { player.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                        .disabled(player.zoom <= 1)
                        .help("Zoom out (⌘−)")
                        .accessibilityLabel("Zoom out")
                    Text(player.zoom <= 1 ? "Fit" : String(format: "%.0f×", player.zoom))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 30)
                        .onTapGesture { player.zoomToFit() }
                        .help("Zoom to fit (⌘0)")
                    Button { player.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                        .disabled(player.zoom >= player.maxZoom)
                        .help("Zoom in (⌘=)")
                        .accessibilityLabel("Zoom in")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

/// DAW-style edit cluster: what the edit applies to, then the arrangement tools with their keys.
struct EditTools: View {
    @Bindable var player: PlayerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let sel = player.selection != nil, busy = AppModel.shared.editJob != nil
        HStack(spacing: 10) {
            Divider().frame(height: 16)
            Text(player.selectedStem.map { $0.capitalized } ?? "All stems")
                .font(.caption.weight(.semibold))
                .foregroundStyle(player.selectedStem.map { StemStyle.color($0) } ?? .secondary)
                .frame(minWidth: 56, alignment: .leading)
                .help("Edits apply to this stem. Click a stem to target it, Esc or drag the ruler for all.")
            tool("scissors", "Split at the playhead or selection edges (⌘E)") { player.split() }
            tool("plus.square.on.square", sel ? "Duplicate the selection after itself (⌘D)" : "Duplicate the track (⌘D)") { player.duplicate() }
                .disabled(!sel && player.selectedStem == nil)
            tool("arrow.left.arrow.right", "Reverse the selection or the clip at the playhead (R)") { player.reverse() }
            tool("crop", "Crop to the selection (⇧⌘J)") { player.crop() }.disabled(!sel)
            tool("delete.left", "Delete the selection (⌫)") { player.deleteRegion() }.disabled(!sel)
            tool("arrow.uturn.backward", "Undo (⌘Z)") { player.undo() }.disabled(!player.canUndo)
            tool("arrow.uturn.forward", "Redo (⇧⌘Z)") { player.redo() }.disabled(!player.canRedo)
            tool("keyboard", "Keyboard shortcuts (⌘/)") { openWindow(id: "shortcuts") }
            Divider().frame(height: 16)
        }
        .disabled(busy)
    }

    private func tool(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
    }
}

/// Muted video above the timeline, kept in sync with the audio engine.
struct VideoPreview: View {
    @Bindable var player: PlayerModel
    @State private var av: AVPlayer?
    @State private var source: URL?

    var body: some View {
        Group {
            if let av {
                VideoPlayer(player: av).disabled(true)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .overlay(Text("Original video not found").foregroundStyle(.secondary))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            source = player.song.resolveSource()
            if let source {
                let p = AVPlayer(url: source)
                p.isMuted = true
                av = p
            }
        }
        .onDisappear {
            av?.pause()
            source?.stopAccessingSecurityScopedResource()
        }
        .onChange(of: player.isPlaying) { _, playing in sync(force: true, playing: playing) }
        .onChange(of: player.currentTime) { _, _ in sync(force: false, playing: player.isPlaying) }
    }

    private func sync(force: Bool, playing: Bool) {
        guard let av else { return }
        let offset = player.song.info.range?.lowerBound ?? 0
        let want = player.currentTime + offset
        let drift = abs(av.currentTime().seconds - want)
        if force || drift > 0.08 {
            av.seek(to: CMTime(seconds: want, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        let rate = playing ? Float(player.song.mix.tempo) : 0
        if av.rate != rate { av.rate = rate }
    }
}

