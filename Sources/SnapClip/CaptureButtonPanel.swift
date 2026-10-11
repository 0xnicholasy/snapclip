import AppKit

/// Borderless floating button that triggers a capture. Dragging moves it; a plain click captures.
@MainActor
final class CaptureButtonPanel {
    private static let size: CGFloat = 48
    private static let autosaveName = "SnapClipCaptureButton"

    private let panel: NSPanel

    init(onClick: @escaping () -> Void) {
        let frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.contentView = CaptureButtonView(frame: frame, onClick: onClick)
        let restored = panel.setFrameUsingName(Self.autosaveName)
        // A saved position on a screen that is no longer attached would leave the button unreachable.
        if !restored || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            positionDefault()
        }
        panel.setFrameAutosaveName(Self.autosaveName)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func positionDefault() {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let margin: CGFloat = 24
        panel.setFrameOrigin(
            NSPoint(x: visible.maxX - Self.size - margin, y: visible.minY + margin))
    }
}

/// Round button. The window drags by its background; a click that does not move fires `onClick`.
private final class CaptureButtonView: NSView {
    private let onClick: () -> Void
    private let dragThreshold: CGFloat = 4

    init(frame: NSRect, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.width / 2
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        toolTip = "Take Screenshot"

        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        let image = NSImage(
            systemSymbolName: "camera.viewfinder", accessibilityDescription: "Take Screenshot")?
            .withSymbolConfiguration(config)
        let icon = NSImageView(image: image ?? NSImage())
        icon.contentTintColor = .labelColor
        icon.frame = bounds
        icon.autoresizingMask = [.width, .height]
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var dragged = false
        // Track manually so the same press can be either a click or a drag.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x
            let dy = now.y - startMouse.y
            if !dragged && hypot(dx, dy) < dragThreshold { continue }
            dragged = true
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }
        if !dragged { onClick() }
    }
}
