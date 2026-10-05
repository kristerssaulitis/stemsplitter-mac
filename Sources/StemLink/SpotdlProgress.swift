import Foundation

/// Parses spotDL's plain (non-TTY) output lines into status a UI can show.
/// Real lines look like:
///   Processing query: https://open.spotify.com/track/…
///   YouTube Music returned no usable results for … after 3 attempts   (then it falls back)
///   Downloaded "Rick Astley - Never Gonna Give You Up":
///   https://www.youtube.com/watch?v=…
///   Skipping "Artist - Title" (file already exists)
public struct SpotdlProgress: Equatable, Sendable {
    public private(set) var lastFinished: String?
    public private(set) var finishedCount = 0
    public private(set) var skippedCount = 0
    /// Last line that looked like an error; used to explain a failed download.
    public private(set) var lastIssue: String?

    public init() {}

    public mutating func consume(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        if line.hasPrefix("Downloaded \"") || line.hasPrefix("Skipping \"") {
            if let name = Self.quoted(line) {
                lastFinished = name
                if line.hasPrefix("Skipping") { skippedCount += 1 } else { finishedCount += 1 }
            }
        } else if line.contains("ERROR") || line.hasPrefix("Failed to")
                    || line.contains("returned no usable results") {
            lastIssue = line
        }
    }

    /// First-to-last quote pair on lines like `Downloaded "Artist - Title":`.
    static func quoted(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else {
            return nil
        }
        return String(line[line.index(after: open)..<close])
    }
}

/// Keeps a running SpotdlProgress from spotDL's output lines. Thread-safe: consume is
/// called from the reader task, latest from anywhere.
public final class SpotdlOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = SpotdlProgress()
    private let onChange: @Sendable (SpotdlProgress) -> Void

    public init(onChange: @escaping @Sendable (SpotdlProgress) -> Void) {
        self.onChange = onChange
    }

    public func consume(_ line: String) {
        lock.lock()
        progress.consume(line)
        let snapshot = progress
        lock.unlock()
        onChange(snapshot)
    }

    /// Latest snapshot (the same value the last onChange delivered).
    public var latest: SpotdlProgress? {
        lock.lock()
        defer { lock.unlock() }
        return progress
    }
}
