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

@Suite struct ScreenCaptureSettingsTests {
    @Test func instantCopyTogglesShowThumbnailKey() throws {
        let suite = "snapclip-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ScreenCaptureSettings(defaults: defaults)

        // macOS shows the thumbnail when the key is unset.
        #expect(settings.isThumbnailEnabled)
        #expect(!settings.isInstantCopyEnabled)

        settings.setInstantCopy(true)
        #expect(defaults.object(forKey: "show-thumbnail") as? Bool == false)
        #expect(settings.isInstantCopyEnabled)

        settings.setInstantCopy(false)
        #expect(defaults.object(forKey: "show-thumbnail") as? Bool == true)
        #expect(settings.isThumbnailEnabled)
    }
}

@Suite struct UpdateTests {
    private func release(tag: String, url: String = "https://github.com/0xnicholasy/snapclip/releases/tag/v0.1.2")
        -> Data
    {
        Data(#"{"tag_name":"\#(tag)","html_url":"\#(url)","name":"ignored","draft":false}"#.utf8)
    }

    private func checker(current: String, response: Data) -> UpdateChecker {
        UpdateChecker(currentVersion: current, fetch: { _ in response })
    }

    @Test func versionParseAcceptsPlainAndVPrefixed() throws {
        let v1 = try #require(SemanticVersion("v0.1.2"))
        let v2 = try #require(SemanticVersion("0.1.2"))
        #expect(v1 == v2)
        #expect(v1.description == "0.1.2")
    }

    @Test func versionParseRejectsAnythingElse() {
        for bad in ["0.1", "v1.2.3-beta", "1.2.3.4", "garbage", "", "v", "1..3", "1.2.x", "V1.2.3", "+1.2.3"] {
            #expect(SemanticVersion(bad) == nil, "\(bad) should be rejected")
        }
    }

    @Test func versionCompareIsNumeric() throws {
        let a = try #require(SemanticVersion("0.1.10"))
        let b = try #require(SemanticVersion("0.1.9"))
        #expect(a > b)
        #expect(try #require(SemanticVersion("0.2.0")) > a)
        #expect(try #require(SemanticVersion("1.0.0")) > a)
    }

    @Test func newerTagIsUpdateAvailable() async throws {
        let result = try await checker(current: "0.1.1", response: release(tag: "v0.1.2")).check()
        let expected = ReleaseInfo(
            version: try #require(SemanticVersion("0.1.2")),
            pageURL: try #require(URL(string: "https://github.com/0xnicholasy/snapclip/releases/tag/v0.1.2")))
        #expect(result == .updateAvailable(expected))
    }

    @Test func releasePageURLIsBuiltFromVersionNotPayload() async throws {
        let data = release(tag: "v0.3.4", url: "https://github.com/someone-else/other/releases/tag/v9.9.9")
        let result = try await checker(current: "0.1.1", response: data).check()
        guard case .updateAvailable(let info) = result else { Issue.record("expected update"); return }
        #expect(info.pageURL.absoluteString == "https://github.com/0xnicholasy/snapclip/releases/tag/v0.3.4")
    }

    @Test func sameOrOlderTagIsUpToDate() async throws {
        let same = try await checker(current: "0.1.2", response: release(tag: "v0.1.2")).check()
        #expect(same == .upToDate(current: try #require(SemanticVersion("0.1.2"))))
        let older = try await checker(current: "0.1.2", response: release(tag: "v0.1.1")).check()
        #expect(older == .upToDate(current: try #require(SemanticVersion("0.1.2"))))
    }

    @Test func malformedJsonThrows() async {
        let bad = checker(current: "0.1.1", response: Data("not json".utf8))
        await #expect(throws: UpdateError.malformedResponse) { try await bad.check() }
        let missing = checker(current: "0.1.1", response: Data(#"{"tag_name":"v0.1.2"}"#.utf8))
        await #expect(throws: UpdateError.malformedResponse) { try await missing.check() }
    }

    @Test func unparsableTagOrNonGithubUrlThrows() async {
        let beta = checker(current: "0.1.1", response: release(tag: "v0.2.0-beta"))
        await #expect(throws: UpdateError.unrecognizedTag("v0.2.0-beta")) { try await beta.check() }
        let evil = checker(current: "0.1.1", response: release(tag: "v0.2.0", url: "https://evil.example/x"))
        await #expect(throws: UpdateError.malformedResponse) { try await evil.check() }
    }

    @Test func requestCarriesRequiredHeadersAndTimeout() throws {
        let request = UpdateChecker(currentVersion: "0.1.2", fetch: { _ in Data() }).makeRequest()
        #expect(request.url?.absoluteString == "https://api.github.com/repos/0xnicholasy/snapclip/releases/latest")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "SnapClip/0.1.2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 15)
    }

    @Test func nextCheckIsDelayedUntil24HoursAfterLast() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdateSchedule.delayUntilNextCheck(lastCheck: nil, now: now) == 5)
        #expect(UpdateSchedule.delayUntilNextCheck(lastCheck: now.addingTimeInterval(-3_600), now: now) == 82_800)
        #expect(UpdateSchedule.delayUntilNextCheck(lastCheck: now.addingTimeInterval(-90_000), now: now) == 5)
    }
}

@Suite struct HomebrewInstallTests {
    @Test func derivesBrewPathFromCellarBundle() throws {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let install = try #require(
                HomebrewInstall(bundlePath: "\(prefix)/Cellar/snapclip/0.1.1/SnapClip.app"))
            #expect(install.brewPath == "\(prefix)/bin/brew")
            #expect(install.stableAppPath == "\(prefix)/opt/snapclip/SnapClip.app")
            #expect(install.environment["PATH"] == "\(prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        }
    }

    @Test func nonCellarPathIsNotHomebrew() {
        #expect(HomebrewInstall(bundlePath: "/Users/me/snapclip/build/SnapClip.app") == nil)
        #expect(HomebrewInstall(bundlePath: "/Applications/SnapClip.app") == nil)
        #expect(HomebrewInstall(bundlePath: "/opt/homebrew/Cellar/other/1.0/SnapClip.app") == nil)
    }

    @Test func nonAllowlistedOrEmptyPrefixIsRejected() {
        #expect(HomebrewInstall(bundlePath: "/Cellar/snapclip/0.1.1/SnapClip.app") == nil)
        #expect(HomebrewInstall(bundlePath: "/tmp/evil/Cellar/snapclip/0.1.1/SnapClip.app") == nil)
        #expect(HomebrewInstall(bundlePath: "/Users/me/homebrew/Cellar/snapclip/0.1.1/SnapClip.app") == nil)
        #expect(HomebrewInstall(bundlePath: "/usr/local/Cellar/snapclip/") == nil)
        #expect(HomebrewInstall(bundlePath: "/usr/local/Cellar/snapclip/0.1.1/SnapClip.app") != nil)
    }

    @Test func environmentPassesThroughOnlyAllowlistedVariables() throws {
        let install = try #require(HomebrewInstall(bundlePath: "/opt/homebrew/Cellar/snapclip/0.1.1/SnapClip.app"))
        let env = install.environment(inheriting: [
            "HTTPS_PROXY": "http://proxy:3128", "no_proxy": "localhost", "TMPDIR": "/tmp/x",
            "PATH": "/evil", "DYLD_INSERT_LIBRARIES": "/evil.dylib", "HOMEBREW_NO_AUTO_UPDATE": "0",
        ])
        #expect(env["HTTPS_PROXY"] == "http://proxy:3128")
        #expect(env["no_proxy"] == "localhost")
        #expect(env["TMPDIR"] == "/tmp/x")
        #expect(env["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(env["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    }
}
