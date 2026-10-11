import Foundation

/// The `screencapture` invocation used for SnapClip's own captures.
public enum CaptureCommand {
    public static let executable = "/usr/sbin/screencapture"

    /// Interactive capture (Space toggles window mode, Esc cancels) saved into `folder`
    /// under the same name pattern macOS uses, so the watcher picks it up.
    public static func arguments(folder: URL, date: Date, timeZone: TimeZone = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screenshot \(formatter.string(from: date)).png"
        return ["-i", folder.appendingPathComponent(name).path]
    }
}
