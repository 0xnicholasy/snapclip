import CoreServices
import Foundation

/// Turns folder events into tracked screenshots: filter, wait until the file is stable, copy, then add.
/// Main-actor only; the app drives it from the FSEvents callback.
@MainActor
public final class ScreenshotPipeline {
    /// Raw values equal the FSEventStreamEventFlags bits, so a watcher can wrap its flags directly.
    public struct EventFlags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let itemCreated = EventFlags(rawValue: UInt32(kFSEventStreamEventFlagItemCreated))
        public static let itemRenamed = EventFlags(rawValue: UInt32(kFSEventStreamEventFlagItemRenamed))
        public static let itemModified = EventFlags(rawValue: UInt32(kFSEventStreamEventFlagItemModified))
        public static let itemXattrMod = EventFlags(rawValue: UInt32(kFSEventStreamEventFlagItemXattrMod))
        public static let itemIsFile = EventFlags(rawValue: UInt32(kFSEventStreamEventFlagItemIsFile))
        public static let mustScanSubDirs = EventFlags(
            rawValue: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
        public static let userDropped = EventFlags(rawValue: UInt32(kFSEventStreamEventFlagUserDropped))
        public static let kernelDropped = EventFlags(rawValue: UInt32(kFSEventStreamEventFlagKernelDropped))
        public static let rootChanged = EventFlags(rawValue: UInt32(kFSEventStreamEventFlagRootChanged))

        static let relevant: EventFlags = [.itemCreated, .itemRenamed, .itemModified, .itemXattrMod]
        static let needsRescan: EventFlags = [.mustScanSubDirs, .userDropped, .kernelDropped, .rootChanged]
    }

    public struct Event: Sendable {
        public let path: String
        public let flags: EventFlags

        public init(path: String, flags: EventFlags) {
            self.path = path
            self.flags = flags
        }
    }

    public let store: TrackerStore
    public var watchedFolder: URL
    private var inFlight: Set<FileIdentity> = []
    private let waitUntilStable: @MainActor (String) async -> Bool
    private let copy: @MainActor (URL) -> Bool
    private let listFolder: @MainActor (URL) -> [String]
    private let identityOf: @MainActor (String) -> FileIdentity?
    private let now: @MainActor () -> Date

    public init(
        store: TrackerStore,
        watchedFolder: URL,
        waitUntilStable: @escaping @MainActor (String) async -> Bool = {
            await ScreenshotDetector.waitUntilStable(path: $0)
        },
        copy: @escaping @MainActor (URL) -> Bool,
        listFolder: @escaping @MainActor (URL) -> [String] = {
            (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
        },
        identityOf: @escaping @MainActor (String) -> FileIdentity? = { FileIdentity.at(path: $0) },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.store = store
        self.watchedFolder = watchedFolder
        self.waitUntilStable = waitUntilStable
        self.copy = copy
        self.listFolder = listFolder
        self.identityOf = identityOf
        self.now = now
    }

    /// Handles a batch of events. Returns the tasks it spawned so callers (tests) can await them.
    @discardableResult
    public func handle(_ events: [Event]) -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []
        if events.contains(where: { !$0.flags.isDisjoint(with: .needsRescan) }) {
            tasks += rescanWatchedFolder()
        }
        for event in events
        where event.flags.contains(.itemIsFile) && !event.flags.isDisjoint(with: .relevant) {
            if let task = consider(path: event.path) { tasks.append(task) }
        }
        return tasks
    }

    private func rescanWatchedFolder() -> [Task<Void, Never>] {
        let names = listFolder(watchedFolder)
        return names.compactMap { consider(path: watchedFolder.appendingPathComponent($0).path) }
    }

    private func consider(path: String) -> Task<Void, Never>? {
        guard let identity = identityOf(path), !inFlight.contains(identity),
            ScreenshotPolicy.shouldTrack(
                path: path, watchedFolder: watchedFolder, seen: store.seenIdentities, now: now())
        else { return nil }

        let url = URL(fileURLWithPath: path)
        inFlight.insert(identity)
        return Task { @MainActor in
            let stable = await waitUntilStable(path)
            inFlight.remove(identity)
            guard stable, identityOf(path) == identity, copy(url)
            else { return }
            store.add(path: path)
        }
    }
}
