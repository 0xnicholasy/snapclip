import AppKit
import SnapClipCore

/// Update checks (automatic + manual) and the Homebrew-based install flow.
@MainActor
final class UpdateController {
    private static let lastCheckKey = "lastUpdateCheck"
    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SnapClip/update.log")

    private nonisolated static let upgradeTimeout: TimeInterval = 15 * 60
    private nonisolated static let upgradeInterruptGrace: TimeInterval = 60

    private let defaults = UserDefaults.standard
    private let checker: UpdateChecker
    private var autoTimer: Timer?
    private var isChecking = false
    private(set) var isUpdating = false
    private(set) var availableRelease: ReleaseInfo?

    init() {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        checker = UpdateChecker(currentVersion: version)
    }

    func start() {
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date
        scheduleAutoCheck(after: UpdateSchedule.delayUntilNextCheck(lastCheck: last, now: Date()))
    }

    // MARK: - Menu

    func addMenuItems(to menu: NSMenu) {
        if isUpdating {
            let item = NSMenuItem(title: "Updating... (building, ~1 min)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        } else if let release = availableRelease {
            let item = NSMenuItem(
                title: "Install Update \(release.version)...", action: #selector(installFromMenu),
                keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
    }

    func makeCheckItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Check for Updates...", action: #selector(checkFromMenu), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func installFromMenu() {
        if let release = availableRelease { install(release) }
    }

    @objc private func checkFromMenu() {
        guard !isChecking else { return }
        Task { await checkManually() }
    }

    // MARK: - Checking

    private func scheduleAutoCheck(after delay: TimeInterval) {
        autoTimer?.invalidate()
        autoTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runAutoCheck() }
        }
    }

    private func runAutoCheck() {
        Task {
            let succeeded = (try? await performCheck()) != nil
            scheduleAutoCheck(
                after: succeeded
                    ? UpdateSchedule.delayUntilNextCheck(lastCheck: Date(), now: Date())
                    : SnapClipConstants.updateRetryInterval)
        }
    }

    private func performCheck() async throws -> UpdateCheckResult {
        isChecking = true
        defer { isChecking = false }
        let result = try await checker.check()
        defaults.set(Date(), forKey: Self.lastCheckKey)
        switch result {
        case .updateAvailable(let release): availableRelease = release
        case .upToDate: availableRelease = nil
        }
        return result
    }

    private func checkManually() async {
        do {
            switch try await performCheck() {
            case .upToDate(let current):
                let alert = NSAlert()
                alert.messageText = "You're up to date (\(current))"
                alert.addButton(withTitle: "OK")
                present(alert)
            case .updateAvailable(let release):
                promptInstall(release)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not check for updates"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            present(alert)
        }
    }

    private func promptInstall(_ release: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "SnapClip \(release.version) is available"
        alert.informativeText = "You have version \(checker.currentVersion)."
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        switch present(alert) {
        case .alertFirstButtonReturn: install(release)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.pageURL)
        default: break
        }
    }

    @discardableResult
    private func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    // MARK: - Installing

    private func install(_ release: ReleaseInfo) {
        guard !isUpdating else { return }
        // Resolve symlinks so /Applications/SnapClip.app maps back to the Cellar path.
        let bundlePath = URL(fileURLWithPath: Bundle.main.bundlePath).resolvingSymlinksInPath().path
        guard let homebrew = HomebrewInstall(bundlePath: bundlePath) else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        isUpdating = true
        Task {
            let logURL = Self.logURL
            let outcome = await withCheckedContinuation {
                (continuation: CheckedContinuation<UpgradeOutcome, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: UpgradeRunner.run(homebrew, logURL: logURL, timeout: Self.upgradeTimeout, grace: Self.upgradeInterruptGrace))
                }
            }
            isUpdating = false
            switch outcome {
            case .success: finishUpgrade(release, homebrew)
            case .failed(let reason): presentFailure(reason)
            }
        }
    }

    private func finishUpgrade(_ release: ReleaseInfo, _ homebrew: HomebrewInstall) {
        let plist = URL(fileURLWithPath: homebrew.stableAppPath).appendingPathComponent("Contents/Info.plist")
        let installed = NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String
        guard installed == release.version.description else {
            presentFailure("Homebrew hasn't published SnapClip \(release.version) yet. Try again later.")
            return
        }
        relaunch(from: homebrew.stableAppPath)
    }

    private func relaunch(from appPath: String) {
        // Helper waits for this process to exit, then opens the new app. Arguments are positional.
        let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$2\""
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), appPath]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "SnapClip was updated"
            alert.informativeText = "Quit and reopen SnapClip to use the new version."
            alert.addButton(withTitle: "OK")
            present(alert)
        }
    }

    private func presentFailure(_ reason: String) {
        let tail = Self.logTail(lines: 15)
        let alert = NSAlert()
        alert.messageText = "Update failed"
        alert.informativeText = tail.isEmpty ? reason : "\(reason)\n\n\(tail)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show Log")
        if present(alert) == .alertSecondButtonReturn {
            NSWorkspace.shared.open(Self.logURL)
        }
    }

    private static func logTail(lines count: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 8192 ? size - 8192 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count)
            .joined(separator: "\n")
    }
}
