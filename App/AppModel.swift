import AppKit
import AVFoundation
import os
import StemAnalysis
import StemLink
import StemMix
import StemSeparation
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

let log = Logger(subsystem: "app.stemsplitter", category: "app")

@Observable
final class SplitJob: Identifiable {
    enum State: Equatable {
        case waiting, splitting(Double), failed(String), cancelled
    }

    let id = UUID()
    let source: URL
    let range: ClosedRange<Double>?
    let layout: StemLayout
    var state: State = .waiting
    var task: Task<Void, Never>?

    init(source: URL, range: ClosedRange<Double>?, layout: StemLayout) {
        self.source = source
        self.range = range
        self.layout = layout
    }

    var title: String { source.deletingPathExtension().lastPathComponent }
}

/// In-flight reverse/cut edit; audio runs detached, the entry appears when done.
struct EditJob: Identifiable {
    let id = UUID()
    let title: String
}

/// One spotDL link download. MP3s land in Downloads/ and then split like dropped files.
@Observable
final class DownloadJob: Identifiable {
    enum State: Equatable {
        case waiting, resolving, downloading(String), failed(String), cancelled

        var isDownloading: Bool { if case .downloading = self { return true }; return false }
    }

    let id = UUID()
    let link: MusicLink
    var state: State = .waiting
    var task: Task<Void, Never>?

    init(link: MusicLink) { self.link = link }

    var label: String {
        switch link {
        case .spotifyTrack: "Spotify track"
        case .spotifyAlbum: "Spotify album"
        case .spotifyPlaylist: "Spotify playlist"
        case .youtube: "YouTube video"
        }
    }

    /// Counts so far, then the last track spotDL touched.
    static func status(_ p: SpotdlProgress) -> String {
        var parts: [String] = []
        if p.finishedCount > 0 { parts.append("\(p.finishedCount) downloaded") }
        if p.skippedCount > 0 { parts.append("\(p.skippedCount) skipped") }
        if let f = p.lastFinished { parts.append(f) }
        return parts.isEmpty ? "Downloading…" : parts.joined(separator: " · ")
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var songs: [Song] = []
    var queue: [SplitJob] = []
    var downloads: [DownloadJob] = []
    var editJob: EditJob?
    private(set) var selection: Song?
    private(set) var player: PlayerModel?
    var errorMessage: String?
    var lastTimings: [String: Double] = [:]

    /// Transcription runs eagerly only up to this duration; longer files get a "Transcribe" button.
    static let eagerTranscribeLimit = 15 * 60.0

    let libraryURL: URL = {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        let url = music.appendingPathComponent("StemSplitter", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var cascade: CascadePipeline?
    private var transcriber: NoteTranscriber?
    private var running = false
    private var downloadRunning = false

    init() { reloadLibrary() }

    func select(_ song: Song?) {
        guard song != selection || (song != nil && player == nil) else { return }
        player?.teardown()
        selection = song
        player = song.map { PlayerModel(song: $0) }
    }

    func reloadLibrary() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: nil)) ?? []
        let loaded = dirs.compactMap(Song.load).sorted { $0.info.created > $1.info.created }
        // Keep existing objects (their player state) where the folder is unchanged.
        songs = loaded.map { new in songs.first { $0.folder == new.folder } ?? new }
        if let s = selection, !songs.contains(s) { select(nil) }
    }

    static func modelURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mlmodelc")
    }

    // MARK: Queue

    static let supportedTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .mpeg4Audio]

    func enqueue(_ urls: [URL], range: ClosedRange<Double>? = nil) {
        for url in urls {
            let id = jobID(url, range: range, layout: .four)
            if let existing = songs.first(where: { $0.id == id }) {
                select(existing)  // double drop focuses the existing split
                continue
            }
            queue.append(SplitJob(source: url, range: range, layout: .four))
        }
        pump()
    }

    func cancel(_ job: SplitJob) {
        if job.task == nil { queue.removeAll { $0.id == job.id } } else { job.task?.cancel() }
    }

    func jobID(_ url: URL, range: ClosedRange<Double>?, layout: StemLayout) -> String {
        var id = ContentHash.of(url) + "-" + layout.rawValue
        if let range { id += String(format: "-%.1f-%.1f", range.lowerBound, range.upperBound) }
        return id
    }

    private func pump() {
        guard !running, let job = queue.first(where: { $0.state == .waiting }) else {
            updateDock()
            return
        }
        running = true
        job.task = Task { await run(job) }
    }

    private func run(_ job: SplitJob) async {
        let folder = uniqueFolder(job.title)
        defer {
            running = false
            if !isFailed(job) { queue.removeAll { $0.id == job.id } }  // failures stay until dismissed
            if !queue.contains(where: { $0.state == .waiting }) { notifyQueueDone() }
            pump()
        }
        let scoped = job.source.startAccessingSecurityScopedResource()
        defer { if scoped { job.source.stopAccessingSecurityScopedResource() } }
        do {
            job.state = .splitting(0)
            if cascade == nil {
                guard let rofURL = Self.modelURL("melband-roformer"), let hdURL = Self.modelURL("htdemucs") else {
                    throw SeparatorError.modelMissing("app bundle")
                }
                cascade = try CascadePipeline(vocals: MelBandRoformerSeparator(modelURL: rofURL),
                                              residual: HTDemucsSeparator(modelURL: hdURL))
            }
            let id = jobID(job.source, range: job.range, layout: job.layout)
            let asset = AVURLAsset(url: job.source)
            let isVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
            let sourceRate = try? await asset.loadTracks(withMediaType: .audio).first?.load(.formatDescriptions).first
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }

            let request = SplitRequest(source: job.source, outputDirectory: folder, range: job.range, layout: job.layout)
            let pipeline = cascade!
            let signpost = OSSignposter(logger: log)
            let state = signpost.beginInterval("split")
            let result = try await Task.detached(priority: .userInitiated) {
                try await pipeline.run(request) { p in Task { @MainActor in job.state = .splitting(p); self.updateDock() } }
            }.value
            signpost.endInterval("split", state)
            lastTimings["split"] = result.elapsed
            log.info("split \(job.title, privacy: .public) \(result.duration)s audio in \(result.elapsed)s")

            let info = SongInfo(id: id, title: job.title, sourcePath: job.source.path,
                                sourceBookmark: try? job.source.bookmarkData(options: .withSecurityScope),
                                isVideo: isVideo, layout: job.layout, range: job.range,
                                sourceSampleRate: sourceRate, duration: result.duration,
                                splitSeconds: result.elapsed, created: Date())
            let song = Song(folder: folder, info: info)
            song.save()
            songs.insert(song, at: 0)
            if selection == nil || queue.count == 1 { select(song) }
            analyze(song)
        } catch {
            try? FileManager.default.removeItem(at: folder)  // pipeline already deleted partial stems
            if (error as? SplitError) == .cancelled || error is CancellationError || Task.isCancelled {
                job.state = .cancelled
            } else {
                log.error("split failed \(job.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
                job.state = .failed(error.localizedDescription)
            }
        }
    }

    private func isFailed(_ j: SplitJob) -> Bool { if case .failed = j.state { return true } else { return false } }

    func dismiss(_ job: SplitJob) { queue.removeAll { $0.id == job.id } }

    // MARK: Link downloads (spotDL)

    /// Downloaded MP3s keep here (not caches) so re-pasting a link skips the fetch and
    /// re-splitting still finds its source.
    static let downloadsURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StemSplitter/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Returns false when that link is already downloading (duplicate paste).
    @discardableResult
    func submitLink(_ link: MusicLink) -> Bool {
        if downloads.contains(where: { $0.link == link && $0.task != nil }) { return false }
        downloads.append(DownloadJob(link: link))
        pumpDownloads()
        return true
    }

    func cancel(_ job: DownloadJob) {
        if job.task == nil { downloads.removeAll { $0.id == job.id } } else { job.task?.cancel() }
    }

    func dismiss(_ job: DownloadJob) { downloads.removeAll { $0.id == job.id } }

    func retry(_ job: DownloadJob) {
        job.state = .waiting
        pumpDownloads()
    }

    private func pumpDownloads() {
        guard !downloadRunning, let job = downloads.first(where: { $0.state == .waiting }) else { return }
        downloadRunning = true
        job.task = Task { await runDownload(job) }
    }

    private func runDownload(_ job: DownloadJob) async {
        defer {
            downloadRunning = false
            job.task = nil
            pumpDownloads()
        }
        guard let runner = SpotdlRunner.locate() else {
            job.state = .failed(SpotdlError.notFound.errorDescription ?? "spotDL is not installed.")
            return
        }
        job.state = .resolving
        do {
            let files = try await runner.download(job.link.query, outputDirectory: Self.downloadsURL,
                                                  homeDirectory: Self.downloadsURL) { p in
                Task { @MainActor in
                    if job.state.isDownloading || job.state == .resolving {
                        job.state = .downloading(DownloadJob.status(p))
                    }
                }
            }
            downloads.removeAll { $0.id == job.id }  // success leaves the download list
            enqueue(files)  // joins the normal split queue; a known file re-selects its song
        } catch let error as SpotdlError {
            job.state = error == .cancelled ? .cancelled : .failed(error.errorDescription ?? "Download failed.")
        } catch {
            job.state = .failed(error.localizedDescription)
        }
    }

    private func uniqueFolder(_ title: String) -> URL {
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = libraryURL.appendingPathComponent(safe)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = libraryURL.appendingPathComponent("\(safe) \(n)")
            n += 1
        }
        return url
    }

    // MARK: Analysis + transcription

    /// Key/BPM/chords, then notes. Each step fails independently and never blocks the stems.
    func analyze(_ song: Song, force: Bool = false) {
        if song.analysis == nil || force {
            song.analyzing = true
            let stems = Dictionary(uniqueKeysWithValues: song.stems.map { ($0.name, $0.url) })
            Task.detached(priority: .userInitiated) {
                let t0 = Date()
                let inputs = StemAnalyzer.inputs(stems: stems)
                let result = try? StemAnalyzer.analyze(rhythm: inputs.rhythm, harmony: inputs.harmony)
                await MainActor.run {
                    song.analyzing = false
                    song.analysis = result ?? AnalysisResult(tempo: nil, key: nil, chords: [])
                    song.saveAnalysis()
                    self.lastTimings["analysis"] = Date().timeIntervalSince(t0)
                }
            }
        }
        if song.info.duration <= Self.eagerTranscribeLimit {
            for stem in StemAnalyzer.transcribable where song.stemNames.contains(stem) && song.notes[stem] == nil {
                transcribe(song, stem: stem)
            }
        }
    }

    func transcribe(_ song: Song, stem: String) {
        guard !song.transcribing.contains(stem) else { return }
        if transcriber == nil, let url = Self.modelURL("basic-pitch") { transcriber = try? NoteTranscriber(modelURL: url) }
        guard let transcriber else { return }
        song.transcribing.insert(stem)
        let url = song.stemURL(stem)
        Task.detached(priority: .utility) {
            let notes = (try? StemAnalyzer.transcribe(stem: stem, url: url, with: transcriber)) ?? []
            await MainActor.run {
                song.notes[stem] = notes
                song.transcribing.remove(stem)
                song.saveNotes(stem)
            }
        }
    }

    // MARK: Library actions

    func delete(_ song: Song) {
        if selection == song { select(nil) }
        songs.removeAll { $0 == song }
        try? FileManager.default.trashItem(at: song.folder, resultingItemURL: nil)
    }

    // MARK: Edits — new library entries, originals never touched

    func reverseCopy(_ song: Song) {
        editCopy(song, title: song.title + " (Reversed)") { payload, folder in
            try SongEditor.writeReversed(payload, to: folder)
        }
    }

    func cutCopy(_ song: Song, range: ClosedRange<Double>) {
        guard range.lowerBound > 0.01 || range.upperBound < song.info.duration - 0.01 else {
            errorMessage = "That selection is the whole song — nothing would be left."
            return
        }
        editCopy(song, title: song.title + " (Cut)") { payload, folder in
            try SongEditor.writeCut(payload, range: range, to: folder)
        }
    }

    private func editCopy(_ song: Song, title: String,
                          write: @escaping (SongEditor.Payload, URL) throws -> Double) {
        guard editJob == nil else { return }
        // The copy gets plain files: arranged stems are bounced, duplicates get their own file.
        var mix = song.mix, notes = song.notes
        var peaks: [String: [Float]] = [:]
        for name in song.stemNames {
            peaks[name] = song.arrangedPeaks(name)
            if mix[name].clips != nil { notes[name] = nil }  // stale once rearranged
            mix[name].clips = nil
            mix[name].source = nil
        }
        let arranged = song.stemNames.filter { song.mix[$0].clips != nil }
        let stems = song.stems, liveMix = song.mix
        let payloadBase = SongEditor.Payload(stems: stems, peaks: peaks, notes: notes,
                                             analysis: song.analysis, mix: mix, info: song.info)
        let folder = uniqueFolder(title)
        editJob = EditJob(title: title)
        Task.detached(priority: .userInitiated) {
            let bounceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: bounceDir) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var payload = payloadBase
                if !arranged.isEmpty {
                    try FileManager.default.createDirectory(at: bounceDir, withIntermediateDirectories: true)
                    let graph = try MixGraph(stems: stems, settings: liveMix)
                    let bounced = try stems.map { s -> (name: String, url: URL) in
                        guard arranged.contains(s.name) else { return s }
                        let url = bounceDir.appendingPathComponent("\(s.name).wav")
                        try graph.bounce(s.name, to: url)
                        return (s.name, url)
                    }
                    payload = SongEditor.Payload(stems: bounced, peaks: peaks, notes: notes,
                                                 analysis: payloadBase.analysis, mix: mix, info: payloadBase.info)
                }
                let duration = try write(payload, folder)
                // Edited stems no longer line up with the source video, so the copy is audio-only.
                var info = payload.info
                info.id = payload.info.id + "-" + UUID().uuidString.prefix(6)
                info.title = title
                info.isVideo = false
                info.range = nil
                info.duration = duration
                info.created = Date()
                info.derivedFrom = payload.info.id
                let newInfo = info
                try JSONEncoder().encode(newInfo).write(to: folder.appendingPathComponent("song.json"))
                await MainActor.run {
                    self.editJob = nil
                    let song = Song(folder: folder, info: newInfo)
                    self.songs.insert(song, at: 0)
                    self.select(song)
                }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                await MainActor.run {
                    self.editJob = nil
                    self.errorMessage = "Couldn't edit the song: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Undo applies to the selected song when it is an edit copy whose source still exists.
    var undoTarget: Song? {
        guard let cur = selection, let src = cur.info.derivedFrom else { return nil }
        return songs.first { $0.id == src }
    }

    /// Reverts the selected edit copy: copy to Trash, back to the song it came from.
    func undoEdit() {
        guard let cur = selection, let target = undoTarget else { return }
        delete(cur)
        select(target)
    }

    // MARK: Dock + notifications

    private func updateDock() {
        let active = queue.compactMap { j -> Double? in if case .splitting(let p) = j.state { return p } else { return nil } }.first
        NSApp?.dockTile.badgeLabel = active.map { "\(Int($0 * 100))%" } ?? (queue.isEmpty ? nil : "\(queue.count)")
    }

    private func notifyQueueDone() {
        guard !NSApp.isActive else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = "Stems ready"
            content.body = "Your split queue is done."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    var diagnostics: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        var lines = ["StemSplitter \(v)", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "analysis v\(AnalysisResult.currentVersion)", "library \(libraryURL.path) (\(songs.count) songs)"]
        for (k, t) in lastTimings.sorted(by: { $0.key < $1.key }) { lines.append(String(format: "last %@: %.2fs", k, t)) }
        if let s = selection, let a = s.analysis {
            lines.append(String(format: "selected: bpm %.1f conf %.2f, key %@ conf %.2f, %d chords", a.tempo?.bpm ?? 0,
                                a.tempo?.confidence ?? 0, a.key?.key.name ?? "—", a.key?.confidence ?? 0, a.chords.count))
        }
        return lines.joined(separator: "\n")
    }
}
