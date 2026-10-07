import Foundation
import Testing
@testable import SnapClipCore

final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

struct Fixture {
    let dir: URL
    let clock = TestClock()
    let trashed = TrashLog()
    let store: TrackerStore

    final class TrashLog { var urls: [URL] = [] }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapclip-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let clock = self.clock
        let log = self.trashed
        store = TrackerStore(
            storeURL: dir.appendingPathComponent("state/tracked.json"),
            now: { clock.now },
            trash: { log.urls.append($0) })
    }

    @discardableResult
    func makeFile(_ name: String) throws -> String {
        let path = dir.appendingPathComponent(name).path
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        return path
    }
}

private func setScreenCaptureXattr(_ path: String) throws {
    let value: [UInt8] = [1]
    let result = setxattr(path, SnapClipConstants.screenCaptureXattr, value, value.count, 0, 0)
    try #require(result == 0, "setxattr failed for \(path)")
}

@Suite struct RetentionTests {
    @Test func sixthScreenshotTrashesOldest() throws {
        let f = try Fixture()
        var paths: [String] = []
        for i in 1...6 {
            paths.append(try f.makeFile("s\(i).png"))
            f.store.add(path: paths[i - 1])
            f.clock.advance(1)
        }
        #expect(f.trashed.urls.map(\.path) == [paths[0]])
        #expect(f.store.items.count == 5)
    }

    @Test func expiresAfterFiveMinutes() throws {
        let f = try Fixture()
        let path = try f.makeFile("a.png")
        f.store.add(path: path)
        f.clock.advance(299)
        f.store.sweep()
        #expect(f.trashed.urls.isEmpty)
        f.clock.advance(1)
        f.store.sweep()
        #expect(f.trashed.urls.map(\.path) == [path])
        #expect(f.store.items.isEmpty)
    }

    @Test func movedFileIsNotTrashedAndIsUntracked() throws {
        let f = try Fixture()
        let path = try f.makeFile("a.png")
        f.store.add(path: path)
        let elsewhere = f.dir.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            atPath: path, toPath: elsewhere.appendingPathComponent("a.png").path)
        f.clock.advance(400)
        f.store.sweep()
        #expect(f.trashed.urls.isEmpty)
        #expect(f.store.items.isEmpty)
    }

    @Test func renamedFileIsNotTrashed() throws {
        let f = try Fixture()
        let path = try f.makeFile("a.png")
        f.store.add(path: path)
        try FileManager.default.moveItem(atPath: path, toPath: f.dir.appendingPathComponent("renamed.png").path)
        f.clock.advance(400)
        f.store.sweep()
        #expect(f.trashed.urls.isEmpty)
        #expect(f.store.items.isEmpty)
    }

    @Test func samePathDifferentInodeIsNotTrashed() throws {
        let f = try Fixture()
        let path = try f.makeFile("a.png")
        f.store.add(path: path)
        // Keep the original inode alive elsewhere so the new file cannot reuse it.
        try FileManager.default.moveItem(atPath: path, toPath: f.dir.appendingPathComponent("orig.png").path)
        try f.makeFile("a.png")
        f.clock.advance(400)
        f.store.sweep()
        #expect(f.trashed.urls.isEmpty)
        #expect(f.store.items.isEmpty)
    }
}

@Suite struct LoginItemTests {
    @Test func cellarPathIsRewrittenToOpt() {
        let stable = LoginItem.stableAppPath(
            bundlePath: "/opt/homebrew/Cellar/snapclip/0.1.0/SnapClip.app")
        #expect(stable == "/opt/homebrew/opt/snapclip/SnapClip.app")
        #expect(LoginItem.stableAppPath(bundlePath: "/Applications/SnapClip.app") == "/Applications/SnapClip.app")
    }
}

@Suite struct DetectorTests {
    @Test func xattrDetection() throws {
        let f = try Fixture()
        let marked = try f.makeFile("marked.png")
        let plain = try f.makeFile("plain.png")
        try setScreenCaptureXattr(marked)
        #expect(ScreenshotDetector.isScreenCapture(path: marked))
        #expect(!ScreenshotDetector.isScreenCapture(path: plain))
    }
}

@Suite struct PolicyTests {
    private func accepts(_ f: Fixture, _ path: String, seen: Set<FileIdentity> = [], folder: URL? = nil) -> Bool {
        ScreenshotPolicy.shouldTrack(
            path: path, watchedFolder: folder ?? f.dir, seen: seen, now: Date())
    }

    @Test func freshScreenshotIsAccepted() throws {
        let f = try Fixture()
        let path = try f.makeFile("shot.png")
        try setScreenCaptureXattr(path)
        #expect(accepts(f, path))
    }

    @Test func imageWithoutXattrIsRejected() throws {
        let f = try Fixture()
        let path = try f.makeFile("plain.png")
        #expect(!accepts(f, path))
    }

    @Test func movieWithXattrIsRejected() throws {
        let f = try Fixture()
        let path = try f.makeFile("recording.mov")
        try setScreenCaptureXattr(path)
        #expect(!accepts(f, path))
    }

    @Test func fileOlderThanRecentWindowIsRejected() throws {
        let f = try Fixture()
        let path = try f.makeFile("old.png")
        try setScreenCaptureXattr(path)
        let later = Date().addingTimeInterval(SnapClipConstants.recentWindow + 5)
        #expect(!ScreenshotPolicy.shouldTrack(path: path, watchedFolder: f.dir, seen: [], now: later))
    }

    @Test func renamedTrackedFileIsNotTrackedAgain() throws {
        let f = try Fixture()
        let path = try f.makeFile("shot.png")
        try setScreenCaptureXattr(path)
        f.store.add(path: path)
        let renamed = f.dir.appendingPathComponent("kept.png").path
        try FileManager.default.moveItem(atPath: path, toPath: renamed)
        #expect(accepts(f, renamed), "without the seen set the renamed file looks like a new screenshot")
        #expect(!accepts(f, renamed, seen: f.store.seenIdentities))
    }

    @Test func seenFileMovedIntoFolderIsNotTrackedAgain() throws {
        let f = try Fixture()
        let elsewhere = f.dir.appendingPathComponent("elsewhere", isDirectory: true)
        let watched = f.dir.appendingPathComponent("watched", isDirectory: true)
        for dir in [elsewhere, watched] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let original = elsewhere.appendingPathComponent("shot.png").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: original))
        try setScreenCaptureXattr(original)
        f.store.add(path: original)
        let dropped = watched.appendingPathComponent("shot.png").path
        try FileManager.default.moveItem(atPath: original, toPath: dropped)
        #expect(accepts(f, dropped, folder: watched))
        #expect(!accepts(f, dropped, seen: f.store.seenIdentities, folder: watched))
    }

    @Test func symlinkedWatchedFolderStillMatches() throws {
        let f = try Fixture()
        let path = try f.makeFile("shot.png")
        try setScreenCaptureXattr(path)
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapclip-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.dir)
        #expect(accepts(f, path, folder: link))
    }
}

@Suite struct PersistenceTests {
    @Test func seenIdentitiesSurviveReload() throws {
        let f = try Fixture()
        let path = try f.makeFile("a.png")
        f.store.add(path: path)
        let identity = try #require(FileIdentity.at(path: path))
        let reloaded = TrackerStore(
            storeURL: f.dir.appendingPathComponent("state/tracked.json"), now: { f.clock.now },
            trash: { _ in })
        #expect(reloaded.items.map(\.path) == [path])
        #expect(reloaded.seenIdentities == [identity])
    }

    @Test func legacyArrayFormatStillDecodes() throws {
        let f = try Fixture()
        let path = try f.makeFile("a.png")
        let identity = try #require(FileIdentity.at(path: path))
        let legacy = """
            [{"path":"\(path)","inode":\(identity.inode),"device":\(identity.device),
              "addedAt":"2026-10-07T00:00:00Z"}]
            """
        let url = f.dir.appendingPathComponent("legacy.json")
        try Data(legacy.utf8).write(to: url)
        let store = TrackerStore(storeURL: url, now: { f.clock.now }, trash: { _ in })
        #expect(store.items.map(\.path) == [path])
        #expect(store.seenIdentities == [identity])
    }

    @Test func sweepWithoutChangeDoesNotRewriteFile() throws {
        let f = try Fixture()
        let path = try f.makeFile("a.png")
        f.store.add(path: path)
        let url = f.dir.appendingPathComponent("state/tracked.json")
        try FileManager.default.removeItem(at: url)
        f.store.sweep()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
