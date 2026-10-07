import AppKit
import CoreServices
import SnapClipCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = TrackerStore()
    private let loginItem = LoginItem()
    private let captureSettings = ScreenCaptureSettings()
    private let desktopSettings = DesktopSettings()
    private static let promptedKey = "didPromptInstantCopy"
    private var statusItem: NSStatusItem?
    private var watcher: FolderWatcher?
    private var sweepTimer: Timer?
    private var watchedFolder = ScreenshotLocation.resolve()
    private var inFlight: Set<FileIdentity> = []
    private let updates = UpdateController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnapClip")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        // Location is re-read on every start.
        watchedFolder = ScreenshotLocation.resolve()
        let folderWatcher = FolderWatcher { [weak self] events in
            self?.handle(events)
        }
        folderWatcher.start(folder: watchedFolder)
        watcher = folderWatcher

        store.sweep()
        sweepTimer = Timer.scheduledTimer(
            withTimeInterval: SnapClipConstants.sweepInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.store.sweep() }
        }

        promptInstantCopyOnFirstLaunch()
        updates.start()
    }

    private func promptInstantCopyOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.promptedKey) else { return }
        defaults.set(true, forKey: Self.promptedKey)
        guard captureSettings.isThumbnailEnabled else { return }

        let alert = NSAlert()
        alert.messageText = "Copy screenshots instantly?"
        alert.informativeText =
            "While the floating thumbnail is shown, macOS waits about 10 seconds before saving the "
            + "screenshot, so SnapClip can only copy it after that delay. Turning the thumbnail off "
            + "copies each screenshot right away."
        alert.addButton(withTitle: "Turn Off Thumbnail")
        alert.addButton(withTitle: "Keep Thumbnail")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            captureSettings.setInstantCopy(true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
    }

    // MARK: - Detection

    private func handle(_ events: [FolderWatcher.Event]) {
        let relevant = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed
                | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemXattrMod)
        let isFile = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let needsRescan = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        if events.contains(where: { $0.flags & needsRescan != 0 }) {
            rescanWatchedFolder()
        }
        for event in events where event.flags & isFile != 0 && event.flags & relevant != 0 {
            consider(path: event.path)
        }
    }

    private func rescanWatchedFolder() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: watchedFolder.path)) ?? []
        for name in names {
            consider(path: watchedFolder.appendingPathComponent(name).path)
        }
    }

    private func consider(path: String) {
        guard let identity = FileIdentity.at(path: path), !inFlight.contains(identity),
            ScreenshotPolicy.shouldTrack(
                path: path, watchedFolder: watchedFolder, seen: store.seenIdentities, now: Date())
        else { return }

        let url = URL(fileURLWithPath: path)
        inFlight.insert(identity)
        Task { @MainActor in
            let stable = await ScreenshotDetector.waitUntilStable(path: path)
            inFlight.remove(identity)
            guard stable, FileIdentity.at(path: path) == identity, copyToClipboard(url: url)
            else { return }
            store.add(path: path)
        }
    }

    @discardableResult
    private func copyToClipboard(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return false }
        let png: Data?
        if url.pathExtension.lowercased() == "png" {
            png = data
        } else {
            png = image.tiffRepresentation
                .flatMap { NSBitmapImageRep(data: $0) }?
                .representation(using: .png, properties: [:])
        }
        guard let tiff = image.tiffRepresentation, let png else { return false }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        item.setString(url.absoluteString, forType: .fileURL)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        store.sweep()
        updates.addMenuItems(to: menu)

        let header = NSMenuItem(title: "Tracked screenshots", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if store.items.isEmpty {
            let empty = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let now = Date()
        for tracked in store.items.sorted(by: { $0.addedAt > $1.addedAt }) {
            let remaining = max(0, SnapClipConstants.maxAge - now.timeIntervalSince(tracked.addedAt))
            let name = URL(fileURLWithPath: tracked.path).lastPathComponent
            let entry = NSMenuItem(
                title: "\(name) - \(format(remaining)) left", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let copy = NSMenuItem(title: "Copy", action: #selector(copyItem(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = tracked.path
            sub.addItem(copy)
            entry.submenu = sub
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        let login = NSMenuItem(
            title: "Start at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = loginItem.isEnabled ? .on : .off
        menu.addItem(login)

        let instant = NSMenuItem(
            title: "Instant Copy (no floating thumbnail)", action: #selector(toggleInstantCopy(_:)),
            keyEquivalent: "")
        instant.target = self
        instant.state = captureSettings.isInstantCopyEnabled ? .on : .off
        menu.addItem(instant)

        if desktopSettings.iconsHidden {
            menu.addItem(.separator())
            let info = NSMenuItem(
                title: "Desktop icons are hidden by macOS", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            let show = NSMenuItem(
                title: "Show Desktop Icons...", action: #selector(openDesktopSettings), keyEquivalent: "")
            show.target = self
            menu.addItem(show)
            menu.addItem(.separator())
        }

        let open = NSMenuItem(
            title: "Open Screenshot Folder", action: #selector(openFolder), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(updates.makeCheckItem())

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @objc private func copyItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        copyToClipboard(url: URL(fileURLWithPath: path))
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if loginItem.isEnabled {
                try loginItem.disable()
            } else {
                try loginItem.enable(appPath: LoginItem.stableAppPath(bundlePath: Bundle.main.bundlePath))
            }
        } catch {
            NSLog("SnapClip: login item toggle failed: %@", String(describing: error))
        }
    }

    @objc private func toggleInstantCopy(_ sender: NSMenuItem) {
        captureSettings.setInstantCopy(!captureSettings.isInstantCopyEnabled)
    }

    @objc private func openDesktopSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(watchedFolder)
    }
}
