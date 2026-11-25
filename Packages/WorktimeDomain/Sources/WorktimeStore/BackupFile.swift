import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public enum BackupFileError: Error, Equatable {
    case invalidDestination, unsafeDirectory, unsafeFile, tooLarge, system(Int32)
    case publicationUncertain(Int32)
}

/// Local plaintext archive I/O. A private directory is required; this is not protection against the same user.
package enum BackupFile {
    /// Existing CSV and schema-1 archives retain their original default limit.
    static let maxBytes = 24 * 1024 * 1024
    /// Hard upper bound for explicitly opted-in schema-2 archive I/O.
    static let maxSupportedBytes = 96 * 1024 * 1024

    package static func publish(_ data: Data, to url: URL) throws {
        try publish(data, to: url, maxBytes: maxBytes)
    }

    static func publish(_ data: Data, to url: URL, maxBytes: Int) throws {
        try publish(data, to: url, maxBytes: maxBytes, synchronizeDirectory: syncDirectory)
    }

    /// The final file may exist if publication succeeded but directory synchronization failed.
    static func publish(_ data: Data, to url: URL, synchronizeDirectory: (Int32) throws -> Void) throws {
        try publish(data, to: url, maxBytes: maxBytes, synchronizeDirectory: synchronizeDirectory)
    }

    private static func publish(
        _ data: Data, to url: URL, maxBytes: Int, synchronizeDirectory: (Int32) throws -> Void
    ) throws {
        guard maxBytes > 0, maxBytes <= maxSupportedBytes, data.count <= maxBytes
        else { throw BackupFileError.tooLarge }
        try withDirectory(url) { directory, name in
            let temp = ".worktime-\(UUID().uuidString).partial"
            let fd = openat(directory, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw BackupFileError.system(errno) }
            var temporaryExists = true
            defer {
                close(fd)
                if temporaryExists {
                    unlinkat(directory, temp, 0)
                }
            }
            guard fchmod(fd, 0o600) == 0 else { throw BackupFileError.system(errno) }
            try writeAll(data, fd: fd)
            guard fsync(fd) == 0 else { throw BackupFileError.system(errno) }
            // Publish only a complete file, without replacing even a dangling symlink.
            guard linkat(directory, temp, directory, name, 0) == 0 else {
                throw BackupFileError.system(errno)
            }
            guard unlinkat(directory, temp, 0) == 0 else { throw BackupFileError.publicationUncertain(errno) }
            temporaryExists = false
            try synchronizeDirectory(directory)
        }
    }

    private static func syncDirectory(_ directory: Int32) throws {
        while fsync(directory) != 0 {
            let code = errno
            guard code == EINTR else { throw BackupFileError.publicationUncertain(code) }
        }
    }

    static func load(_ url: URL) throws -> Data {
        try load(url, maxBytes: maxBytes)
    }

    static func load(_ url: URL, maxBytes: Int) throws -> Data {
        guard maxBytes > 0, maxBytes <= maxSupportedBytes else { throw BackupFileError.tooLarge }
        return try withDirectory(url) { directory, name in
            let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw BackupFileError.system(errno) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw BackupFileError.system(errno) }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
                  info.st_nlink == 1, info.st_mode & 0o077 == 0
            else { throw BackupFileError.unsafeFile }
            guard info.st_size >= 0, info.st_size <= maxBytes else { throw BackupFileError.tooLarge }
            return try readAll(fd: fd, maxBytes: maxBytes)
        }
    }

    private static func withDirectory<T>(_ url: URL, _ body: (Int32, String) throws -> T) throws -> T {
        let name = url.lastPathComponent
        guard url.isFileURL, !url.hasDirectoryPath, !name.isEmpty, name != ".", name != "..", name != "/"
        else { throw BackupFileError.invalidDestination }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw BackupFileError.system(errno) }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0 else { throw BackupFileError.system(errno) }
        guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw BackupFileError.unsafeDirectory }
        return try body(directory, name)
    }

    private static func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let base = bytes.baseAddress else { throw BackupFileError.unsafeFile }
                let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else { throw BackupFileError.system(count < 0 ? errno : EIO) }
                offset += count
            }
        }
    }

    private static func readAll(fd: Int32, maxBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else { throw BackupFileError.system(errno) }
            guard count > 0 else { return data }
            guard count <= maxBytes - data.count else { throw BackupFileError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
