import Foundation

/// A SnapClip bundle that lives under `<prefix>/Cellar/snapclip/<version>/`, i.e. installed by
/// Homebrew. Paths are derived from the bundle path only; PATH is never searched.
public struct HomebrewInstall: Equatable, Sendable {
    public let prefix: String

    /// Only the standard Homebrew prefixes are trusted: the derived `brew` path gets executed.
    public static let allowedPrefixes: Set<String> = ["/opt/homebrew", "/usr/local"]

    /// Environment variables passed through to brew when set (proxy, TLS and user identity).
    public static let passthroughEnvironmentKeys = [
        "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "ALL_PROXY",
        "https_proxy", "http_proxy", "no_proxy", "all_proxy",
        "SSL_CERT_FILE", "USER", "LOGNAME", "TMPDIR",
    ]

    public init?(bundlePath: String) {
        let marker = "/Cellar/snapclip/"
        guard let range = bundlePath.range(of: marker), !bundlePath[range.upperBound...].isEmpty else {
            return nil
        }
        let prefix = String(bundlePath[..<range.lowerBound])
        guard Self.allowedPrefixes.contains(prefix) else { return nil }
        self.prefix = prefix
    }

    public var brewPath: String { prefix + "/bin/brew" }

    /// Path that survives `brew upgrade`; relaunch from here.
    public var stableAppPath: String { prefix + "/opt/snapclip/SnapClip.app" }

    public var environment: [String: String] {
        environment(inheriting: ProcessInfo.processInfo.environment)
    }

    public func environment(inheriting parent: [String: String]) -> [String: String] {
        var env = [String: String]()
        for key in Self.passthroughEnvironmentKeys {
            if let value = parent[key] { env[key] = value }
        }
        env.merge([
            "PATH": "\(prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
        ]) { _, fixed in fixed }
        return env
    }
}
