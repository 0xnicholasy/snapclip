import AppKit
import Carbon.HIToolbox
import SnapClipCore

/// Small window that records a shortcut from the next key press.
@MainActor
final class HotkeyRecorder: NSObject, NSWindowDelegate {
    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete",
        kVK_LeftArrow: "\u{2190}", kVK_RightArrow: "\u{2192}", kVK_DownArrow: "\u{2193}",
        kVK_UpArrow: "\u{2191}", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    private let window: NSPanel
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var monitor: Any?
    private var pending: CaptureHotkey?
    private var finished = false

    private let onSave: (CaptureHotkey) -> Void
    private let onClear: () -> Void
    private let onClose: () -> Void

    /// `onClose` always runs last, once, however the window ends, so the caller can restore its hotkey.
    init(
        current: CaptureHotkey?, onSave: @escaping (CaptureHotkey) -> Void,
        onClear: @escaping () -> Void, onClose: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onClear = onClear
        self.onClose = onClose
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        super.init()
        pending = current
        window.title = "Capture Shortcut"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildContent()
        refresh()
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handle(event) }
            return consumed ? nil : event
        }
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        shortcutLabel.font = .systemFont(ofSize: 22, weight: .medium)
        shortcutLabel.alignment = .center
        errorLabel.textColor = .systemRed
        errorLabel.alignment = .center
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 2

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = ""
        let clear = NSButton(title: "Clear Shortcut", target: self, action: #selector(clearShortcut))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let buttons = NSStackView(views: [clear, cancel, saveButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [shortcutLabel, errorLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            errorLabel.widthAnchor.constraint(equalToConstant: 288),
        ])
        window.contentView = content
    }

    private func refresh() {
        shortcutLabel.stringValue = pending?.displayString ?? "Press a shortcut..."
        saveButton.isEnabled = pending != nil
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if Int(event.keyCode) == kVK_Escape && flags.isDisjoint(with: [.command, .control, .option, .shift]) {
            cancel()
            return true
        }
        let modifiers = Self.carbonModifiers(from: flags)
        let keyCode = UInt32(event.keyCode)
        if let error = CaptureHotkey.validate(keyCode: keyCode, modifiers: modifiers) {
            errorLabel.stringValue = error.message
            return true
        }
        errorLabel.stringValue = ""
        pending = CaptureHotkey(keyCode: keyCode, modifiers: modifiers, keyLabel: Self.label(for: event))
        refresh()
        return true
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= CaptureHotkey.commandMask }
        if flags.contains(.shift) { mask |= CaptureHotkey.shiftMask }
        if flags.contains(.option) { mask |= CaptureHotkey.optionMask }
        if flags.contains(.control) { mask |= CaptureHotkey.controlMask }
        return mask
    }

    private static func label(for event: NSEvent) -> String {
        if let name = specialKeys[Int(event.keyCode)] { return name }
        let text = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return text.isEmpty ? "Key \(event.keyCode)" : text
    }

    @objc private func save() {
        guard let pending else { return }
        onSave(pending)
        close()
    }

    @objc private func clearShortcut() {
        onClear()
        close()
    }

    @objc private func cancel() {
        close()
    }

    private func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onClose()
    }
}
