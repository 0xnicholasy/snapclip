import Foundation

/// Reads and writes the macOS screenshot thumbnail setting (`show-thumbnail`).
/// While the floating thumbnail is shown, macOS saves the file only after it closes (~10 s).
public struct ScreenCaptureSettings {
    static let thumbnailKey = "show-thumbnail"
    private let defaults: UserDefaults?

    public init(
        defaults: UserDefaults? = UserDefaults(suiteName: SnapClipConstants.screenCaptureDomain)
    ) {
        self.defaults = defaults
    }

    /// macOS shows the thumbnail when the key is unset.
    public var isThumbnailEnabled: Bool {
        defaults?.object(forKey: Self.thumbnailKey) as? Bool ?? true
    }

    public var isInstantCopyEnabled: Bool { !isThumbnailEnabled }

    public func setInstantCopy(_ enabled: Bool) {
        defaults?.set(!enabled, forKey: Self.thumbnailKey)
        defaults?.synchronize()
    }
}

/// Read-only view of the macOS setting that hides Desktop icons.
public struct DesktopSettings {
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = UserDefaults(suiteName: SnapClipConstants.windowManagerDomain)) {
        self.defaults = defaults
    }

    public var iconsHidden: Bool { defaults?.bool(forKey: "HideDesktop") ?? false }
}
