import Foundation
import Testing
@testable import SnapClipCore

@Suite struct CaptureHotkeyTests {
    private let cmd = CaptureHotkey.commandMask
    private let shift = CaptureHotkey.shiftMask
    private let opt = CaptureHotkey.optionMask
    private let ctrl = CaptureHotkey.controlMask

    @Test func displayStringUsesMacOrder() {
        let hotkey = CaptureHotkey(keyCode: 1, modifiers: cmd | shift | opt | ctrl, keyLabel: "S")
        #expect(hotkey.displayString == "\u{2303}\u{2325}\u{21E7}\u{2318}S")
        let two = CaptureHotkey(keyCode: 1, modifiers: opt | ctrl, keyLabel: "S")
        #expect(two.displayString == "\u{2303}\u{2325}S")
    }

    @Test func validationRejectsShiftOnlyAndNoModifier() {
        #expect(CaptureHotkey.validate(keyCode: 1, modifiers: shift) == .needsModifier)
        #expect(CaptureHotkey.validate(keyCode: 1, modifiers: 0) == .needsModifier)
    }

    @Test func validationRejectsSystemScreenshotShortcuts() {
        for code: UInt32 in [20, 21, 23] {
            #expect(CaptureHotkey.validate(keyCode: code, modifiers: cmd | shift) == .reservedBySystem)
        }
        #expect(CaptureHotkey.validate(keyCode: 22, modifiers: cmd | shift) == nil)
        #expect(CaptureHotkey.validate(keyCode: 1, modifiers: ctrl | opt) == nil)
        #expect(CaptureHotkey.validate(keyCode: 20, modifiers: cmd) == nil)
    }

    @Test func storeRoundTripsAndClears() throws {
        let suite = "snapclip-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CaptureHotkeyStore(defaults: defaults)
        #expect(store.load() == nil)
        let hotkey = CaptureHotkey(keyCode: 1, modifiers: ctrl | opt, keyLabel: "S")
        store.save(hotkey)
        #expect(store.load() == hotkey)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func showCaptureButtonDefaultsOffAndPersists() throws {
        let suite = "snapclip-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CaptureHotkeyStore(defaults: defaults)
        #expect(store.showCaptureButton == false)
        store.showCaptureButton = true
        #expect(CaptureHotkeyStore(defaults: defaults).showCaptureButton == true)
    }

    @Test func captureArgumentsBuildExpectedPath() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13:20 UTC
        let args = CaptureCommand.arguments(
            folder: URL(fileURLWithPath: "/tmp/shots", isDirectory: true), date: date, timeZone: utc)
        #expect(args == ["-i", "/tmp/shots/Screenshot 2023-11-14 at 22.13.20.png"])
        #expect(CaptureCommand.executable == "/usr/sbin/screencapture")
    }
}
