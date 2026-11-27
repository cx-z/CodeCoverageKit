#if CODE_COVERAGE_KIT_ENABLED
import Darwin
import Foundation

/// Collector-confined durable publication using same-directory rename and explicit storage flush boundaries.
final class CoverageDurableFile {
    enum Boundary: CaseIterable {
        case beforeWrite, afterWrite, beforeFileSync, afterFileSync, beforeRename, afterRename
        case beforeDirectorySync, afterDirectorySync, beforeFlush, afterFlush
    }
    private let vFault: (Boundary) throws -> Void

    /// Installs optional boundary fault injection; no global filesystem hooks or shared mutable state are used.
    init(fault: @escaping (Boundary) throws -> Void = { _ in }) { vFault = fault }

    /// Creates each missing directory and syncs its own and its parent's namespace before later file publication.
    func createDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        let t_parent = url.deletingLastPathComponent()
        try createDirectory(t_parent)
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw p_error() }
        try p_syncDirectory(url)
        try p_syncDirectory(t_parent)
    }

    /// Writes/syncs complete bytes, publishes atomically, re-syncs the owned directory chain, then flushes storage again.
    func write(_ data: Data, to url: URL, syncThrough anchor: URL? = nil) throws {
        try createDirectory(url.deletingLastPathComponent())
        let t_temporary = url.deletingLastPathComponent().appendingPathComponent(".commit-\(UUID().uuidString)")
        let t_fd = open(t_temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard t_fd >= 0 else { throw p_error() }
        defer { close(t_fd); try? FileManager.default.removeItem(at: t_temporary) }
        try vFault(.beforeWrite)
        try data.withUnsafeBytes { t_bytes in
            var t_offset = 0
            while t_offset < t_bytes.count {
                let t_written = Darwin.write(t_fd, t_bytes.baseAddress!.advanced(by: t_offset), t_bytes.count - t_offset)
                if t_written < 0 && errno == EINTR { continue }
                guard t_written > 0 else { throw p_error() }
                t_offset += t_written
            }
        }
        try vFault(.afterWrite)
        try vFault(.beforeFileSync)
        try p_flush(t_fd)
        try vFault(.afterFileSync)
        try vFault(.beforeRename)
        guard rename(t_temporary.path, url.path) == 0 else { throw p_error() }
        try vFault(.afterRename)
        try vFault(.beforeDirectorySync)
        try p_syncDirectoryChain(url.deletingLastPathComponent(), through: anchor ?? url.deletingLastPathComponent())
        try vFault(.afterDirectorySync)
        try vFault(.beforeFlush)
        try p_flush(t_fd)
        try vFault(.afterFlush)
    }

    /// Reestablishes the commit boundary before a recovered record or receipt can imply completed obligations.
    func synchronizeExisting(_ url: URL, syncThrough anchor: URL? = nil) throws {
        let t_fd = open(url.path, O_RDWR | O_NOFOLLOW)
        guard t_fd >= 0 else { throw p_error() }
        defer { close(t_fd) }
        try p_syncDirectoryChain(url.deletingLastPathComponent(), through: anchor ?? url.deletingLastPathComponent())
        try p_flush(t_fd)
    }

    /// Propagates both filesystem-sync and Darwin full-storage-flush failures; unsupported flush never counts as success.
    private func p_flush(_ fd: Int32) throws {
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw p_error() }
    }

    /// Re-syncs the full owned namespace chain, including directories left visible by a prior interrupted/failed commit.
    private func p_syncDirectoryChain(_ directory: URL, through anchor: URL) throws {
        var t_directory = directory.standardizedFileURL
        let t_anchor = anchor.standardizedFileURL
        guard t_directory == t_anchor || t_directory.path.hasPrefix(t_anchor.path == "/" ? "/" : t_anchor.path + "/") else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        while true {
            try p_syncDirectory(t_directory)
            if t_directory == t_anchor { return }
            t_directory.deleteLastPathComponent()
        }
    }

    /// Syncs directory entries without assuming a regular-file atomic write also persists its namespace.
    private func p_syncDirectory(_ url: URL) throws {
        let t_fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard t_fd >= 0 else { throw p_error() }
        defer { close(t_fd) }
        guard fsync(t_fd) == 0 else { throw p_error() }
    }

    /// Returns the POSIX error without including profile bytes, credentials or file paths.
    private func p_error() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
#endif
