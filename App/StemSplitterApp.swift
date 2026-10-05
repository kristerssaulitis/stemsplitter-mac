import AppKit
import SwiftUI

@main
struct StemSplitterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("StemSplitter", id: "main") {
            ContentView()
                // Song-open + inspector needs room: at 960×560 the detail/inspector
                // split children oscillate min/max and AppKit aborts (Update Constraints
                // loop). 1400×860 verified crash-free with the inspector open.
                .frame(minWidth: 1400, minHeight: 860)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.35, green: 0.78, blue: 0.95))
        }
        .commands { AppCommands() }
        Window("Keyboard Shortcuts", id: "shortcuts") { ShortcutsView() }
            .windowResizability(.contentSize)
    }
}

struct AppCommands: Commands {
    var player: PlayerModel? { AppModel.shared.player }
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { NotificationCenter.default.post(name: .openFiles, object: nil) }
                .keyboardShortcut("o")
            Button("Download from Link…") { NotificationCenter.default.post(name: .downloadLink, object: nil) }
                .keyboardShortcut("u")
            Button("Split Part of File…") { NotificationCenter.default.post(name: .splitPart, object: nil) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .saveItem) {
            Button("Export All Stems…") { if let player { Exporter.stems(player) } }
                .keyboardShortcut("e", modifiers: [.command, .option])
            Button("Export Mixdown…") { if let player { Exporter.mixdown(player) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export Instrumental…") { if let player { Exporter.mixdown(player, instrumental: true) } }
        }
        CommandMenu("Playback") {
            Button("Play / Pause") { player?.togglePlay() }
            Button("Pitch Up") { player?.nudgePitch(1) }
                .keyboardShortcut(.upArrow)
            Button("Pitch Down") { player?.nudgePitch(-1) }
                .keyboardShortcut(.downArrow)
            Button("Speed Up") { player?.nudgeTempo(1) }
                .keyboardShortcut(.rightArrow)
            Button("Slow Down") { player?.nudgeTempo(-1) }
                .keyboardShortcut(.leftArrow)
            Button("Reset Pitch and Tempo") { player?.updateMix { $0.pitch = 0; $0.tempo = 1 } }
            Divider()
            Button("Zoom In") { player?.zoomIn() }
                .keyboardShortcut("=")
            Button("Zoom Out") { player?.zoomOut() }
                .keyboardShortcut("-")
            Button("Zoom to Fit") { player?.zoomToFit() }
                .keyboardShortcut("0")
            Button("Zoom to Selection") { player?.zoomToSelection() }
                .keyboardShortcut("=", modifiers: [.command, .shift])
            Divider()
            Button("Toggle Loop") { player?.toggleLoop() }
                .keyboardShortcut("l")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { player?.undo() }
                .keyboardShortcut("z")
                .disabled(player?.canUndo != true)
            Button("Redo") { player?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(player?.canRedo != true)
        }
        CommandGroup(after: .pasteboard) {
            if let player {
                Divider()
                ArrangeMenu(player: player)
            }
        }
        CommandMenu("Song") {
            Button("Reverse Song as New Copy") { player?.reverseSong() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(player == nil)
            Button("Cut Selection from Song as New Copy") { player?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(player?.selection == nil)
        }
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
                .keyboardShortcut("/")
            Button("Copy Diagnostics") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AppModel.shared.diagnostics, forType: .string)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// Dock icon drop, Finder "Open With", `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.enqueue(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Finder right-click → Services → "Split Stems with StemSplitter" (NSServices in Info.plist).
    @objc func splitStems(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files to split." as NSString
            return
        }
        NSApp.activate()
        Task { @MainActor in AppModel.shared.enqueue(urls) }
    }
}
