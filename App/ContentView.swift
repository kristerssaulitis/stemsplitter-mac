import AVFoundation
import PhotosUI
import StemSeparation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model = AppModel.shared
    @State private var showInspector = ProcessInfo.processInfo.environment["SS_NOINSPECTOR"] == nil
    @State private var dropTargeted = false
    @State private var photoItem: PhotosPickerItem?
    @State private var trimURL: URL?
    @State private var showLinkSheet = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Button { openFiles() } label: { Label("Open", systemImage: "plus") }
                    .help("Open audio or video (⌘O)")
                Button { showLinkSheet = true } label: { Label("Download from Link", systemImage: "link") }
                    .help("Download from a Spotify or YouTube link (⌘U)")
                PhotosPicker(selection: $photoItem, matching: .videos, photoLibrary: .shared()) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                .help("Split a video from your Photos library")
                if model.player != nil {
                    Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.enqueue(files)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: photoItem) { _, item in importPhoto(item) }
        .onReceive(NotificationCenter.default.publisher(for: .openFiles)) { _ in openFiles() }
        .onReceive(NotificationCenter.default.publisher(for: .downloadLink)) { _ in showLinkSheet = true }
        .onReceive(NotificationCenter.default.publisher(for: .splitPart)) { _ in
            if let url = pickFiles(multiple: false).first { trimURL = url }
        }
        .sheet(item: $trimURL) { url in TrimSheet(url: url) }
        .sheet(isPresented: $showLinkSheet) { LinkDownloadSheet() }
        .alert("Couldn't do that", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(model.errorMessage ?? "") }
    }

    private var detail: some View {
        Group {
            if let player = model.player {
                HStack(spacing: 0) {
                    SongView(player: player)
                        .id(player.song.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showInspector {
                        Divider()
                        InspectorView(player: player)
                            .frame(width: 270)
                            .transition(.move(edge: .trailing))
                    }
                }
            } else {
                EmptyDropView(targeted: dropTargeted)
            }
        }
    }

    /// TEMP bisect G: apply .balanced split style via env.
    struct TEMPBalanced: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on { content.navigationSplitViewStyle(.balanced) } else { content }
        }
    }

    private func pickFiles(multiple: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppModel.supportedTypes
        panel.allowsMultipleSelection = multiple
        return panel.runModal() == .OK ? panel.urls : []
    }

    private func openFiles() { model.enqueue(pickFiles(multiple: true)) }

    private func importPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                if let movie = try await item.loadTransferable(type: PhotoMovie.self) { model.enqueue([movie.url]) }
            } catch {
                model.errorMessage = "Couldn't load that video from Photos: \(error.localizedDescription)"
            }
            photoItem = nil
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

extension Notification.Name {
    static let openFiles = Notification.Name("openFiles")
    static let splitPart = Notification.Name("splitPart")
    static let downloadLink = Notification.Name("downloadLink")
}

/// Photos hands us a temporary file; copy it somewhere that outlives the transfer.
struct PhotoMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Imports", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PhotoMovie(url: dest)
        }
    }
}

struct EmptyDropView: View {
    var targeted: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text("Drop a song or video")
                .font(.title2.weight(.semibold))
            Text("4 stems, key, BPM, chords and notes. Nothing leaves your Mac.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(24)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop a song or video to split it into stems")
    }
}

struct SidebarView: View {
    @Bindable var model = AppModel.shared

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
            if !model.queue.isEmpty {
                Section("Queue") {
                    ForEach(model.queue) { job in JobRow(job: job) }
                }
            }
            Section("Library") {
                ForEach(model.songs) { song in
                    SongRow(song: song)
                        .tag(song)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([song.folder]) }
                            Button("Re-analyze") { model.analyze(song, force: true) }
                            Divider()
                            Button("Move to Trash", role: .destructive) { model.delete(song) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.songs.isEmpty && model.queue.isEmpty {
                Text("Splits you make show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }
}

struct JobRow: View {
    let job: SplitJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.title).lineLimit(1)
                Spacer()
                switch job.state {
                case .failed, .cancelled:
                    Button { AppModel.shared.dismiss(job) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                default:
                    Button { AppModel.shared.cancel(job) } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.borderless)
                        .help("Cancel")
                        .accessibilityLabel("Cancel split")
                }
            }
            switch job.state {
            case .waiting:
                Text("Waiting").font(.caption).foregroundStyle(.secondary)
            case .splitting(let p):
                ProgressView(value: p).progressViewStyle(.linear)
                    .accessibilityLabel("Splitting \(Int(p * 100)) percent")
            case .failed(let m):
                Text(m).font(.caption).foregroundStyle(.red).lineLimit(2)
            case .cancelled:
                Text("Cancelled").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SongRow: View {
    let song: Song

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if song.info.isVideo { Image(systemName: "film").font(.caption2).foregroundStyle(.secondary) }
                Text(song.title).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(Format.time(song.info.duration))
                if let bpm = song.analysis?.tempo?.bpm { Text("\(Int(bpm.rounded())) BPM") }
                if let key = song.analysis?.key?.key { Text(key.name) }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

/// "Split Part of File…": choose a range before splitting.
struct TrimSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var end: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Split part of \(url.lastPathComponent)").font(.headline)
            if duration > 0 {
                LabeledContent("Start") {
                    Slider(value: $start, in: 0...duration) { Text(Format.time(start)).monospacedDigit().frame(width: 56) }
                }
                LabeledContent("End") {
                    Slider(value: $end, in: 0...duration) { Text(Format.time(end)).monospacedDigit().frame(width: 56) }
                }
                Text("\(Format.time(max(0, end - start))) selected of \(Format.time(duration))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Split") {
                    AppModel.shared.enqueue([url], range: start...end)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(end - start < 1)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            end = duration
        }
        .onChange(of: start) { _, v in if end < v { end = v } }
        .onChange(of: end) { _, v in if start > v { start = v } }
    }
}

enum Format {
    static func time(_ s: Double) -> String {
        guard s.isFinite else { return "–:––" }
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func precise(_ s: Double) -> String {
        String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}
