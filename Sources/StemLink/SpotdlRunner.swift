#if os(macOS)
import Darwin
import Foundation

public enum SpotdlError: LocalizedError, Equatable {
    case notFound
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "spotDL is not installed. In Terminal: brew install ffmpeg && pipx install spotdl, then relaunch StemSplitter."
        case .cancelled:
            return nil
        case .failed(let message):
            return message
        }
    }
}

/// Runs the user's local spotDL install (pipx or Homebrew) as a subprocess and
/// reports its progress. GUI apps get a bare PATH, so both the binary lookup and
/// the child PATH are widened to the usual tool locations.
public struct SpotdlRunner: Sendable {
    public let executable: URL
    public let environment: [String: String]

    public init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    /// NSHomeDirectory()/homeDirectoryForCurrentUser point at the sandbox container for a
    /// GUI app; the pipx install and Homebrew live in the real home from the passwd db.
    private static let realHome: String = {
        if let pw = getpwuid(getuid()) { return String(cString: pw.pointee.pw_dir) }
        return NSHomeDirectory()
    }()

    /// Finds spotDL for a GUI app: launchd's PATH lacks ~/.local/bin (pipx) and
    /// Homebrew, which also holds the ffmpeg spotDL shells out to.
    /// `standardDirs: false` searches only `searchPath` (tests).
    public static func locate(searchPath: String? = nil, standardDirs: Bool = true) -> SpotdlRunner? {
        var dirs = Set((searchPath ?? ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init))
        if standardDirs {
            dirs.insert(realHome + "/.local/bin")
            dirs.insert("/opt/homebrew/bin")
            dirs.insert("/usr/local/bin")
        }
        let ordered = dirs.sorted()
        guard let hit = ordered.first(where: { FileManager.default.isExecutableFile(atPath: $0 + "/spotdl") }) else {
            return nil
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ordered.joined(separator: ":")
        return SpotdlRunner(executable: URL(fileURLWithPath: hit + "/spotdl"), environment: env)
    }

    /// `homeDirectory` redirects spotDL's caches into app storage so the sandboxed app's
    /// children never write to the real home. Returns the downloaded audio files.
    public func download(_ query: String, outputDirectory: URL, homeDirectory: URL,
                         progress: @escaping @Sendable (SpotdlProgress) -> Void) async throws -> [URL] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)

        var env = environment
        env["HOME"] = homeDirectory.path

        let process = Process()
        process.executableURL = executable
        process.arguments = ["download", query, "--output", outputDirectory.path,
                             "--format", "mp3", "--print-errors"]
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let output = SpotdlOutput(onChange: progress)
        let reader = Task {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                output.consume(line)
            }
        }

        try process.run()
        do {
            // Poll instead of waiting on the process so cooperative cancellation stays responsive.
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(200))
            }
        } catch is CancellationError {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw SpotdlError.cancelled
        }
        // Drain the tail (last line often has no newline) before checking the exit status.
        try? await reader.value

        let files = ((try? FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "mp3" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        if process.terminationStatus != 0 {
            throw SpotdlError.failed(output.latest?.lastIssue
                ?? "spotDL exited with code \(process.terminationStatus).")
        }
        guard !files.isEmpty else {
            throw SpotdlError.failed(output.latest?.lastIssue ?? "No tracks matched that link.")
        }
        return files
    }
}
#endif
