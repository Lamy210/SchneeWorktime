import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public enum DatabaseFileError: Error, Equatable {
    case invalidURL, unsafeFile, system(Int32)
}

/// Defense in depth for the app's private local directory. The caller owns its directory and session lock.
enum DatabaseFileGuard {
    // macOS exposes legitimate ancestor aliases (for example /var -> /private/var).
    // Resolve only the parent: resolving the final component would hide prohibited database links.
    static func canonicalURL(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.hasDirectoryPath else { throw DatabaseFileError.invalidURL }
        return url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent)
    }

    static func prepare(_ url: URL, createIfMissing: Bool) throws -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath else { throw DatabaseFileError.invalidURL }
        try validateSidecars(url)
        if try existsAndValidate(url.path) {
            return false
        }
        guard createIfMissing else { throw DatabaseFileError.system(ENOENT) }
        let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DatabaseFileError.system(errno) }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw DatabaseFileError.system(errno) }
        // Do not remove a partially initialized database on error; normal reopen must fail closed.
        return true
    }

    static func validate(_ url: URL) throws {
        guard try existsAndValidate(url.path) else { throw DatabaseFileError.system(ENOENT) }
        try validateSidecars(url)
    }

    private static func validateSidecars(_ url: URL) throws {
        for suffix in ["-journal", "-wal", "-shm"] {
            _ = try existsAndValidate(url.path + suffix)
        }
    }

    private static func existsAndValidate(_ path: String) throws -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            if code == ENOENT {
                return false
            }
            throw DatabaseFileError.system(code)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0
        else { throw DatabaseFileError.unsafeFile }
        return true
    }
}
