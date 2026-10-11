import Carbon.HIToolbox
import SnapClipCore

/// Registers one global hotkey through Carbon, which needs no Accessibility permission.
@MainActor
final class HotkeyManager {
    private static let signature: OSType = 0x534E_4150  // "SNAP"
    /// The C callback cannot capture state, so it reaches the active manager through this.
    private static weak var active: HotkeyManager?

    var onPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Replaces any registered hotkey. Returns false if the system refused it
    /// (for example another app already owns the shortcut).
    @discardableResult
    func register(_ hotkey: CaptureHotkey) -> Bool {
        unregister()
        guard installHandlerIfNeeded() else { return false }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("SnapClip: RegisterEventHotKey failed with status %d", status)
            return false
        }
        hotKeyRef = ref
        Self.active = self
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    func stop() {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        if Self.active === self { Self.active = nil }
    }

    private func installHandlerIfNeeded() -> Bool {
        guard handlerRef == nil else { return true }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                Task { @MainActor in HotkeyManager.active?.onPress?() }
                return noErr
            },
            1, &spec, nil, &ref)
        guard status == noErr else {
            NSLog("SnapClip: InstallEventHandler failed with status %d", status)
            return false
        }
        handlerRef = ref
        return true
    }

    isolated deinit {
        stop()
    }
}
