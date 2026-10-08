import Foundation

/// Strict `MAJOR.MINOR.PATCH` version with an optional leading `v`. Anything else is rejected.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ string: String) {
        var text = Substring(string)
        if text.hasPrefix("v") { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // ASCII digits only: Int("+1") and Int("-1") would otherwise parse.
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part)
            else { return nil }
            numbers.append(n)
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct ReleaseInfo: Equatable, Sendable {
    public let version: SemanticVersion
    public let pageURL: URL
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(current: SemanticVersion)
    case updateAvailable(ReleaseInfo)
}

public enum UpdateError: Error, Equatable, LocalizedError {
    case invalidCurrentVersion(String)
    case httpStatus(Int)
    case malformedResponse
    case unrecognizedTag(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion(let v): return "Could not read the installed version (\"\(v)\")."
        case .httpStatus(let code): return "GitHub returned HTTP \(code)."
        case .malformedResponse: return "GitHub returned an unexpected response."
        case .unrecognizedTag(let tag): return "The latest release tag \"\(tag)\" is not a MAJOR.MINOR.PATCH version."
        }
    }
}

public struct UpdateChecker: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> Data

    public static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/0xnicholasy/snapclip/releases/latest")!

    private struct Payload: Decodable {
        let tag_name: String
        let html_url: String
    }

    public let currentVersion: String
    private let fetch: Fetch

    public init(currentVersion: String, fetch: @escaping Fetch = UpdateChecker.liveFetch) {
        self.currentVersion = currentVersion
        self.fetch = fetch
    }

    public static let liveFetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.httpStatus(http.statusCode)
        }
        return data
    }

    public func makeRequest() -> URLRequest {
        var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: SnapClipConstants.updateRequestTimeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SnapClip/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    public func check() async throws -> UpdateCheckResult {
        guard let current = SemanticVersion(currentVersion) else {
            throw UpdateError.invalidCurrentVersion(currentVersion)
        }
        let data = try await fetch(makeRequest())
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw UpdateError.malformedResponse
        }
        guard let latest = SemanticVersion(payload.tag_name) else {
            throw UpdateError.unrecognizedTag(payload.tag_name)
        }
        // html_url is only a sanity check; the URL opened in the browser is built from the validated version.
        guard let reported = URL(string: payload.html_url), reported.scheme == "https",
            reported.host == "github.com",
            let url = URL(string: "https://github.com/0xnicholasy/snapclip/releases/tag/v\(latest)")
        else { throw UpdateError.malformedResponse }
        return latest > current
            ? .updateAvailable(ReleaseInfo(version: latest, pageURL: url))
            : .upToDate(current: current)
    }
}

/// Seconds to wait before the next automatic update check.
public enum UpdateSchedule {
    public static func delayUntilNextCheck(lastCheck: Date?, now: Date) -> TimeInterval {
        guard let lastCheck else { return SnapClipConstants.updateInitialDelay }
        let remaining = SnapClipConstants.updateCheckInterval - now.timeIntervalSince(lastCheck)
        return min(SnapClipConstants.updateCheckInterval, max(SnapClipConstants.updateInitialDelay, remaining))
    }
}
