import XCTest
@testable import StemLink

final class StemLinkTests: XCTestCase {
    // MARK: LinkParser

    func testSpotifyTrackStripsQueryParamsAndWhitespace() throws {
        let link = try XCTUnwrap(MusicLink.parse("  https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT?si=abc123&context=xyz  "))
        XCTAssertEqual(link, .spotifyTrack("4cOdK2wGLETKBW3PvgPWqT"))
        XCTAssertEqual(link.query, "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT")
    }

    func testSpotifyAlbumAndPlaylist() throws {
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://open.spotify.com/album/1DFixLWuPkv3KT3TnV35m3")), .spotifyAlbum("1DFixLWuPkv3KT3TnV35m3"))
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=1")), .spotifyPlaylist("37i9dQZF1DXcBWIGoYBM5M"))
    }

    func testSpotifyURIForm() throws {
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("spotify:track:4cOdK2wGLETKBW3PvgPWqT")), .spotifyTrack("4cOdK2wGLETKBW3PvgPWqT"))
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("SPOTIFY:PLAYLIST:37i9dQZF1DXcBWIGoYBM5M")), .spotifyPlaylist("37i9dQZF1DXcBWIGoYBM5M"))
    }

    func testYouTubeWatchShortsPlaylist() throws {
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")), .youtube("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://music.youtube.com/watch?v=dQw4w9WgXcQ")), .youtube("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://youtu.be/dQw4w9WgXcQ?si=x")), .youtube("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://www.youtube.com/shorts/abc123_-")), .youtube("https://www.youtube.com/watch?v=abc123_-"))
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://www.youtube.com/playlist?list=PL123_-")), .youtube("https://www.youtube.com/playlist?list=PL123_-"))
    }

    func testRejectsNonMusicLinks() {
        XCTAssertNil(MusicLink.parse(""))
        XCTAssertNil(MusicLink.parse("   "))
        XCTAssertNil(MusicLink.parse("https://google.com"))
        XCTAssertNil(MusicLink.parse("https://open.spotify.com/track/"))  // no id
        XCTAssertNil(MusicLink.parse("https://open.spotify.com/genre/discover-page"))
        XCTAssertNil(MusicLink.parse("spotify:episode:5pd1mU0zU8eYz0WfW1z1z1z"))
        XCTAssertNil(MusicLink.parse("https://www.youtube.com/watch"))  // no v param
        XCTAssertNil(MusicLink.parse("not a link"))
    }

    // MARK: SpotdlProgress

    func testProgressOnRealOutputSequence() {
        var p = SpotdlProgress()
        p.consume("Processing query: https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT")
        p.consume("YouTube Music returned no usable results for rick astley - never gonna give you up after 3 attempts")
        p.consume("Downloaded \"Rick Astley - Never Gonna Give You Up\":")
        p.consume("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(p.finishedCount, 1)
        XCTAssertEqual(p.lastFinished, "Rick Astley - Never Gonna Give You Up")
        XCTAssertEqual(p.processing, "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT")
        XCTAssertNotNil(p.lastIssue)  // the fallback note is kept but only used when nothing downloads
    }

    func testProgressCountsSkipAndKeepLastTrack() {
        var p = SpotdlProgress()
        p.consume("Downloaded \"A - First\":")
        p.consume("Skipping \"B - Already There\" (file already exists)")
        p.consume("")
        XCTAssertEqual(p.finishedCount, 1)
        XCTAssertEqual(p.skippedCount, 1)
        XCTAssertEqual(p.lastFinished, "B - Already There")
    }

    func testProgressCollectsErrorLine() {
        var p = SpotdlProgress()
        p.consume("ERROR: Could not complete the operation")
        XCTAssertEqual(p.lastIssue, "ERROR: Could not complete the operation")
    }

    // MARK: SpotdlOutput line splitting

    func testOutputSplitsAcrossChunksAndFlushesTail() {
        final class Snaps: @unchecked Sendable {
            let lock = NSLock(); var value: [SpotdlProgress] = []
            func add(_ p: SpotdlProgress) { lock.lock(); value.append(p); lock.unlock() }
            var all: [SpotdlProgress] { lock.lock(); defer { lock.unlock() }; return value }
        }
        let snaps = Snaps()
        let out = SpotdlOutput { snaps.add($0) }
        out.append(Data("Downloaded \"A - B\":\nhttps://youtu.be/x".utf8))
        XCTAssertEqual(snaps.all.count, 1)  // first line done, second has no newline yet
        XCTAssertEqual(snaps.all[0].lastFinished, "A - B")
        out.append(Data("\nSkipping \"C - D\" (file already exists)\n".utf8))
        out.flush()
        XCTAssertEqual(snaps.all.count, 3)
        XCTAssertEqual(snaps.all.last?.skippedCount, 1)
        let final = snaps.all.last!
        XCTAssertEqual(final.finishedCount, 1)
        XCTAssertEqual(final.lastFinished, "C - D")
    }

    // MARK: SpotdlRunner (Process, macOS only)

    private func writeScript(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-spotdl-\(UUID()).sh")
        try "#!/bin/sh\n\(body)".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func runner(_ script: URL) -> SpotdlRunner {
        SpotdlRunner(executable: script, environment: ProcessInfo.processInfo.environment)
    }

    func testRunnerDownloadsAndStreamsProgress() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spotdl-test-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try writeScript("""
        echo "Processing query: $2"
        sleep 0.2
        echo 'Downloaded "Test Artist - Test Song":'
        printf 'ID3' > "$4/Test Artist - Test Song.mp3"
        """)
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var snaps: [SpotdlProgress] = []
            func add(_ p: SpotdlProgress) { lock.lock(); snaps.append(p); lock.unlock() }
            var all: [SpotdlProgress] { lock.lock(); defer { lock.unlock() }; return snaps }
        }
        let box = Box()
        let files = try await runner(script).download("https://open.spotify.com/track/x", outputDirectory: dir,
                                                      homeDirectory: dir.appendingPathComponent("home")) { box.add($0) }
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].lastPathComponent, "Test Artist - Test Song.mp3")
        XCTAssertTrue(box.all.contains { $0.lastFinished == "Test Artist - Test Song" })
    }

    func testRunnerFailsWhenNothingDownloads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spotdl-test-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try writeScript("echo 'ERROR: No results'; exit 1\n")
        do {
            _ = try await runner(script).download("https://open.spotify.com/track/x", outputDirectory: dir,
                                                  homeDirectory: dir.appendingPathComponent("home")) { _ in }
            XCTFail("expected failure")
        } catch let error as SpotdlError {
            XCTAssertEqual(error, .failed("ERROR: No results"))
        }
    }

    func testRunnerCancelTerminatesProcess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spotdl-test-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try writeScript("sleep 30\n")
        let task = Task {
            try await runner(script).download("https://open.spotify.com/track/x", outputDirectory: dir,
                                              homeDirectory: dir.appendingPathComponent("home")) { _ in }
        }
        try await Task.sleep(for: .seconds(0.6))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as SpotdlError {
            XCTAssertEqual(error, .cancelled)
        }
        // The killed script must not leave a file behind (it never got that far anyway).
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".mp3") }, [])
    }

    func testLocateFindsExecutableInSearchPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spotdl-bin-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("spotdl")
        try "#!/bin/sh\nexit 0".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let found = SpotdlRunner.locate(searchPath: dir.path, standardDirs: false)
        XCTAssertEqual(found?.executable, fake)
    }

    func testLocateReturnsNilWithoutBinary() {
        XCTAssertNil(SpotdlRunner.locate(searchPath: "/nonexistent-\(UUID())", standardDirs: false))
    }
}
