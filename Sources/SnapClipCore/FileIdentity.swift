import Foundation

/// Inode + device identity of a file, read with stat(2).
public struct FileIdentity: Codable, Hashable, Sendable {
    public let inode: UInt64
    public let device: UInt64

    public init(inode: UInt64, device: UInt64) {
        self.inode = inode
        self.device = device
    }

    /// Identity of the file currently at `path`, or nil if nothing is there.
    public static func at(path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(inode: UInt64(info.st_ino), device: UInt64(info.st_dev))
    }
}
