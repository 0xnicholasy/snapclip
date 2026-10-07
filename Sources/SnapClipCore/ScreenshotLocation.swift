import Foundation

public enum ScreenshotLocation {
    /// Reads `location` from the com.apple.screencapture domain; falls back to ~/Desktop.
    public static func resolve(
        defaults: UserDefaults? = UserDefaults(suiteName: SnapClipConstants.screenCaptureDomain),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let fallback = home.appendingPathComponent("Desktop", isDirectory: true)
        guard let raw = defaults?.string(forKey: "location"), !raw.isEmpty else { return fallback }
        let expanded: String
        if raw == "~" {
            expanded = home.path
        } else if raw.hasPrefix("~/") {
            expanded = home.appendingPathComponent(String(raw.dropFirst(2))).path
        } else {
            expanded = raw
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            return fallback
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
