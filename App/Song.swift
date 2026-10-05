import CryptoKit
import Foundation
import StemAnalysis
import StemMix
import StemSeparation

/// song.json. The folder it lives in is the library entry: plain files are the database.
struct SongInfo: Codable, Equatable {
    var id: String              // content hash of the source (dedupe key)
    var title: String
    var sourcePath: String
    var sourceBookmark: Data?   // security-scoped, for video preview/export after relaunch
    var isVideo: Bool
    var layout: StemLayout
    var range: ClosedRange<Double>?
    var sourceSampleRate: Double?
    var duration: Double
    var splitSeconds: Double
    var created: Date
    /// For edit copies (reversed / cut): id of the song this one was derived from. Backs undo.
    var derivedFrom: String?
    /// Duplicated tracks ("vocals 2"), appended after the layout's stems.
    var extraStems: [String]?
}

/// One library entry, loaded from its folder.
@Observable
final class Song: Identifiable, Hashable {
    let folder: URL
    var info: SongInfo
    var analysis: AnalysisResult?
    var notes: [String: [NoteEvent]] = [:]
    var transcribing: Set<String> = []
    var analyzing = false
    var mix: MixSettings
    var peaks: [String: [Float]] = [:]

    var id: String { info.id }
    var title: String { info.title }
    var stemNames: [String] { SplitPipeline.stemNames(info.layout, sources: ["drums", "bass", "other", "vocals"]) + (info.extraStems ?? []) }
    var stems: [(name: String, url: URL)] { stemNames.map { ($0, stemURL($0)) } }
    /// Duplicated tracks share their source stem's file and peaks.
    func source(_ name: String) -> String { mix[name].source ?? name }
    func stemURL(_ name: String) -> URL { folder.appendingPathComponent("\(source(name)).wav") }
    func clips(_ name: String) -> [Clip] { mix[name].clips ?? Clips.whole(info.duration) }

    /// Waveform peaks as arranged by the stem's clips (gaps 0), same bins as the source peaks.
    func arrangedPeaks(_ name: String) -> [Float] {
        let src = peaks[name] ?? peaks[source(name)] ?? []
        guard let clips = mix[name].clips else { return src }
        let pps = Double(SplitPipeline.peaksPerSecond)
        return src.indices.map { i in
            let t = (Double(i) + 0.5) / pps
            guard let k = Clips.at(clips, t) else { return 0 }
            let j = Int(clips[k].sourceTime(t) * pps)
            return src.indices.contains(j) ? src[j] : 0
        }
    }

    init(folder: URL, info: SongInfo) {
        self.folder = folder
        self.info = info
        mix = (try? JSONDecoder().decode(MixSettings.self, from: Data(contentsOf: folder.appendingPathComponent("mix.json")))) ?? MixSettings()
        for name in stemNames {
            if let d = try? Data(contentsOf: SplitPipeline.peaksURL(folder, name)) {
                peaks[name] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
            if let d = try? Data(contentsOf: notesURL(name)), let n = try? JSONDecoder().decode([NoteEvent].self, from: d) {
                notes[name] = n
            }
        }
        if let d = try? Data(contentsOf: analysisURL), let a = try? JSONDecoder().decode(AnalysisResult.self, from: d),
           a.version == AnalysisResult.currentVersion {
            analysis = a
        }
    }

    static func load(_ folder: URL) -> Song? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("song.json")),
              let info = try? JSONDecoder().decode(SongInfo.self, from: d),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(SplitPipeline.stemNames(info.layout, sources: ["vocals"]).first!).wav").path)
        else { return nil }
        return Song(folder: folder, info: info)
    }

    var analysisURL: URL { folder.appendingPathComponent("analysis.json") }
    func notesURL(_ stem: String) -> URL { folder.appendingPathComponent("notes-\(stem).json") }

    func save() { try? JSONEncoder().encode(info).write(to: folder.appendingPathComponent("song.json")) }
    func saveMix() { try? JSONEncoder().encode(mix).write(to: folder.appendingPathComponent("mix.json")) }
    func saveAnalysis() { if let analysis { try? JSONEncoder().encode(analysis).write(to: analysisURL) } }
    func saveNotes(_ stem: String) { try? JSONEncoder().encode(notes[stem] ?? []).write(to: notesURL(stem)) }

    /// Resolves the original source (video preview / video export). Caller balances with stopAccessing.
    func resolveSource() -> URL? {
        if let b = info.sourceBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: b, options: .withSecurityScope, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                return url
            }
        }
        let url = URL(fileURLWithPath: info.sourcePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Display helpers (all follow the pitch control)

    var semitones: Int { Int(mix.pitch.rounded()) }
    var key: MusicalKey? { analysis?.key?.key.transposed(semitones) }

    /// "Title - Vocals - 124bpm Am"
    func exportName(_ stem: String?) -> String {
        var parts = [title]
        if let stem { parts.append(stem.capitalized) }
        var tags: [String] = []
        if let bpm = analysis?.tempo.map({ $0.bpm * mix.tempo }) { tags.append("\(Int(bpm.rounded()))bpm") }
        if let key { tags.append(key.name) }
        if !tags.isEmpty { parts.append(tags.joined(separator: " ")) }
        return parts.joined(separator: " - ").replacingOccurrences(of: "/", with: "-")
    }

    static func == (a: Song, b: Song) -> Bool { a.folder == b.folder }
    func hash(into h: inout Hasher) { h.combine(folder) }
}

enum ContentHash {
    /// SHA-256 of size + first and last MiB. Fast on multi-GB videos; collisions don't matter here.
    static func of(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return UUID().uuidString }
        defer { try? h.close() }
        var hasher = SHA256()
        let size = (try? h.seekToEnd()) ?? 0
        withUnsafeBytes(of: size) { hasher.update(bufferPointer: $0) }
        try? h.seek(toOffset: 0)
        if let d = try? h.read(upToCount: 1 << 20) { hasher.update(data: d) }
        if size > 2 << 20 {
            try? h.seek(toOffset: size - (1 << 20))
            if let d = try? h.read(upToCount: 1 << 20) { hasher.update(data: d) }
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
