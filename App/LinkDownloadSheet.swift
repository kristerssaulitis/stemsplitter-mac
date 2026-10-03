import StemLink
import SwiftUI

/// "Download from Link" (⌘L): paste a Spotify or YouTube link, the local spotDL install
/// fetches tagged MP3s, and they split like dropped files.
struct LinkDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model = AppModel.shared
    @State private var linkText = ""
    @State private var shake = 0
    @State private var showInvalid = false
    @State private var duplicate = false
    @State private var spotdlMissing = SpotdlRunner.locate() == nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download from Link").font(.title2.weight(.semibold))
            Text("Spotify link (track, album, playlist) or YouTube video. spotDL matches the audio on YouTube, tags it from Spotify, and it splits like a dropped file.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Paste a Spotify or YouTube link", text: $linkText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .onChange(of: linkText) { _, _ in showInvalid = false; duplicate = false }
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(MusicLink.parse(linkText) == nil)
            }
            .modifier(ShakeEffect(shakes: CGFloat(shake)))
            .animation(.easeInOut(duration: 0.35), value: shake)

            if showInvalid {
                Text("That doesn't look like a Spotify or YouTube link.")
                    .font(.caption).foregroundStyle(.red)
            }
            if duplicate {
                Text("Already downloading that link.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if spotdlMissing {
                Label {
                    Text("spotDL isn't installed. In Terminal: brew install ffmpeg && pipx install spotdl, then relaunch StemSplitter.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.yellow)
            }

            if !model.downloads.isEmpty {
                Text("Downloads").font(.headline)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.downloads) { job in DownloadRow(job: job) }
                    }
                }
                .frame(maxHeight: 230)
            } else {
                Text("Downloads show up here and then join the split queue.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            HStack {
                Text("MP3s keep in Application Support/StemSplitter/Downloads.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func add() {
        guard let link = MusicLink.parse(linkText) else {
            withAnimation { shake += 1; showInvalid = true }
            Task {
                try? await Task.sleep(for: .seconds(0.45))
                withAnimation { shake += 1 }
            }
            return
        }
        if model.submitLink(link) {
            linkText = ""
            duplicate = false
        } else {
            duplicate = true
        }
    }
}

struct DownloadRow: View {
    let job: DownloadJob

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.label)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                switch job.state {
                case .waiting:
                    Text("Waiting").font(.caption).foregroundStyle(.secondary)
                case .resolving:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Looking up…").font(.caption).foregroundStyle(.secondary)
                    }
                case .downloading(let status):
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch job.state {
            case .failed, .cancelled:
                HStack(spacing: 4) {
                    Button { AppModel.shared.retry(job) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Retry")
                        .accessibilityLabel("Retry download")
                    Button { AppModel.shared.dismiss(job) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss download")
                }
            default:
                Button { AppModel.shared.cancel(job) } label: { Image(systemName: "stop.circle") }
                    .buttonStyle(.borderless)
                    .help("Cancel")
                    .accessibilityLabel("Cancel download")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
}

/// Horizontal shake for invalid input.
struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(shakes * .pi * 2), y: 0))
    }
}
