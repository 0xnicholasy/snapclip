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
    public static let bundleIdentifier = "io.github.0xnicholasy.snapclip"
    public static let screenCaptureXattr = "com.apple.metadata:kMDItemIsScreenCapture"
    public static let screenCaptureDomain = "com.apple.screencapture"
}
