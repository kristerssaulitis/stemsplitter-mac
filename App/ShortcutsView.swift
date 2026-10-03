import SwiftUI

/// Help ▸ Keyboard Shortcuts (⌘/). Keep in sync with AppCommands and SongView's key handlers.
struct ShortcutsView: View {
    private let sections: [(String, [(String, String)])] = [
        ("Playback", [
            ("Space", "Play / pause"),
            ("⌘L", "Toggle loop"),
            ("I / O", "Set loop start / end at playhead"),
            ("↑ / ↓", "Pitch up / down"),
            ("→ / ←", "Speed up / slow down"),
        ]),
        ("Editing", [
            ("⌘E", "Split at playhead or selection edges"),
            ("⌘D", "Duplicate selection (no selection: duplicate track)"),
            ("R", "Reverse selection or clip at playhead"),
            ("⇧⌘J", "Crop to selection"),
            ("⌫", "Delete selection"),
            ("⇧⌘D", "Duplicate track"),
            ("⌘Z / ⇧⌘Z", "Undo / redo"),
            ("Esc", "Clear selection, then stem"),
        ]),
        ("Stems", [
            ("1 – 9", "Select stem"),
            ("S / M", "Solo / mute selected stem"),
            ("N", "Show notes for selected stem"),
        ]),
        ("Mouse", [
            ("Drag waveform", "Select on that stem"),
            ("Drag ruler", "Select across all stems"),
            ("Drag clip edge", "Trim clip"),
            ("Drag clip top strip", "Move clip"),
            ("Click clip top strip", "Select clip"),
            ("Hold ⌘ while dragging", "Turn off beat snap"),
            ("Right-click", "Edit menu"),
        ]),
        ("View", [
            ("⌘= / ⌘-", "Zoom in / out"),
            ("⌘0", "Zoom to fit"),
            ("⇧⌘=", "Zoom to selection"),
        ]),
        ("Song & Files", [
            ("⌘O", "Open"),
            ("⌘U", "Download from link"),
            ("⇧⌘O", "Split part of file"),
            ("⌥⌘E", "Export all stems"),
            ("⇧⌘E", "Export mixdown"),
            ("⇧⌘R", "Reverse song as new copy"),
            ("⌘⌫", "Cut selection as new copy"),
        ]),
    ]

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(sections, id: \.0) { title, rows in
                    GridRow {
                        Text(title).font(.headline).padding(.top, 10).gridCellColumns(2)
                    }
                    ForEach(rows, id: \.0) { key, what in
                        GridRow {
                            Text(key).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(what)
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 440, height: 560)
    }
}
