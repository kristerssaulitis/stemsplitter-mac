import AppKit
import StemMix
import SwiftUI

struct InspectorView: View {
    @Bindable var player: PlayerModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Stem").tag(0)
                Text("Export").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            ScrollView {
                if tab == 0 { FXPanel(player: player) } else { ExportPanel(player: player) }
            }
        }
    }
}

struct FXPanel: View {
    @Bindable var player: PlayerModel
    /// nil = master bus.
    @State private var target: String?

    var song: Song { player.song }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Target", selection: $target) {
                Text("Master").tag(String?.none)
                ForEach(song.stemNames, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
            }
            .onAppear { target = player.selectedStem }
            .onChange(of: player.selectedStem) { _, s in target = s }

            if let stem = target, song.stemNames.contains(stem) {
                stemControls(stem)
            } else {
                Section("Master EQ") { eq(\.masterEQ) }
                Text("Pitch and tempo live in the header (⌘↑ / ⌘↓ pitch · ⌘→ / ⌘← tempo).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func stemControls(_ stem: String) -> some View {
        let s = song.mix[stem]
        Group {
            slider("Volume", value: s.volume, range: 0...2, format: { String(format: "%.0f%%", $0 * 100) }) { v in player.updateMix { $0[stem].volume = v } }
            slider("Pan", value: s.pan, range: -1...1, format: { $0 == 0 ? "C" : String(format: "%@%.0f", $0 < 0 ? "L" : "R", abs($0) * 100) }) { v in
                player.updateMix { $0[stem].pan = v }
            }
        }
        Divider()
        HStack {
            Text("EQ").font(.headline)
            Spacer()
            Toggle("Bypass", isOn: Binding(get: { s.eq.bypass }, set: { v in player.updateMix { $0[stem].eq.bypass = v } }))
                .toggleStyle(.checkbox).font(.caption)
        }
        eq(\.[stem].eq)
        Divider()
        Toggle(isOn: Binding(get: { s.delay.enabled }, set: { v in player.updateMix { $0[stem].delay.enabled = v } })) {
            Text("Delay").font(.headline)
        }
        if s.delay.enabled {
            Picker("Time", selection: Binding(get: { s.delay.beats ?? -1 }, set: { v in player.updateMix { $0[stem].delay.beats = v < 0 ? nil : v } })) {
                Text("1/16").tag(0.25)
                Text("1/8").tag(0.5)
                Text("1/8 dotted").tag(0.75)
                Text("1/4").tag(1.0)
                Text("1/2").tag(2.0)
                Text("Free (ms)").tag(-1.0)
            }
            .disabled(song.analysis?.tempo == nil && s.delay.beats != nil)
            if s.delay.beats == nil {
                slider("Time", value: s.delay.milliseconds, range: 10...2000, format: { String(format: "%.0f ms", $0) }) { v in
                    player.updateMix { $0[stem].delay.milliseconds = v }
                }
            }
            slider("Feedback", value: s.delay.feedback, range: 0...90, format: { String(format: "%.0f%%", $0) }) { v in player.updateMix { $0[stem].delay.feedback = v } }
            slider("Mix", value: s.delay.mix, range: 0...100, format: { String(format: "%.0f%%", $0) }) { v in player.updateMix { $0[stem].delay.mix = v } }
        }
        Divider()
        Toggle(isOn: Binding(get: { s.reverb.enabled }, set: { v in player.updateMix { $0[stem].reverb.enabled = v } })) {
            Text("Reverb").font(.headline)
        }
        if s.reverb.enabled {
            Picker("Space", selection: Binding(get: { s.reverb.room }, set: { v in player.updateMix { $0[stem].reverb.room = v } })) {
                ForEach(ReverbSettings.Room.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            slider("Wet", value: s.reverb.wet, range: 0...100, format: { String(format: "%.0f%%", $0) }) { v in player.updateMix { $0[stem].reverb.wet = v } }
        }
        Divider()
        Button("Reset \(stem.capitalized)") { player.resetStem(stem) }
    }

    private func eq(_ path: WritableKeyPath<MixSettings, EQSettings>) -> some View {
        let e = song.mix[keyPath: path]
        return VStack(spacing: 6) {
            slider("Low", value: e.low, range: -24...24, format: Self.db) { v in player.updateMix { $0[keyPath: path].low = v } }
            slider("Mid", value: e.mid, range: -24...24, format: Self.db) { v in player.updateMix { $0[keyPath: path].mid = v } }
            slider("High", value: e.high, range: -24...24, format: Self.db) { v in player.updateMix { $0[keyPath: path].high = v } }
        }
    }

    static func db(_ v: Double) -> String { String(format: "%+.1f dB", v) }

    private func slider(_ label: String, value: Double, range: ClosedRange<Double>, format: @escaping (Double) -> String,
                        set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(format(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: set), in: range)
                .controlSize(.small)
                .accessibilityLabel(label)
                .accessibilityValue(format(value))
        }
    }
}

struct ExportPanel: View {
    @Bindable var player: PlayerModel
    @AppStorage("export.container") private var container = ExportFormat.Container.wav
    @AppStorage("export.rate") private var rate = 0.0  // 0 = match source
    @AppStorage("export.depth") private var depth = ExportFormat.Depth.int24

    var song: Song { player.song }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Format", selection: $container) {
                Text("WAV").tag(ExportFormat.Container.wav)
                Text("AIFF").tag(ExportFormat.Container.aiff)
                Text("FLAC").tag(ExportFormat.Container.flac)
            }
            Picker("Sample rate", selection: $rate) {
                Text(song.info.sourceSampleRate.map { String(format: "Source (%.1f kHz)", $0 / 1000) } ?? "Source").tag(0.0)
                Text("44.1 kHz").tag(44_100.0)
                Text("48 kHz").tag(48_000.0)
            }
            Picker("Bit depth", selection: $depth) {
                Text("16-bit").tag(ExportFormat.Depth.int16)
                Text("24-bit").tag(ExportFormat.Depth.int24)
                if container != .flac { Text("32-bit float").tag(ExportFormat.Depth.float32) }
            }
            Toggle("Selection only", isOn: $player.exportSelectionOnly).disabled(player.selection == nil)
            Text("Exports include FX, pitch and tempo: what you hear.")
                .font(.caption).foregroundStyle(.secondary)

            if let progress = player.exportProgress {
                HStack {
                    ProgressView(value: progress)
                    Button { player.exportTask?.cancel() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                        .accessibilityLabel("Cancel export")
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button { Exporter.stems(player) } label: { Label("Export All Stems…  ⌥⌘E", systemImage: "square.stack.3d.down.right") }
                    Button { Exporter.mixdown(player) } label: { Label("Export Mixdown…  ⇧⌘E", systemImage: "waveform") }
                    Button { Exporter.mixdown(player, instrumental: true) } label: { Label("Export Instrumental…", systemImage: "music.mic.circle") }
                        .help("Mixdown with every vocals stem muted")
                    if song.info.isVideo {
                        Button { Exporter.video(player) } label: { Label("Export Video with This Mix…", systemImage: "film") }
                    }
                    Button { Exporter.midi(player) } label: { Label("Export MIDI…", systemImage: "music.note.list") }
                        .disabled(song.notes.isEmpty)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }
}

/// Export actions, shared by the inspector buttons and the File menu.
@MainActor
enum Exporter {
    static var format: ExportFormat {
        let d = UserDefaults.standard
        let container = ExportFormat.Container(rawValue: d.string(forKey: "export.container") ?? "") ?? .wav
        var depth = ExportFormat.Depth(rawValue: d.integer(forKey: "export.depth")) ?? .int24
        if container == .flac && depth == .float32 { depth = .int24 }
        let rate = d.double(forKey: "export.rate")
        return ExportFormat(container: container, sampleRate: rate == 0 ? nil : rate, depth: depth)
    }

    static func chooseFolder() -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Export Here"
        return p.runModal() == .OK ? p.url : nil
    }

    static func chooseFile(_ name: String, ext: String) -> URL? {
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(name).\(ext)"
        p.canCreateDirectories = true
        return p.runModal() == .OK ? p.url : nil
    }

    private static func run(_ player: PlayerModel, _ work: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> URL) {
        guard player.exportProgress == nil else { return }
        player.exportProgress = 0
        player.exportTask = Task {
            do {
                let out = try await work { p in Task { @MainActor in player.exportProgress = p } }
                NSWorkspace.shared.activateFileViewerSelecting([out])
            } catch is CancellationError {
            } catch {
                AppModel.shared.errorMessage = error.localizedDescription
            }
            player.exportProgress = nil
        }
    }

    static func stems(_ player: PlayerModel) {
        guard let dir = chooseFolder() else { return }
        let song = player.song, fmt = format, r = player.exportRange
        let stems = song.stems, mix = song.mix, bpm = song.analysis?.tempo?.bpm, src = song.info.sourceSampleRate
        let items = song.stemNames.map { (stem: $0, file: dir.appendingPathComponent(song.exportName($0) + "." + fmt.fileExtension)) }
        run(player) { report in
            for (i, item) in items.enumerated() {
                try await Task.detached {
                    try ExportRenderer.render(stems: stems, settings: mix, bpm: bpm, only: item.stem, range: r, format: fmt,
                                              sourceSampleRate: src, to: item.file) { p in report((Double(i) + p) / Double(items.count)) }
                }.value
            }
            return items.first!.file
        }
    }

    /// `instrumental`: same mix with the vocals (and their duplicates) muted.
    static func mixdown(_ player: PlayerModel, instrumental: Bool = false) {
        let song = player.song, fmt = format, r = player.exportRange
        guard let url = chooseFile(song.exportName(instrumental ? "instrumental" : nil), ext: fmt.fileExtension) else { return }
        var mix = song.mix
        if instrumental {
            for s in song.stemNames where StemStyle.base(s) == "vocals" { mix[s].mute = true; mix[s].solo = false }
        }
        let stems = song.stems, bpm = song.analysis?.tempo?.bpm, src = song.info.sourceSampleRate
        run(player) { report in
            try await Task.detached {
                try ExportRenderer.render(stems: stems, settings: mix, bpm: bpm, only: nil, range: r, format: fmt,
                                          sourceSampleRate: src, to: url, progress: report)
            }.value
            return url
        }
    }

    static func video(_ player: PlayerModel) {
        let song = player.song
        guard let source = song.resolveSource() else {
            AppModel.shared.errorMessage = "The original video isn't available any more."
            return
        }
        guard let url = chooseFile(song.exportName(nil), ext: "mov") else { source.stopAccessingSecurityScopedResource(); return }
        // Video can't follow a tempo change: render at source speed. The region maps onto the source timeline.
        var atSourceSpeed = song.mix
        atSourceSpeed.tempo = 1
        let flat = atSourceSpeed
        let stems = song.stems, bpm = song.analysis?.tempo?.bpm, r = player.exportRange
        let base = song.info.range?.lowerBound ?? 0
        let span = r ?? 0...song.info.duration
        run(player) { report in
            defer { source.stopAccessingSecurityScopedResource() }
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await Task.detached {
                try ExportRenderer.render(stems: stems, settings: flat, bpm: bpm, only: nil, range: r, format: ExportFormat(),
                                          sourceSampleRate: nil, to: wav) { report($0 * 0.8) }
            }.value
            try await ExportRenderer.replaceAudio(video: source, audio: wav, range: (span.lowerBound + base)...(span.upperBound + base), to: url)
            report(1)
            return url
        }
    }

    static func midi(_ player: PlayerModel) {
        guard let dir = chooseFolder() else { return }
        var first: URL?
        for stem in player.song.stemNames where player.song.notes[stem] != nil {
            guard let tmp = player.midiFile(stem: stem) else { continue }
            let dest = dir.appendingPathComponent(tmp.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: tmp, to: dest)
            first = first ?? dest
        }
        if let first { NSWorkspace.shared.activateFileViewerSelecting([first]) }
    }
}
