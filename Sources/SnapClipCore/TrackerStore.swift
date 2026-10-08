import Foundation

public struct TrackedScreenshot: Codable, Equatable, Sendable {
    public let path: String
    public let inode: UInt64
    public let device: UInt64
    public let addedAt: Date

    public var identity: FileIdentity { FileIdentity(inode: inode, device: device) }

    public init(path: String, identity: FileIdentity, addedAt: Date) {
        self.path = path
        self.inode = identity.inode
        self.device = identity.device
        self.addedAt = addedAt
    }
}

/// Tracks screenshots and applies the retention policy. Not thread-safe:
/// use from one actor (the app uses the main actor).
public final class TrackerStore {
    public typealias Trash = (URL) throws -> Void

    private struct State: Codable {
        var items: [TrackedScreenshot]
        var seen: [FileIdentity]
    }

    public private(set) var items: [TrackedScreenshot]
    public private(set) var seen: [FileIdentity]
    private var dirty = false
    /// Set when the store file existed but could not be used; the next save moves it aside first.
    private var loadFailed = false
    private let storeURL: URL
    private let now: () -> Date
    private let trash: Trash
    private let identityOf: (String) -> FileIdentity?

    public static var defaultStoreURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SnapClip/tracked.json")
    }

    public static func systemTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public init(
        storeURL: URL = TrackerStore.defaultStoreURL,
        now: @escaping () -> Date = Date.init,
        trash: @escaping Trash = TrackerStore.systemTrash,
        identityOf: @escaping (String) -> FileIdentity? = { FileIdentity.at(path: $0) }
    ) {
        self.storeURL = storeURL
        self.now = now
        self.trash = trash
        self.identityOf = identityOf
        let loaded = Self.load(from: storeURL)
        self.items = loaded.state.items
        self.seen = loaded.state.seen
        self.loadFailed = loaded.unusable
    }

    /// Identities of every file ever tracked (bounded). A seen file is never tracked again,
    /// so a screenshot the user renamed or moved is kept.
    public var seenIdentities: Set<FileIdentity> { Set(seen) }

    public func isTracked(path: String) -> Bool {
        items.contains { $0.path == path }
    }

    /// Start tracking the file at `path` (no-op if missing or already tracked), then sweep.
    public func add(path: String) {
        guard !isTracked(path: path), let identity = identityOf(path) else { return }
        items.append(TrackedScreenshot(path: path, identity: identity, addedAt: now()))
        if !seen.contains(identity) {
            seen.append(identity)
            if seen.count > SnapClipConstants.maxSeen {
                seen.removeFirst(seen.count - SnapClipConstants.maxSeen)
            }
        }
        dirty = true
        sweep()
    }

    /// Drop moved files, trash expired ones, then trash oldest while over the cap.
    @discardableResult
    public func sweep() -> [URL] {
        var trashed: [URL] = []
        let before = items

        // 1. A file is only ours while the same inode/device sits at the original path.
        items.removeAll { identityOf($0.path) != $0.identity }

        // 2. Expired.
        let current = now()
        let expired = items.filter { current.timeIntervalSince($0.addedAt) >= SnapClipConstants.maxAge }
        for item in expired { trashItem(item, into: &trashed) }

        // 3. Over the cap: oldest first.
        while items.count > SnapClipConstants.maxTracked {
            guard let oldest = items.min(by: { $0.addedAt < $1.addedAt }) else { break }
            trashItem(oldest, into: &trashed)
        }

        if dirty || items != before {
            save()
            dirty = false
        }
        return trashed
    }

    /// Always stops tracking the item; a failed trash is not retried.
    private func trashItem(_ item: TrackedScreenshot, into trashed: inout [URL]) {
        items.removeAll { $0.path == item.path }
        let url = URL(fileURLWithPath: item.path)
        do {
            try trash(url)
            trashed.append(url)
        } catch {
            NSLog("SnapClip: could not trash %@: %@", item.path, String(describing: error))
        }
    }

    /// `unusable` is true when the file exists but could not be read or decoded, so the caller
    /// can preserve it before overwriting. A missing file or a permission error is not flagged:
    /// the first is normal, and the second skips the rename on purpose (constraint WS2); whether
    /// saves should be blocked in that case is an open backlog decision.
    private static func load(from url: URL) -> (state: State, unusable: Bool) {
        let empty = State(items: [], seen: [])
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            switch (error as? CocoaError)?.code {
            case .fileReadNoSuchFile:
                return (empty, false)
            case .fileReadNoPermission:
                NSLog("SnapClip: no permission to read %@: %@", url.path, String(describing: error))
                return (empty, false)
            default:
                NSLog("SnapClip: could not read %@: %@", url.path, String(describing: error))
                return (empty, true)
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stateError: Error
        do {
            return (try decoder.decode(State.self, from: data), false)
        } catch {
            stateError = error
        }
        // Older versions stored a bare array of tracked items.
        if let legacy = try? decoder.decode([TrackedScreenshot].self, from: data) {
            return (State(items: legacy, seen: legacy.map(\.identity)), false)
        }
        NSLog("SnapClip: could not decode %@: %@", url.path, String(describing: stateError))
        return (empty, true)
    }

    /// Moves an unusable store file aside once, before the first save overwrites it.
    private func preserveUnreadableStore() {
        loadFailed = false
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let sidecar = storeURL.deletingLastPathComponent()
            .appendingPathComponent("\(storeURL.lastPathComponent).unreadable-\(formatter.string(from: now()))")
        try? FileManager.default.moveItem(at: storeURL, to: sidecar)
    }

    private func save() {
        if loadFailed { preserveUnreadableStore() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(State(items: items, seen: seen)).write(to: storeURL, options: .atomic)
        } catch {
            NSLog("SnapClip: could not save tracker: %@", String(describing: error))
        }
    }
}
