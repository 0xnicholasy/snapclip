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
    private static let widgetKey = "showDesktopWidget"
    private var statusItem: NSStatusItem?
    private var watcher: FolderWatcher?
    private var sweepTimer: Timer?
    private lazy var pipeline = ScreenshotPipeline(
        store: store, watchedFolder: ScreenshotLocation.resolve(),
        copy: { [unowned self] in self.copyToClipboard(url: $0) })
    private let updates = UpdateController()
    private let hotkeyStore = CaptureHotkeyStore()
    private let hotkeys = HotkeyManager()
    private var recorder: HotkeyRecorder?
    private var buttonPanel: CaptureButtonPanel?
    private var widget: DesktopWidgetPanel?
    private var aboutWindow: AboutWindow?
    /// Screenshots kept this session, newest first. They stay listed in the widget until dismissed.
    private var keptInWidget: [TrackedScreenshot] = []
    private static let maxWidgetRows = SnapClipConstants.maxTracked + 3
    private lazy var captureController = CaptureController(
        folder: { [unowned self] in self.pipeline.watchedFolder },
        onRunningChanged: { [weak self] running in self?.captureRunningChanged(running) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnapClip")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        // Location is re-read on every start.
        pipeline.watchedFolder = ScreenshotLocation.resolve()
        let folderWatcher = FolderWatcher { [weak self] events in
            self?.pipeline.handle(events)
        }
        folderWatcher.start(folder: pipeline.watchedFolder)
        watcher = folderWatcher

        store.sweep()
        let sweep = Timer.scheduledTimer(
            withTimeInterval: SnapClipConstants.sweepInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.store.sweep()
                if self?.widget?.isVisible == true { self?.widget?.refresh() }
            }
        }
        sweepTimer = sweep

        promptInstantCopyOnFirstLaunch()
        updates.start()
        setUpCapture()
        if UserDefaults.standard.bool(forKey: Self.widgetKey) { showWidget() }
    }

    private func showWidget() {
        let panel =
            widget
            ?? DesktopWidgetPanel(
                entries: { [unowned self] in self.widgetEntries() },
                onCopy: { [unowned self] in self.copyToClipboard(url: URL(fileURLWithPath: $0)) },
                onPreview: { [unowned self] in self.openInPreview(path: $0) },
                onKeep: { [unowned self] in self.keep(path: $0) },
                onTrash: { [unowned self] in self.trashNow(path: $0) },
                onDismiss: { [unowned self] in self.dismissKept(path: $0) },
                onAbout: { [unowned self] in self.showAbout() })
        widget = panel
        panel.show()
    }

    /// Pending items newest first, then kept ones. Kept items whose file moved or changed are dropped.
    private func widgetEntries() -> [WidgetEntry] {
        keptInWidget.removeAll { FileIdentity.at(path: $0.path) != $0.identity }
        let pending = store.items
            .filter { FileIdentity.at(path: $0.path) == $0.identity }
            .sorted { $0.addedAt > $1.addedAt }
        let keptRoom = max(0, Self.maxWidgetRows - pending.count)
        return pending.map { WidgetEntry(item: $0, kept: false) }
            + keptInWidget.prefix(keptRoom).map { WidgetEntry(item: $0, kept: true) }
    }

    private func dismissKept(path: String) {
        keptInWidget.removeAll { $0.path == path }
        if widget?.isVisible == true { widget?.refresh() }
    }

    private func keep(path: String) {
        if let item = store.items.first(where: { $0.path == path }) {
            keptInWidget.removeAll { $0.path == path }
            keptInWidget.insert(item, at: 0)
            keptInWidget = Array(keptInWidget.prefix(SnapClipConstants.maxTracked))
        }
        store.keep(path: path)
        if widget?.isVisible == true { widget?.refresh() }
    }

    private func trashNow(path: String) {
        let moved = store.trashNow(path: path)
        if widget?.isVisible == true { widget?.refresh() }
        guard !moved else { return }
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = "Could not move to Trash"
        alert.informativeText =
            "\(URL(fileURLWithPath: path).lastPathComponent)\nThe file is still in your screenshot folder and is no longer auto-cleaned."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func setUpCapture() {
        hotkeys.onPress = { [weak self] in self?.captureController.capture() }
        if let hotkey = hotkeyStore.load(), !hotkeys.register(hotkey) {
            showRegistrationFailure(for: hotkey)
        }
        if hotkeyStore.showCaptureButton { showCaptureButton() }
    }

    private func showCaptureButton() {
        let panel = buttonPanel ?? CaptureButtonPanel { [weak self] in self?.captureController.capture() }
        buttonPanel = panel
        panel.show()
    }

    /// Hides the floating button while `screencapture` runs so it is not in the shot.
    private func captureRunningChanged(_ running: Bool) {
        if running {
            buttonPanel?.hide()
        } else if hotkeyStore.showCaptureButton {
            showCaptureButton()
        }
    }

    @objc private func aboutItem() { showAbout() }

    private func showAbout() {
        let window = aboutWindow ?? AboutWindow()
        aboutWindow = window
        window.show()
    }

    private func showRegistrationFailure(for hotkey: CaptureHotkey) {
        let alert = NSAlert()
        alert.messageText = "Shortcut could not be registered"
        alert.informativeText =
            "\(hotkey.displayString) may already be used by another app. Choose a different shortcut "
            + "with Capture Shortcut... in the SnapClip menu."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
        hotkeys.stop()
    }

    // MARK: - Detection

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

    private func openInPreview(path: String) {
        if store.items.contains(where: { $0.path == path }) { keep(path: path) }
        let url = URL(fileURLWithPath: path)
        guard
            let previewURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Preview")
        else {
            NSWorkspace.shared.open(url)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: previewURL, configuration: config)
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
            let preview = NSMenuItem(
                title: "Open in Preview (keeps it)", action: #selector(previewItem(_:)), keyEquivalent: "")
            preview.target = self
            preview.representedObject = tracked.path
            sub.addItem(preview)
            let keep = NSMenuItem(title: "Keep", action: #selector(keepItem(_:)), keyEquivalent: "")
            keep.target = self
            keep.representedObject = tracked.path
            sub.addItem(keep)
            let trashNow = NSMenuItem(
                title: "Move to Trash", action: #selector(trashNowItem(_:)), keyEquivalent: "")
            trashNow.target = self
            trashNow.representedObject = tracked.path
            sub.addItem(trashNow)
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

        let hotkey = hotkeyStore.load()
        let shotTitle = hotkey.map { "Take Screenshot  (\($0.displayString))" } ?? "Take Screenshot"
        let shot = NSMenuItem(title: shotTitle, action: #selector(takeScreenshot), keyEquivalent: "")
        shot.target = self
        menu.addItem(shot)

        let shortcut = NSMenuItem(
            title: "Capture Shortcut...", action: #selector(openRecorder), keyEquivalent: "")
        shortcut.target = self
        menu.addItem(shortcut)

        let button = NSMenuItem(
            title: "Show Capture Button", action: #selector(toggleCaptureButton(_:)), keyEquivalent: "")
        button.target = self
        button.state = hotkeyStore.showCaptureButton ? .on : .off
        menu.addItem(button)

        let widgetItem = NSMenuItem(
            title: "Show Desktop Widget", action: #selector(toggleWidget(_:)), keyEquivalent: "")
        widgetItem.target = self
        widgetItem.state = UserDefaults.standard.bool(forKey: Self.widgetKey) ? .on : .off
        menu.addItem(widgetItem)

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
        let about = NSMenuItem(title: "About SnapClip", action: #selector(aboutItem), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
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

    @objc private func previewItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openInPreview(path: path)
    }

    @objc private func keepItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        keep(path: path)
    }

    @objc private func trashNowItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        trashNow(path: path)
    }

    @objc private func toggleWidget(_ sender: NSMenuItem) {
        let enabled = !UserDefaults.standard.bool(forKey: Self.widgetKey)
        UserDefaults.standard.set(enabled, forKey: Self.widgetKey)
        if enabled {
            showWidget()
        } else {
            widget?.hide()
        }
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

    @objc private func takeScreenshot() {
        // The menu is still closing; give it a moment so it is not captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.captureController.capture()
        }
    }

    @objc private func toggleCaptureButton(_ sender: NSMenuItem) {
        let enabled = !hotkeyStore.showCaptureButton
        hotkeyStore.showCaptureButton = enabled
        if enabled {
            showCaptureButton()
        } else {
            buttonPanel?.hide()
        }
    }

    @objc private func openRecorder() {
        if let recorder {
            recorder.bringToFront()
            return
        }
        // Free the active hotkey so pressing it records instead of capturing.
        hotkeys.unregister()
        let previous = hotkeyStore.load()
        let recorder = HotkeyRecorder(
            current: previous,
            onSave: { [weak self] hotkey in self?.hotkeyStore.save(hotkey) },
            onClear: { [weak self] in self?.hotkeyStore.clear() },
            onClose: { [weak self] in self?.recorderClosed(previous: previous) })
        self.recorder = recorder
        recorder.show()
    }

    private func recorderClosed(previous: CaptureHotkey?) {
        recorder = nil
        guard let hotkey = hotkeyStore.load() else { return }
        if hotkeys.register(hotkey) { return }
        // Keep only a shortcut that is actually registered: roll back to the previous one.
        if hotkey != previous {
            if let previous {
                hotkeyStore.save(previous)
                hotkeys.register(previous)
            } else {
                hotkeyStore.clear()
            }
        }
        // This runs inside windowWillClose; show the modal alert after the close finishes.
        DispatchQueue.main.async { [weak self] in self?.showRegistrationFailure(for: hotkey) }
    }

    @objc private func openDesktopSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(pipeline.watchedFolder)
    }
}
