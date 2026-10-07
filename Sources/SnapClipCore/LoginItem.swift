import Foundation

public struct LoginItem {
    public let launchAgentsDirectory: URL

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    public init(launchAgentsDirectory: URL = LoginItem.defaultDirectory) {
        self.launchAgentsDirectory = launchAgentsDirectory
    }

    public var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(SnapClipConstants.bundleIdentifier).plist")
    }

    /// Toggle state is simply whether the plist exists.
    public var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    public func enable(appPath: String) throws {
        let plist: [String: Any] = [
            "Label": SnapClipConstants.bundleIdentifier,
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    public func disable() throws {
        guard isEnabled else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    /// Maps "<prefix>/Cellar/snapclip/<version>/rest" to "<prefix>/opt/snapclip/rest" so the
    /// path survives `brew upgrade`. Any other path is returned unchanged.
    public static func stableAppPath(bundlePath: String) -> String {
        let marker = "/Cellar/snapclip/"
        guard let range = bundlePath.range(of: marker) else { return bundlePath }
        let prefix = String(bundlePath[..<range.lowerBound])
        let afterMarker = bundlePath[range.upperBound...]
        guard let slash = afterMarker.firstIndex(of: "/") else { return bundlePath }
        let rest = afterMarker[slash...]
        return prefix + "/opt/snapclip" + rest
    }
}
