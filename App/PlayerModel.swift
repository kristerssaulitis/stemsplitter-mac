import AVFoundation
import StemAnalysis
import StemMix
import StemSeparation

/// Playback + selection state for the song on screen. One per selected song.
@MainActor
@Observable
final class PlayerModel {
    let song: Song
    private(set) var graph: MixGraph?
    var currentTime: Double = 0
    var isPlaying = false
    /// Drag-selected region: loop range and "export region" source.
    var selection: ClosedRange<Double>?
    var looping = false
    var selectedStem: String?
    var showNotes: Set<String> = []
    var errorMessage: String?
    /// Timeline zoom: 1 = whole song fits. `maxZoom` is set by the timeline from its width.
    private(set) var zoom: Double = 1
    var maxZoom: Double = 64
    /// After the next zoom change, scroll so this time sits at the left edge.
    var pendingScrollTime: Double?
    var exportSelectionOnly = false
    var exportProgress: Double?
    var exportTask: Task<Void, Never>?
    var exportRange: ClosedRange<Double>? { exportSelectionOnly ? selection : nil }
    private var timer: Timer?
    private var configObserver: NSObjectProtocol?

    var duration: Double { song.info.duration }

    init(song: Song) {
        self.song = song
        build()
    }

    private func build() {
        do {
            graph = try MixGraph(stems: song.stems, settings: song.mix, bpm: song.analysis?.tempo?.bpm)
            if let graph {
                configObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: graph.engine, queue: .main) { [weak self] _ in
                    // Output device changed (headphones unplugged): rebuild from settings, keep the playhead.
                    Task { @MainActor in self?.rebuild() }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rebuild() {
        let t = currentTime
        stop()
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        build()
        currentTime = t
    }

    func teardown() {
        stop()
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        graph?.engine.stop()
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let graph else { return }
        graph.bpm = song.analysis?.tempo?.bpm
        let loop = looping ? selection : nil
        if currentTime >= duration - 0.05 { currentTime = loop?.lowerBound ?? 0 }
        graph.play(from: currentTime, loop: loop)
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        graph?.pause()
        currentTime = graph?.currentTime ?? currentTime
        stop()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    private func tick() {
        guard let graph else { return }
        currentTime = graph.currentTime
        if !looping && currentTime >= duration - 0.01 { pause(); currentTime = duration }
    }

    func seek(_ t: Double) {
        currentTime = max(0, min(t, duration))
        if isPlaying { play() }
    }

    func toggleLoop() {
        looping.toggle()
        if looping && selection == nil { selection = currentTime...min(duration, currentTime + 4) }
        if isPlaying { play() }
    }

    func setLoopStart() {
        let end = max(selection?.upperBound ?? duration, currentTime + 0.05)
        selection = currentTime...min(end, duration)
        if isPlaying && looping { play() }
    }

    func setLoopEnd() {
        let start = min(selection?.lowerBound ?? 0, currentTime - 0.05)
        selection = max(0, start)...currentTime
        if isPlaying && looping { play() }
    }

    // MARK: Zoom

    func setZoom(_ z: Double) { zoom = max(1, min(z, maxZoom)) }
    func zoomIn() { setZoom(zoom * 2) }
    func zoomOut() { setZoom(zoom / 2) }
    func zoomToFit() { setZoom(1) }

    func zoomToSelection() {
        guard let sel = selection, sel.upperBound > sel.lowerBound else { return }
        let len = sel.upperBound - sel.lowerBound
        pendingScrollTime = max(0, sel.lowerBound - len * 0.05)
        setZoom(duration / (len * 1.1))
    }

    // MARK: Mix

    /// Mutate settings → live graph update → mix.json.
    func updateMix(_ change: (inout MixSettings) -> Void) {
        change(&song.mix)
        song.mix.pitch = max(-12, min(12, song.mix.pitch))
        song.mix.tempo = max(0.5, min(1.5, song.mix.tempo))
        graph?.apply(song.mix)
        song.saveMix()
    }

    func toggleSolo(_ stem: String) { updateMix { $0[stem].solo.toggle() } }
    func toggleMute(_ stem: String) { updateMix { $0[stem].mute.toggle() } }
    func nudgePitch(_ d: Double) { updateMix { $0.pitch = ($0.pitch + d).rounded() } }
    func resetStem(_ stem: String) { updateMix { $0.stems[stem] = StemSettings() } }

    /// Tempo steps are BPM when detection gave a reference, else percent (base 100).
    func nudgeTempo(_ d: Double) {
        let base = song.analysis?.tempo?.bpm ?? 100
        updateMix { $0.tempo = ($0.tempo * base + d) / base }
    }

    // MARK: Whole-song edits (new library copies)

    func reverseSong() { AppModel.shared.reverseCopy(song) }

    func deleteSelection() {
        guard let sel = selection, sel.upperBound - sel.lowerBound > 0.05 else { return }
        AppModel.shared.cutCopy(song, range: sel)
    }

    // MARK: Arrangement (clips, Ableton-style: instant, unlimited undo, files never touched)

    /// Undo unit: the track list plus every stem's clips and source. Mixer/FX moves are not undo steps.
    struct Snapshot {
        var extraStems: [String]?
        var mix: MixSettings
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    var snapshot: Snapshot { Snapshot(extraStems: song.info.extraStems, mix: song.mix) }
    var canUndo: Bool { !undoStack.isEmpty || AppModel.shared.undoTarget != nil }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Arrangement undo first; past the oldest step, back to the song this edit copy came from.
    func undo() {
        guard let s = undoStack.popLast() else { AppModel.shared.undoEdit(); return }
        redoStack.append(snapshot)
        restore(s)
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(s)
    }

    /// Records `before` as one undo step, after the change was made.
    func commit(_ before: Snapshot) {
        guard before.extraStems != song.info.extraStems || before.mix != song.mix else { return }
        undoStack.append(before)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func restore(_ s: Snapshot) {
        let tracksChanged = s.extraStems != song.info.extraStems
        song.info.extraStems = s.extraStems
        song.save()
        let names = Set(song.mix.stems.keys).union(s.mix.stems.keys)
        updateMix { m in
            for name in names {
                m[name].clips = s.mix[name].clips
                m[name].source = s.mix[name].source
            }
        }
        if tracksChanged { reload() }
    }

    func isExtraStem(_ stem: String) -> Bool { song.info.extraStems?.contains(stem) == true }

    /// The lanes an edit applies to: the selected stem, else all of them (selection dragged on the ruler).
    var editTargets: [String] { selectedStem.map { [$0] } ?? song.stemNames }

    private func edit(_ change: (String, [Clip]) -> [Clip]) {
        let before = snapshot
        let new = editTargets.map { ($0, change($0, song.clips($0))) }
        updateMix { m in for (stem, clips) in new { m[stem].clips = clips } }
        commit(before)
    }

    /// ⌘E: split at the selection's edges, else at the playhead.
    func split() {
        let cuts = selection.map { [$0.lowerBound, $0.upperBound] } ?? [currentTime]
        edit { _, c in cuts.reduce(c) { Clips.split($0, at: $1) } }
    }

    /// ⌘D: copy the selection right after itself and move the selection onto the copy (press again to keep
    /// repeating it). No selection: duplicate the track.
    func duplicate() {
        guard let sel = selection else {
            if let stem = selectedStem { duplicateTrack(stem) }
            return
        }
        edit { _, c in Clips.duplicate(c, sel, duration: duration) }
        let len = sel.upperBound - sel.lowerBound
        if sel.upperBound + 0.01 < duration { selection = sel.upperBound...min(duration, sel.upperBound + len) }
    }

    /// ⌫: remove the selected audio, leaving a gap.
    func deleteRegion() {
        guard let sel = selection else { return }
        edit { _, c in Clips.carve(c, sel) }
    }

    /// ⇧⌘J: keep only the selection.
    func crop() {
        guard let sel = selection else { return }
        edit { _, c in Clips.crop(c, sel) }
    }

    /// R: play the selection backwards, else the clip under the playhead.
    func reverse() {
        let fm = FileManager.default
        let missing = Set(editTargets.map { song.stemURL($0) }).filter { !fm.fileExists(atPath: StemEdit.reversedURL($0).path) }
        let apply = { [self] in
            if let sel = selection {
                edit { _, c in Clips.reverse(c, sel) }
            } else {
                let t = currentTime
                edit { _, c in Clips.at(c, t).map { Clips.reverse(c, c[$0].start...c[$0].end) } ?? c }
            }
        }
        guard !missing.isEmpty else { return apply() }
        // First reverse of a stem renders its backwards copy once (well under a second); after that it's instant.
        let app = AppModel.shared
        guard app.editJob == nil else { return }
        app.editJob = EditJob(title: "reversed audio")
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    for url in missing {
                        let dst = StemEdit.reversedURL(url)
                        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString).wav")
                        do {
                            try StemEdit.writeReversed(from: url, to: tmp)
                            try? FileManager.default.removeItem(at: dst)
                            try FileManager.default.moveItem(at: tmp, to: dst)
                        } catch {
                            try? FileManager.default.removeItem(at: tmp)
                            throw error
                        }
                    }
                }
            }.value
            app.editJob = nil
            if case .failure(let error) = result {
                errorMessage = "Couldn't reverse: \(error.localizedDescription)"
            } else {
                apply()
            }
        }
    }

    /// "vocals" → "vocals 2": a new track playing the same file (no copy), same clips and FX.
    func duplicateTrack(_ stem: String) {
        let before = snapshot
        let base = StemStyle.base(stem)
        var n = 2
        while song.stemNames.contains("\(base) \(n)") { n += 1 }
        let name = "\(base) \(n)"
        var settings = song.mix[stem]
        settings.source = song.source(stem)
        settings.solo = false
        updateMix { $0.stems[name] = settings }
        song.info.extraStems = (song.info.extraStems ?? []) + [name]
        song.save()
        commit(before)
        selectedStem = name
        reload()
    }

    /// Only duplicated tracks can be deleted. Its settings stay in mix.json so undo restores it whole.
    func deleteTrack(_ stem: String) {
        guard isExtraStem(stem) else { return }
        let before = snapshot
        song.info.extraStems?.removeAll { $0 == stem }
        song.save()
        commit(before)
        if selectedStem == stem { selectedStem = nil }
        showNotes.remove(stem)
        reload()
    }

    /// Live clip change while dragging a clip edge or body; the gesture calls `commit` when it ends.
    func previewClips(_ stem: String, _ clips: [Clip]) { updateMix { $0[stem].clips = clips } }

    /// The track list changed: reopen the stems in a fresh graph.
    private func reload() {
        pause()
        graph?.engine.stop()
        rebuild()
    }

    // MARK: Drag-out files

    var cacheDir: URL {
        let d = song.folder.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// File for dragging a stem out. Neutral settings → hard link to the stem (instant, named with
    /// key/BPM). Otherwise the stem is rendered through its FX chain first.
    /// ponytail: renders synchronously (well under a second for a song). Async file promise if it ever lags.
    func dragFile(stem: String) -> URL? {
        let url = cacheDir.appendingPathComponent(song.exportName(stem) + ".wav")
        try? FileManager.default.removeItem(at: url)
        if song.mix.isNeutral(stem) && song.mix[stem].volume == 1 {
            if (try? FileManager.default.linkItem(at: song.stemURL(stem), to: url)) != nil { return url }
            if (try? FileManager.default.copyItem(at: song.stemURL(stem), to: url)) != nil { return url }
            return nil
        }
        do {
            try ExportRenderer.render(stems: song.stems, settings: song.mix, bpm: song.analysis?.tempo?.bpm, only: stem,
                                      range: nil, format: ExportFormat(), sourceSampleRate: nil, to: url)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// MIDI clip for a stem's notes, transposed with the pitch control. Region-limited when a selection exists.
    func midiFile(stem: String) -> URL? {
        guard let notes = song.notes[stem] else { return nil }
        let shift = song.semitones
        var clip = notes.map { n -> NoteEvent in var n = n; n.pitch += shift; return n }
        var name = song.exportName(stem)
        if let sel = selection {
            clip = clip.filter { $0.end > sel.lowerBound && $0.start < sel.upperBound }.map {
                var n = $0
                n.start = max(0, n.start - sel.lowerBound)
                n.end = min(sel.upperBound, n.end) - sel.lowerBound
                return n
            }
            name += String(format: " - %.0fs", sel.lowerBound)
        }
        // Tempo control stretches time; MIDI keeps musical time by writing at the stretched BPM.
        let tempo = song.mix.tempo
        clip = clip.map { var n = $0; n.start /= tempo; n.end /= tempo; return n }
        let url = cacheDir.appendingPathComponent(name + ".mid")
        do {
            try MIDIWriter.data(notes: clip, bpm: (song.analysis?.tempo?.bpm ?? 120) * tempo, name: "\(song.title) \(stem)").write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
