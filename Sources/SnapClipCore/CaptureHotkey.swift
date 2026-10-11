import Foundation

/// A global keyboard shortcut that starts an interactive capture.
public struct CaptureHotkey: Codable, Equatable, Sendable {
    // Carbon modifier masks, duplicated here so Core does not import Carbon.
    public static let commandMask: UInt32 = 0x100
    public static let shiftMask: UInt32 = 0x200
    public static let optionMask: UInt32 = 0x800
    public static let controlMask: UInt32 = 0x1000

    public enum ValidationError: Error, Equatable, Sendable {
        case needsModifier
        case reservedBySystem

        public var message: String {
            switch self {
            case .needsModifier:
                return "Include at least one of Command, Control or Option."
            case .reservedBySystem:
                return "Command+Shift+3, 4 and 5 are reserved by macOS."
            }
        }
    }

    /// Virtual key codes for 3, 4 and 5 on the ANSI layout.
    private static let reservedKeyCodes: Set<UInt32> = [20, 21, 23]

    public let keyCode: UInt32
    public let modifiers: UInt32
    /// Display character of the key, supplied by the recorder (for example "S" or "F5").
    public let keyLabel: String

    public init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// Modifiers in macOS order (Control, Option, Shift, Command) followed by the key.
    public var displayString: String {
        var text = ""
        if modifiers & Self.controlMask != 0 { text += "\u{2303}" }
        if modifiers & Self.optionMask != 0 { text += "\u{2325}" }
        if modifiers & Self.shiftMask != 0 { text += "\u{21E7}" }
        if modifiers & Self.commandMask != 0 { text += "\u{2318}" }
        return text + keyLabel
    }

    public static func validate(keyCode: UInt32, modifiers: UInt32) -> ValidationError? {
        let primary = commandMask | controlMask | optionMask
        guard modifiers & primary != 0 else { return .needsModifier }
        let isCommandShift = modifiers & commandMask != 0 && modifiers & shiftMask != 0
        if isCommandShift && reservedKeyCodes.contains(keyCode) { return .reservedBySystem }
        return nil
    }
}

/// Persists the capture shortcut and the floating-button toggle.
public struct CaptureHotkeyStore {
    private static let hotkeyKey = "captureHotkey"
    private static let buttonKey = "showCaptureButton"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> CaptureHotkey? {
        guard let data = defaults.data(forKey: Self.hotkeyKey) else { return nil }
        return try? JSONDecoder().decode(CaptureHotkey.self, from: data)
    }

    public func save(_ hotkey: CaptureHotkey) {
        guard let data = try? JSONEncoder().encode(hotkey) else { return }
        defaults.set(data, forKey: Self.hotkeyKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.hotkeyKey)
    }

    public var showCaptureButton: Bool {
        get { defaults.bool(forKey: Self.buttonKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.buttonKey) }
    }
}
