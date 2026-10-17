import AppKit
import ImageIO
import SnapClipCore

/// Top-anchored coordinate space, so resizing the window never shifts the header or the rows.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One widget row: a pending screenshot, or one the user kept this session.
struct WidgetEntry: Equatable {
    let item: TrackedScreenshot
    let kept: Bool
}

/// Borderless panel pinned just above the desktop icons that lists the screenshots pending
/// cleanup. Dragging the background moves it; a row click copies, the eye button opens it in Preview, the pin button keeps the file;
/// a kept row stays listed (no countdown) until its x button removes it from the widget.
/// With nothing listed it collapses to its header row.
@MainActor
final class DesktopWidgetPanel {
    private static let width: CGFloat = 260
    // v2: positions saved by earlier builds (a stale x=9 was restored instead of the 24pt default).
    private static let topLeftKey = "SnapClipDesktopWidgetTopLeft.v2"
    private static let headerHeight: CGFloat = 36
    private static let emptyHeight: CGFloat = 40
    private static let rowHeight: CGFloat = 52
    private static let rowSpacing: CGFloat = 8
    private static let bottomPadding: CGFloat = 8
    private static let cornerRadius: CGFloat = 16
    private static let margin: CGFloat = 24

    private let panel: NSPanel
    private let entries: () -> [WidgetEntry]
    private let onCopy: (String) -> Bool
    private let onPreview: (String) -> Void
    private let onKeep: (String) -> Void
    private let onTrash: (String) -> Void
    private let onDismiss: (String) -> Void
    private let onAbout: () -> Void
    private let aboutButton = NSButton()
    private let content = FlippedView()
    private let headerIcon = NSImageView()
    private let headerTitle = NSTextField(labelWithString: "SnapClip")
    private let headerCount = NSTextField(labelWithString: "")
    private var rows: [String: WidgetRowView] = [:]
    private var listed: [WidgetEntry]?
    private var thumbnails: [String: CGImage] = [:]
    private var timer: Timer?

    init(
        entries: @escaping () -> [WidgetEntry], onCopy: @escaping (String) -> Bool,
        onPreview: @escaping (String) -> Void, onKeep: @escaping (String) -> Void,
        onTrash: @escaping (String) -> Void, onDismiss: @escaping (String) -> Void,
        onAbout: @escaping () -> Void
    ) {
        self.entries = entries
        self.onCopy = onCopy
        self.onPreview = onPreview
        self.onKeep = onKeep
        self.onTrash = onTrash
        self.onDismiss = onDismiss
        self.onAbout = onAbout
        let frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.height(forRows: 0))
        panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        // Same level as the macOS desktop widgets (desktopIconWindow + 2): one level lower would be
        // drawn under them. Still below every normal window.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true

        // The popover material is the closest to the translucent macOS desktop widgets and follows
        // light and dark. The rounded mask keeps both the blur and the window shadow rounded.
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        panel.contentView = effect

        content.frame = frame
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)

        headerIcon.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        headerIcon.contentTintColor = .secondaryLabelColor
        headerIcon.imageScaling = .scaleNone
        headerTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        headerTitle.textColor = .labelColor
        headerCount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        headerCount.textColor = .secondaryLabelColor
        headerCount.alignment = .right
        // A button does not start a window drag, so it gets its own clicks inside the draggable header.
        aboutButton.isBordered = false
        aboutButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        aboutButton.contentTintColor = .secondaryLabelColor
        aboutButton.imageScaling = .scaleNone
        aboutButton.toolTip = "About"
        aboutButton.target = self
        aboutButton.action = #selector(aboutClicked)
        for view in [headerIcon, headerTitle, headerCount, aboutButton] { content.addSubview(view) }

        // The height varies with the row count, so the top-left corner is saved instead of the frame.
        let saved = UserDefaults.standard.dictionary(forKey: Self.topLeftKey)
        // Size the panel to its real row count first: placement needs the final size.
        refresh()
        if let x = saved?["x"] as? Double, let y = saved?["y"] as? Double {
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        }
        // A saved position on a screen that is no longer attached would leave the widget unreachable.
        // A saved position under a system desktop widget would hide ours, so it falls back too.
        if saved == nil || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) })
            || Self.systemWidgetFrames().contains(where: { $0.intersects(panel.frame) })
        {
            positionDefault()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveTopLeft() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    @objc private func aboutClicked() {
        onAbout()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func saveTopLeft() {
        let frame = panel.frame
        UserDefaults.standard.set(["x": Double(frame.minX), "y": Double(frame.maxY)], forKey: Self.topLeftKey)
    }

    func show() {
        panel.orderFrontRegardless()
        refresh()
        panel.invalidateShadow()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    /// Rebuilds the rows when the list changed, otherwise only updates the countdowns.
    func refresh() {
        let now = Date()
        let current = entries()
        if current != listed {
            rebuild(current)
        }
        for entry in current where !entry.kept {
            rows[entry.item.path]?.update(
                remaining: max(0, SnapClipConstants.maxAge - now.timeIntervalSince(entry.item.addedAt)))
        }
    }

    private static func height(forRows count: Int) -> CGFloat {
        guard count > 0 else { return emptyHeight }
        return headerHeight + CGFloat(count) * rowHeight + CGFloat(count - 1) * rowSpacing + bottomPadding
    }

    private func rebuild(_ current: [WidgetEntry]) {
        listed = current
        for row in rows.values { row.removeFromSuperview() }
        rows = [:]
        let paths = Set(current.map(\.item.path))
        thumbnails = thumbnails.filter { paths.contains($0.key) }

        let band = current.isEmpty ? Self.emptyHeight : Self.headerHeight
        let pending = current.filter { !$0.kept }.count
        headerCount.stringValue = pending == 0 ? "Nothing to clean" : "\(pending) to clean"
        headerTitle.sizeToFit()
        headerCount.sizeToFit()
        let titleHeight = headerTitle.frame.height
        let countHeight = headerCount.frame.height
        headerIcon.frame = NSRect(x: 12, y: (band - 16) / 2, width: 16, height: 16)
        headerTitle.frame = NSRect(x: 34, y: ((band - titleHeight) / 2).rounded(), width: 100, height: titleHeight)
        headerCount.frame = NSRect(
            x: Self.width - 12 - 22 - 110, y: ((band - countHeight) / 2).rounded(), width: 110,
            height: countHeight)
        aboutButton.frame = NSRect(x: Self.width - 12 - 18, y: (band - 18) / 2, width: 18, height: 18)

        for (index, entry) in current.enumerated() {
            let frame = NSRect(
                x: 0, y: Self.headerHeight + CGFloat(index) * (Self.rowHeight + Self.rowSpacing),
                width: Self.width, height: Self.rowHeight)
            let row = WidgetRowView(
                frame: frame, path: entry.item.path, kept: entry.kept,
                thumbnail: thumbnail(for: entry.item.path), onCopy: onCopy, onPreview: onPreview,
                onKeep: onKeep, onTrash: onTrash, onDismiss: onDismiss)
            content.addSubview(row)
            rows[entry.item.path] = row
        }
        resize(toRows: current.count)
    }

    /// Resizes keeping the top edge fixed; animates only while the panel is on screen.
    private func resize(toRows count: Int) {
        let height = Self.height(forRows: count)
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: Self.width, height: height)
        // Keep the whole panel visible when growth pushes it past the bottom of its screen.
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        }
        let animated = panel.isVisible && abs(frame.height - panel.frame.height) > 0.5
        panel.setFrame(frame, display: true, animate: animated)
        panel.invalidateShadow()
        if panel.isVisible { saveTopLeft() }
    }

    private func thumbnail(for path: String) -> CGImage? {
        if let cached = thumbnails[path] { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
        ]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        thumbnails[path] = cgImage
        return cgImage
    }

    private func positionDefault() {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let margin = Self.margin
        let size = panel.frame.size
        let left = visible.minX + margin
        let right = visible.maxX - size.width - margin
        let top = visible.maxY - size.height - margin
        let bottom = visible.minY + margin
        // Bottom-right is last because the capture button defaults there.
        let candidates = [
            NSPoint(x: left, y: top), NSPoint(x: left, y: bottom),
            NSPoint(x: right, y: top), NSPoint(x: right, y: bottom),
        ]
        let system = Self.systemWidgetFrames()
        let chosen = candidates.first { origin in
            let frame = NSRect(origin: origin, size: size)
            return !system.contains { $0.intersects(frame) }
        }
        panel.setFrameOrigin(chosen ?? candidates[0])
    }

    /// AppKit-coordinate frames of the on-screen macOS desktop widgets. Bounds, owner and layer
    /// need no Screen Recording permission.
    private static func systemWidgetFrames() -> [NSRect] {
        guard let primary = NSScreen.screens.first,
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        let widgetLayer = Int(CGWindowLevelForKey(.desktopIconWindow)) + 2
        return info.compactMap { window in
            guard window[kCGWindowOwnerName as String] as? String == "Notification Center",
                window[kCGWindowLayer as String] as? Int == widgetLayer,
                let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return NSRect(
                x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width,
                height: bounds.height)
        }
    }
}

/// One screenshot row. A click copies; the eye button (shown on hover) opens it in Preview; the pin button keeps the file (a kept row has an x button instead of pin and trash); the window
/// drags elsewhere.
private final class WidgetRowView: NSView {
    private static let textX: CGFloat = 60
    private static let copiedDuration: TimeInterval = 1.2

    private let path: String
    private let kept: Bool
    private let onCopy: (String) -> Bool
    private let onPreview: (String) -> Void
    private let onKeep: (String) -> Void
    private let onTrash: (String) -> Void
    private let onDismiss: (String) -> Void
    private let previewButton = NSButton()
    private let keepButton = NSButton()
    private let trashButton = NSButton()
    private let dismissButton = NSButton()
    private let countdown = NSTextField(labelWithString: "")
    private let copiedIcon = NSImageView()
    private let keptIcon = NSImageView()
    private let thumbView = NSView()
    private let hoverLayer = CALayer()
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let barWidth: CGFloat
    private var copiedTimer: Timer?
    private var isCopied = false
    private var isHovered = false
    private var remaining: TimeInterval = 0

    init(
        frame: NSRect, path: String, kept: Bool, thumbnail: CGImage?,
        onCopy: @escaping (String) -> Bool, onPreview: @escaping (String) -> Void,
        onKeep: @escaping (String) -> Void, onTrash: @escaping (String) -> Void,
        onDismiss: @escaping (String) -> Void
    ) {
        self.path = path
        self.kept = kept
        self.onCopy = onCopy
        self.onPreview = onPreview
        self.onKeep = onKeep
        self.onTrash = onTrash
        self.onDismiss = onDismiss
        let textWidth = frame.width - Self.textX - 44
        // The name also clears the row buttons (two on a kept row); the countdown bar keeps the full width.
        let nameWidth = frame.width - Self.textX - (kept ? 70 : 96)
        barWidth = textWidth
        super.init(frame: frame)
        wantsLayer = true
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        toolTip = "\(fileName)\nClick to copy"

        hoverLayer.frame = bounds.insetBy(dx: 4, dy: 0)
        hoverLayer.cornerRadius = 8
        layer?.addSublayer(hoverLayer)

        thumbView.frame = NSRect(x: 12, y: 6, width: 40, height: 40)
        thumbView.wantsLayer = true
        if let layer = thumbView.layer {
            layer.contents = thumbnail
            layer.contentsGravity = .resizeAspectFill
            layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer.masksToBounds = true
            layer.cornerRadius = 6
            layer.borderWidth = 0.5
        }
        addSubview(thumbView)

        let preview = previewButton
        preview.frame = NSRect(x: frame.width - (kept ? 62 : 88), y: 14, width: 24, height: 24)
        preview.isBordered = false
        preview.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Preview")
        preview.contentTintColor = .secondaryLabelColor
        preview.toolTip = "Open in Preview"
        preview.target = self
        preview.action = #selector(previewClicked)
        preview.isHidden = true
        addSubview(preview)

        let button = keepButton
        button.frame = NSRect(x: frame.width - 62, y: 14, width: 24, height: 24)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Keep")
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Keep (never trash)"
        button.target = self
        button.action = #selector(keepClicked)
        button.isHidden = true
        addSubview(button)

        let trash = trashButton
        trash.frame = NSRect(x: frame.width - 36, y: 14, width: 24, height: 24)
        trash.isBordered = false
        trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Move to Trash")
        trash.contentTintColor = .secondaryLabelColor
        trash.toolTip = "Move to Trash now"
        trash.target = self
        trash.action = #selector(trashClicked)
        trash.isHidden = true
        addSubview(trash)

        let dismiss = dismissButton
        dismiss.frame = NSRect(x: frame.width - 36, y: 14, width: 24, height: 24)
        dismiss.isBordered = false
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove from widget")
        dismiss.contentTintColor = .secondaryLabelColor
        dismiss.toolTip = "Remove from widget"
        dismiss.target = self
        dismiss.action = #selector(dismissClicked)
        dismiss.isHidden = true
        addSubview(dismiss)

        let name = NSTextField(labelWithString: Self.displayName(fileName))
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: Self.textX, y: 32, width: nameWidth, height: 16)
        addSubview(name)

        copiedIcon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        copiedIcon.contentTintColor = .systemGreen
        copiedIcon.imageScaling = .scaleNone
        copiedIcon.frame = NSRect(x: Self.textX, y: 17, width: 12, height: 12)
        copiedIcon.isHidden = true
        addSubview(copiedIcon)

        keptIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Kept")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        keptIcon.contentTintColor = .secondaryLabelColor
        keptIcon.imageScaling = .scaleNone
        keptIcon.frame = NSRect(x: Self.textX, y: 17, width: 12, height: 12)
        keptIcon.isHidden = true
        addSubview(keptIcon)

        countdown.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countdown.textColor = .secondaryLabelColor
        addSubview(countdown)

        trackLayer.frame = NSRect(x: Self.textX, y: 9, width: barWidth, height: 3)
        trackLayer.cornerRadius = 1.5
        layer?.addSublayer(trackLayer)
        fillLayer.cornerRadius = 1.5
        layer?.addSublayer(fillLayer)

        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// "Screenshot 2026-10-16 at 23.32.34.png" becomes "2026-10-16 at 23.32.34". Display only.
    private static func displayName(_ fileName: String) -> String {
        var name = fileName
        if name.hasPrefix("Screenshot ") { name.removeFirst("Screenshot ".count) }
        if name.lowercased().hasSuffix(".png") { name.removeLast(".png".count) }
        return name
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // The row handles its own click; dragging the window starts from the panel background.
    override var mouseDownCanMoveWindow: Bool { false }

    // Labels and the thumbnail would otherwise take the click and let the window drag start.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return dismissButton.hitTest(local) ?? trashButton.hitTest(local) ?? keepButton.hitTest(local) ?? previewButton.hitTest(local) ?? self
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // The panel never becomes key, so cursor rects alone are not honoured there.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func mouseDown(with event: NSEvent) {
        guard onCopy(path) else { return }
        isCopied = true
        copiedTimer?.invalidate()
        copiedTimer = Timer.scheduledTimer(withTimeInterval: Self.copiedDuration, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.endCopied() }
        }
        render()
    }

    @objc private func previewClicked() {
        onPreview(path)
    }

    @objc private func keepClicked() {
        onKeep(path)
    }

    @objc private func trashClicked() {
        onTrash(path)
    }

    @objc private func dismissClicked() {
        onDismiss(path)
    }

    private func endCopied() {
        copiedTimer = nil
        isCopied = false
        render()
    }

    private func setHovered(_ hovered: Bool) {
        isHovered = hovered
        previewButton.isHidden = !hovered
        keepButton.isHidden = !hovered || kept
        trashButton.isHidden = !hovered || kept
        dismissButton.isHidden = !hovered || !kept
        applyColors()
    }

    func update(remaining: TimeInterval) {
        self.remaining = remaining
        render()
    }

    private var fillColor: NSColor {
        if remaining < 15 { return .systemRed }
        if remaining < 60 { return .systemOrange }
        return .controlAccentColor
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            thumbView.layer?.borderColor = NSColor.separatorColor.cgColor
            hoverLayer.backgroundColor =
                isHovered ? NSColor.labelColor.withAlphaComponent(0.06).cgColor : nil
            trackLayer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            fillLayer.backgroundColor = fillColor.cgColor
        }
        CATransaction.commit()
    }

    private func render() {
        let textX = isCopied || kept ? Self.textX + 14 : Self.textX
        countdown.frame = NSRect(x: textX, y: 16, width: barWidth - (textX - Self.textX), height: 14)
        copiedIcon.isHidden = !isCopied
        keptIcon.isHidden = isCopied || !kept
        if isCopied {
            countdown.stringValue = "Copied"
            countdown.textColor = .systemGreen
        } else if kept {
            countdown.stringValue = "Kept, won't be trashed"
            countdown.textColor = .secondaryLabelColor
        } else {
            let total = Int(remaining.rounded(.up))
            countdown.stringValue = String(format: "Trash in %d:%02d", total / 60, total % 60)
            countdown.textColor = .secondaryLabelColor
        }
        trackLayer.isHidden = kept
        fillLayer.isHidden = kept
        let fraction = max(0, min(1, remaining / SnapClipConstants.maxAge))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = NSRect(x: Self.textX, y: 9, width: barWidth * CGFloat(fraction), height: 3)
        CATransaction.commit()
        applyColors()
    }
}
