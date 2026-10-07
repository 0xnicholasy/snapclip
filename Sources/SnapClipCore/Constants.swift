import Foundation

/// All tunable values live here.
public enum SnapClipConstants {
    public static let maxTracked = 5
    /// Seconds after which a tracked screenshot is trashed.
    public static let maxAge: TimeInterval = 300
    /// Seconds between retention sweeps.
    public static let sweepInterval: TimeInterval = 10
    /// Screenshots older than this (by creation date) are never auto-copied.
    public static let recentWindow: TimeInterval = 30
    public static let maxSeen = 200
    /// Seconds between automatic update checks.
    public static let updateCheckInterval: TimeInterval = 24 * 60 * 60
    /// Seconds after launch before the first automatic update check.
    public static let updateInitialDelay: TimeInterval = 5
    public static let updateRequestTimeout: TimeInterval = 15
    /// Seconds before retrying an automatic check that failed.
    public static let updateRetryInterval: TimeInterval = 60 * 60
    public static let bundleIdentifier = "io.github.0xnicholasy.snapclip"
    public static let screenCaptureXattr = "com.apple.metadata:kMDItemIsScreenCapture"
    public static let screenCaptureDomain = "com.apple.screencapture"
    public static let windowManagerDomain = "com.apple.WindowManager"
}
