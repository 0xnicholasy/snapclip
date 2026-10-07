import Foundation
import UniformTypeIdentifiers

public enum ScreenshotPolicy {
    /// Decides whether `path` is a fresh screenshot SnapClip should copy and track.
    /// A file whose identity was already seen (renamed, moved in, duplicated) is never accepted.
    public static func shouldTrack(
        path: String,
        watchedFolder: URL,
        seen: Set<FileIdentity>,
        now: Date
    ) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path
                == watchedFolder.resolvingSymlinksInPath().path,
            ScreenshotDetector.isCandidateName(url.lastPathComponent),
            isImage(url),
            let identity = FileIdentity.at(path: path), !seen.contains(identity),
            ScreenshotDetector.isScreenCapture(path: path),
            isRecent(path: path, now: now)
        else { return false }
        return true
    }

    private static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private static func isRecent(path: String, now: Date) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            attrs[.type] as? FileAttributeType == .typeRegular,
            let created = attrs[.creationDate] as? Date
        else { return false }
        return now.timeIntervalSince(created) <= SnapClipConstants.recentWindow
    }
}
