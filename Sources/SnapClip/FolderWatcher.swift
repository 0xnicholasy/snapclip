import CoreServices
import Foundation
import SnapClipCore

/// File-level FSEvents watcher. Callbacks are delivered on the main queue.
@MainActor
final class FolderWatcher {
    typealias Event = ScreenshotPipeline.Event

    // Only touched on the main actor, plus deinit where this object has a single owner.
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private let handler: @MainActor ([Event]) -> Void

    init(handler: @escaping @MainActor ([Event]) -> Void) {
        self.handler = handler
    }

    func start(folder: URL) {
        stop()
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: CFArray.self) as? [String] ?? []
            var events: [Event] = []
            for index in 0..<min(count, list.count) {
                events.append(Event(path: list[index], flags: .init(rawValue: eventFlags[index])))
            }
            MainActor.assumeIsolated { watcher.handler(events) }
        }
        guard let created = FSEventStreamCreate(
            nil, callback, &context, [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags)
        else {
            NSLog("SnapClip: could not create FSEventStream for %@", folder.path)
            return
        }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        // Stream is released in stop(); AppDelegate owns the watcher for the process lifetime.
    }
}
