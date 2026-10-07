import Foundation

public enum ScreenshotDetector {
    /// True if the file carries the macOS screen-capture extended attribute.
    public static func isScreenCapture(path: String) -> Bool {
        getxattr(path, SnapClipConstants.screenCaptureXattr, nil, 0, 0, 0) >= 0
    }

    /// Dotfiles (including screencapture's hidden temp files) are ignored.
    public static func isCandidateName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".")
    }

    /// Polls the file size until it is non-zero and unchanged for `requiredStable` consecutive polls.
    public static func waitUntilStable(
        path: String,
        interval: Duration = .milliseconds(200),
        timeout: Duration = .seconds(5),
        requiredStable: Int = 2
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastSize: UInt64?
        var stableCount = 0
        while clock.now < deadline {
            guard let size = fileSize(path: path) else { return false }
            if size > 0, size == lastSize {
                stableCount += 1
                if stableCount >= requiredStable { return true }
            } else {
                stableCount = 0
            }
            lastSize = size
            try? await Task.sleep(for: interval)
        }
        return false
    }

    private static func fileSize(path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(info.st_size)
    }
}
