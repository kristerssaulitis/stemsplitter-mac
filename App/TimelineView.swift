import AppKit
import StemAnalysis
import StemMix
import SwiftUI
import UniformTypeIdentifiers

/// Fixed label column + one horizontally scrolling, zoomable lane area sharing one time axis.
/// Ruler: click = seek, drag = select across all stems (loop / export region).
/// Stem lane: drag = select on that stem, clip edge = trim, clip title strip = move. Pinch or ⌘= / ⌘− / ⌘0 = zoom.
struct TimelineView: View {
    @Bindable var player: PlayerModel
    static let labelWidth: CGFloat = 196
    static let rulerHeight: CGFloat = 18
    static let chordHeight: CGFloat = 26
    static let waveHeight: CGFloat = 58
    static let notesHeight: CGFloat = 64
    static let rowSpacing: CGFloat = 6

    @State private var viewWidth: CGFloat = 600
    @State private var scrollX: CGFloat = 0
    @State private var position = ScrollPosition(edge: .leading)
    @State private var pinchBase: Double?

    var song: Song { player.song }
    var contentWidth: CGFloat { viewWidth * player.zoom }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 0) {
                labels.frame(width: Self.labelWidth)
                ScrollView(.horizontal) {
                    lanes
                        .frame(width: contentWidth)
                        .overlay { PlayheadOverlay(player: player) }
                }
                .scrollPosition($position)
                .scrollIndicators(player.zoom > 1 ? .visible : .hidden)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in scrollX = x }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                    viewWidth = max(100, w)
                    player.maxZoom = Self.maxZoom(width: viewWidth, song: song)
                }
                .gesture(MagnifyGesture()
                    .onChanged { g in
                        let base = pinchBase ?? player.zoom
                        pinchBase = base
                        player.setZoom(base * g.magnification)
                    }
                    .onEnded { _ in pinchBase = nil })
            }
            Text("Drag on a stem to select · drag clip edges to trim, the top strip to move (⌘ = no snap) · ⌘E split · ⌘D duplicate · R reverse · ⌫ delete · ⌘/ all shortcuts · drag ≡ out to Finder or a DAW")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, Self.labelWidth)
        }
        // Zooming keeps the playhead at the same screen x (centered if it was off screen);
        // zoom-to-selection puts the selection at the left edge. While playing, page to follow the playhead.
        .onChange(of: player.zoom) { old, new in
            let d = max(player.duration, 0.01)
            if let t = player.pendingScrollTime {
                player.pendingScrollTime = nil
                scrollTo(CGFloat(t / d) * viewWidth * new)
                return
            }
            let t = player.currentTime
            let oldScreenX = CGFloat(t / d) * viewWidth * old - scrollX
            let keep = (0...viewWidth).contains(oldScreenX) ? oldScreenX : viewWidth / 2
            scrollTo(CGFloat(t / d) * viewWidth * new - keep)
        }
        .onChange(of: player.currentTime) { _, t in
            guard player.zoom > 1, player.isPlaying else { return }
            let x = CGFloat(t / max(player.duration, 0.01)) * contentWidth
            if x < scrollX || x > scrollX + viewWidth - 24 { scrollTo(x - 24) }
        }
    }

    private func scrollTo(_ x: CGFloat) {
        position.scrollTo(x: max(0, min(x, contentWidth - viewWidth)))
    }

    /// Past ~2 px per waveform peak there's nothing more to see, and huge canvases cost memory.
    static func maxZoom(width: CGFloat, song: Song) -> Double {
        let peaks = CGFloat(song.peaks.values.first?.count ?? 0)
        return Double(max(1, min(64, min(peaks * 2, 24_000) / width)))
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            Color.clear.frame(height: Self.rulerHeight)
            Text("CHORDS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(height: Self.chordHeight)
            ForEach(Array(song.stemNames.enumerated()), id: \.element) { index, stem in
                StemHeader(player: player, stem: stem, index: index)
            }
        }
    }

    private var lanes: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                TimeRuler(duration: song.info.duration).frame(height: Self.rulerHeight)
                ChordLane(song: song).frame(height: Self.chordHeight)
            }
            .overlay { RulerGesture(player: player) }
            ForEach(song.stemNames, id: \.self) { stem in
                VStack(spacing: 2) {
                    StemLane(player: player, stem: stem)
                        .frame(height: Self.waveHeight)
                        .contextMenu { ArrangeMenu(player: player, stem: stem) }
                    if player.showNotes.contains(stem) {
                        PianoRollLane(notes: song.notes[stem], loading: song.transcribing.contains(stem),
                                      duration: song.info.duration, color: StemStyle.color(stem), stem: stem) {
                            AppModel.shared.transcribe(song, stem: stem)
                        }
                        .frame(height: Self.notesHeight)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }
}

/// Time labels at an interval that keeps ~80 pt between ticks at the current zoom.
struct TimeRuler: View {
    let duration: Double

    var body: some View {
        Canvas { ctx, size in
            guard duration > 0 else { return }
            let pps = size.width / duration
            let step = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300].first { $0 * pps >= 80 } ?? 600
            var t = 0.0
            while t <= duration {
                let x = t * pps
                ctx.fill(Path(CGRect(x: x, y: size.height - 5, width: 1, height: 5)), with: .color(.secondary.opacity(0.6)))
                let label = step < 1 ? Format.precise(t) : Format.time(t)
                ctx.draw(Text(label).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: x + 3, y: 0), anchor: .topLeading)
                t += step
            }
        }
        .accessibilityHidden(true)
    }
}

/// Playhead and a faint selection band over all lanes. Drawing only: lanes and the ruler own the gestures.
struct PlayheadOverlay: View {
    let player: PlayerModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(player.duration, 0.01)
            ZStack(alignment: .topLeading) {
                if let sel = player.selection {
                    Rectangle()
                        .fill(Color.accentColor.opacity(player.looping ? 0.12 : 0.05))
                        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 1) }
                        .overlay(alignment: .trailing) { Rectangle().fill(Color.accentColor).frame(width: 1) }
                        .frame(width: max(1, CGFloat((sel.upperBound - sel.lowerBound) / d) * w))
                        .offset(x: CGFloat(sel.lowerBound / d) * w)
                }
                Rectangle().fill(Color.white.opacity(0.9)).frame(width: 1.5)
                    .offset(x: CGFloat(player.currentTime / d) * w)
            }
            .frame(width: w, height: geo.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Ruler + chord row: click = seek, drag = select time across every stem.
struct RulerGesture: View {
    @Bindable var player: PlayerModel
    @State private var dragStart: Double?
    @State private var lastTap: Date?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(player.duration, 0.01)
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let t = max(0, min(d, Double(g.location.x / w) * d))
                            let start = dragStart ?? Double(g.startLocation.x / w) * d
                            dragStart = start
                            if abs(g.translation.width) > 3 {
                                player.selectedStem = nil
                                player.selection = min(start, t)...max(start, t)
                            }
                        }
                        .onEnded { g in
                            defer { dragStart = nil }
                            if abs(g.translation.width) <= 3 {
                                // Double-click the ruler = undo.
                                if let last = lastTap, Date().timeIntervalSince(last) < 0.35, player.canUndo {
                                    lastTap = nil
                                    player.undo()
                                } else {
                                    lastTap = Date()
                                    player.seek(Double(g.location.x / w) * d)
                                }
                            } else if let sel = player.selection {
                                player.currentTime = sel.lowerBound
                                if player.isPlaying || player.looping { player.play() }
                            }
                        }
                )
        }
        .accessibilityHidden(true)
    }
}

/// One stem's arrangement, Ableton-style: clips with a title strip over the waveform.
/// Drag = select time on this stem · drag a clip edge = trim · drag the strip = move · click = playhead,
/// click the strip = select that clip. Edits snap to detected beats; hold ⌘ to place freely.
struct StemLane: View {
    @Bindable var player: PlayerModel
    let stem: String
    static let strip: CGFloat = 10
    static let edge: CGFloat = 6

    private enum Drag { case select(Double), trim(Int, left: Bool), move(Int) }
    @State private var drag: Drag?
    @State private var base: [Clip] = []
    @State private var before: PlayerModel.Snapshot?

    var song: Song { player.song }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(player.duration, 0.01)
            let clips = song.clips(stem), color = StemStyle.color(stem)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for c in clips {
                        let x0 = CGFloat(c.start / d) * size.width, x1 = CGFloat(c.end / d) * size.width
                        let r = CGRect(x: x0 + 1, y: 0.5, width: max(1, x1 - x0 - 2), height: size.height - 1)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(color.opacity(0.10)))
                        ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(color.opacity(0.55)), lineWidth: 1)
                        let strip = CGRect(x: r.minX, y: 0, width: r.width, height: Self.strip)
                        ctx.fill(Path(roundedRect: strip, cornerRadius: 2), with: .color(color.opacity(c.reversed ? 0.3 : 0.5)))
                        if c.reversed && r.width > 20 {
                            ctx.draw(Text("◀ rev").font(.system(size: 7, weight: .bold)).foregroundStyle(.black.opacity(0.7)),
                                     at: CGPoint(x: r.minX + 4, y: Self.strip / 2), anchor: .leading)
                        }
                    }
                }
                WaveformLane(peaks: song.arrangedPeaks(stem), color: color, dimmed: song.mix.effectiveGain(stem) == 0)
                    .padding(.top, Self.strip)
                if let sel = player.selection, player.selectedStem == stem || player.selectedStem == nil {
                    Rectangle().fill(Color.accentColor.opacity(0.25))
                        .frame(width: max(1, CGFloat((sel.upperBound - sel.lowerBound) / d) * w))
                        .offset(x: CGFloat(sel.lowerBound / d) * w)
                }
            }
            .frame(width: w, height: geo.size.height, alignment: .topLeading)
            .overlay {
                if player.selectedStem == stem { RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.7), lineWidth: 1) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { changed($0, w: w, d: d, clips: clips) }
                .onEnded { ended($0, w: w, d: d) })
            .onContinuousHover { phase in
                guard case .active(let p) = phase else { NSCursor.arrow.set(); return }
                switch hit(p, w: w, d: d, clips: clips) {
                case .trim: NSCursor.resizeLeftRight.set()
                case .move: NSCursor.openHand.set()
                default: NSCursor.iBeam.set()
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(stem.capitalized) clips")
        .accessibilityValue("\(song.clips(stem).count) clips")
    }

    /// Edge hits take the clip on the side the pointer is on, so split points can be trimmed both ways.
    private func hit(_ p: CGPoint, w: CGFloat, d: Double, clips: [Clip]) -> Drag? {
        for (i, c) in clips.enumerated() {
            let x0 = CGFloat(c.start / d) * w, x1 = CGFloat(c.end / d) * w
            if p.x <= x1 + 1, x1 - p.x < Self.edge, p.x > x0 { return .trim(i, left: false) }
            if p.x >= x0 - 1, p.x - x0 < Self.edge, p.x < x1 { return .trim(i, left: true) }
        }
        if p.y <= Self.strip + 2, let i = Clips.at(clips, Double(p.x / w) * d) { return .move(i) }
        return nil
    }

    /// Nearest detected beat within 8 pt, unless ⌘ is held.
    private func snap(_ t: Double, w: CGFloat, d: Double) -> Double {
        guard !NSEvent.modifierFlags.contains(.command), let beats = song.analysis?.tempo?.beats,
              let b = beats.min(by: { abs($0 - t) < abs($1 - t) }), CGFloat(abs(b - t) / d) * w < 8 else { return t }
        return b
    }

    private func changed(_ g: DragGesture.Value, w: CGFloat, d: Double, clips: [Clip]) {
        if drag == nil {
            before = player.snapshot
            base = clips
            drag = hit(g.startLocation, w: w, d: d, clips: clips) ?? .select(snap(Double(g.startLocation.x / w) * d, w: w, d: d))
            player.selectedStem = stem
        }
        let t = max(0, min(d, snap(Double(g.location.x / w) * d, w: w, d: d)))
        switch drag {
        case .select(let t0):
            if abs(g.translation.width) > 3 { player.selection = min(t0, t)...max(t0, t) }
        case .trim(let i, let left):
            player.previewClips(stem, Clips.trim(base, index: i, leftEdge: left, to: t, sourceLength: d, duration: d))
        case .move(let i):
            guard abs(g.translation.width) > 2 else { return }
            let start = snap(base[i].start + Double(g.translation.width / w) * d, w: w, d: d)
            player.previewClips(stem, Clips.move(base, index: i, by: start - base[i].start, duration: d))
            NSCursor.closedHand.set()
        case nil: break
        }
    }

    private func ended(_ g: DragGesture.Value, w: CGFloat, d: Double) {
        defer { drag = nil; before = nil }
        let click = abs(g.translation.width) <= 3
        switch drag {
        case .select:
            if click {
                if !player.looping { player.selection = nil }
                player.seek(Double(g.location.x / w) * d)
            } else if let sel = player.selection {
                player.currentTime = sel.lowerBound
                if player.isPlaying || player.looping { player.play() }
            }
        case .move(let i) where click:
            player.selection = base[i].start...base[i].end  // click the strip = select the clip
        default:
            break
        }
        if let before { player.commit(before) }
    }
}

struct ChordLane: View {
    let song: Song

    var body: some View {
        GeometryReader { geo in
            let d = max(song.info.duration, 0.01), w = geo.size.width
            if song.analyzing {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).redacted(reason: .placeholder)
            } else if let chords = song.analysis?.chords, !chords.isEmpty {
                ZStack(alignment: .leading) {
                    ForEach(Array(chords.enumerated()), id: \.offset) { _, seg in
                        let x = CGFloat(seg.start / d) * w, width = CGFloat((seg.end - seg.start) / d) * w
                        if let chord = seg.chord {
                            let name = chord.transposed(song.semitones).name
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.primary.opacity(seg.confidence < 0.6 ? 0.05 : 0.1))
                                .overlay(alignment: .leading) {
                                    if width > 22 {
                                        Text(name).font(.caption.weight(.medium)).lineLimit(1).padding(.leading, 4)
                                            .foregroundStyle(seg.confidence < 0.6 ? .secondary : .primary)
                                    }
                                }
                                .frame(width: max(1, width - 1))
                                .offset(x: x)
                                .help(name)
                        }
                    }
                }
            } else {
                Text("—").foregroundStyle(.secondary).help("No chords: no clear tonal center")
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Chords")
        .accessibilityValue(chordSummary)
    }

    private var chordSummary: String {
        let names = (song.analysis?.chords ?? []).compactMap { $0.chord?.transposed(song.semitones).name }
        var unique: [String] = []
        for n in names where unique.last != n { unique.append(n) }
        return unique.prefix(12).joined(separator: ", ")
    }
}

/// Label-column half of a stem row: drag handle, name, S / M / ♪, and the MIDI drag handle.
struct StemHeader: View {
    @Bindable var player: PlayerModel
    let stem: String
    let index: Int

    var song: Song { player.song }
    var color: Color { StemStyle.color(stem) }
    var canNote: Bool { StemAnalyzer.transcribable.contains(stem) }
    var showingNotes: Bool { player.showNotes.contains(stem) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header.frame(height: TimelineView.waveHeight)
            if showingNotes {
                noteHandle.frame(maxWidth: .infinity, alignment: .trailing).frame(height: TimelineView.notesHeight)
            }
        }
        .padding(.vertical, 3)
        .background(player.selectedStem == stem ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu { ArrangeMenu(player: player, stem: stem) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 30)
                .contentShape(Rectangle())
                .onDrag {
                    guard let url = player.dragFile(stem: stem) else { return NSItemProvider() }
                    let p = NSItemProvider(object: url as NSURL)
                    p.suggestedName = url.lastPathComponent
                    return p
                } preview: {
                    Label(song.exportName(stem), systemImage: "waveform").padding(6).background(color.opacity(0.85), in: Capsule())
                }
                .help("Drag the \(stem) audio into Finder or your DAW")
                .accessibilityLabel("Drag \(stem) audio")
            Button { player.selectedStem = stem } label: {
                HStack(spacing: 5) {
                    Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Image(systemName: StemStyle.icon(stem)).foregroundStyle(color)
                    Text(stem.capitalized).font(.callout.weight(.medium))
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 2)
            toggle("S", on: song.mix[stem].solo, tint: .yellow, help: "Solo (S)") { player.toggleSolo(stem) }
            toggle("M", on: song.mix[stem].mute, tint: .red, help: "Mute (M)") { player.toggleMute(stem) }
            if canNote {
                toggle("♪", on: showingNotes, tint: color, help: "Notes (N)") {
                    if showingNotes { player.showNotes.remove(stem) } else { player.showNotes.insert(stem) }
                }
            }
        }
        .padding(.trailing, 10)
    }

    private var noteHandle: some View {
        Image(systemName: "pianokeys")
            .foregroundStyle(.secondary)
            .padding(.trailing, 12)
            .frame(height: 40)
            .contentShape(Rectangle())
            .onDrag {
                guard let url = player.midiFile(stem: stem) else { return NSItemProvider() }
                let p = NSItemProvider(object: url as NSURL)
                p.suggestedName = url.lastPathComponent
                return p
            } preview: {
                Label("\(song.exportName(stem)).mid", systemImage: "music.note.list").padding(6).background(color.opacity(0.85), in: Capsule())
            }
            .help("Drag a MIDI clip of the \(stem) notes (selection only, if there is one)")
            .accessibilityLabel("Drag \(stem) MIDI")
    }

    private func toggle(_ label: String, on: Bool, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.caption.weight(.bold)).frame(width: 20, height: 18)
                .background(on ? tint.opacity(0.85) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(on ? Color.black : .primary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(help) \(stem)")
        .accessibilityValue(on ? "on" : "off")
    }
}

/// Arrangement commands, Ableton keys. `stem` set (a lane's context menu): act on that stem.
/// nil (menu bar): act on the selected stem, or all stems for a ruler selection.
struct ArrangeMenu: View {
    let player: PlayerModel
    var stem: String?

    var body: some View {
        let sel = player.selection != nil, track = stem ?? player.selectedStem
        Group {
            Button("Split") { target { player.split() } }.keyboardShortcut("e")
            Button(sel ? "Duplicate Selection" : "Duplicate Track") { target { player.duplicate() } }
                .keyboardShortcut("d")
                .disabled(!sel && track == nil)
            Button("Reverse") { target { player.reverse() } }.keyboardShortcut("r")
            Button("Crop to Selection") { target { player.crop() } }.keyboardShortcut("j", modifiers: [.command, .shift]).disabled(!sel)
            Button("Delete Selection") { target { player.deleteRegion() } }.disabled(!sel)
            Divider()
            Button("Duplicate Track") { if let track { player.duplicateTrack(track) } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(track == nil)
            if let track, player.isExtraStem(track) {
                Button("Delete Track", role: .destructive) { player.deleteTrack(track) }
            }
        }
        .disabled(AppModel.shared.editJob != nil)
    }

    private func target(_ action: () -> Void) {
        if let stem { player.selectedStem = stem }
        action()
    }
}

struct WaveformLane: View {
    let peaks: [Float]
    let color: Color
    let dimmed: Bool

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let cols = max(1, Int(size.width / 2))
            let per = Double(peaks.count) / Double(cols)
            let mid = size.height / 2
            var path = Path()
            for c in 0..<cols {
                let a = Int(Double(c) * per), b = max(a + 1, Int(Double(c + 1) * per))
                var m: Float = 0
                for i in a..<min(b, peaks.count) { m = max(m, peaks[i]) }
                let h = max(0.5, CGFloat(min(1, m)) * mid)
                path.addRect(CGRect(x: CGFloat(c) * 2, y: mid - h, width: 1.4, height: h * 2))
            }
            ctx.fill(path, with: .color(color.opacity(dimmed ? 0.25 : 0.9)))
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}

struct PianoRollLane: View {
    let notes: [NoteEvent]?
    let loading: Bool
    let duration: Double
    let color: Color
    let stem: String
    let transcribe: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04))
            if let notes, !notes.isEmpty {
                let lo = notes.map(\.pitch).min()!, hi = notes.map(\.pitch).max()!
                Canvas { ctx, size in
                    let span = CGFloat(max(hi - lo + 1, 12))
                    let rowH = size.height / span
                    let d = max(duration, 0.01)
                    var path = Path()
                    for n in notes {
                        let x = CGFloat(n.start / d) * size.width
                        let w = max(1, CGFloat((n.end - n.start) / d) * size.width)
                        let y = size.height - CGFloat(n.pitch - lo + 1) * rowH
                        path.addRect(CGRect(x: x, y: y, width: w, height: max(1.5, rowH - 0.5)))
                    }
                    ctx.fill(path, with: .color(color))
                }
                .accessibilityElement()
                .accessibilityLabel("\(stem.capitalized) notes")
                .accessibilityValue("\(notes.count) notes, range \(Self.noteName(lo)) to \(Self.noteName(hi))")
            } else if loading {
                ProgressView().controlSize(.small)
            } else if notes != nil {
                Text("No notes found").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Transcribe", action: transcribe).controlSize(.small)
            }
        }
    }

    static func noteName(_ midi: Int) -> String { PitchClass.name(midi) + "\(midi / 12 - 1)" }
}
