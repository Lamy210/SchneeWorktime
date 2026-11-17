import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public enum LocalSessionLockError: Error, Equatable {
    case unsafeDirectory, unsafeLockFile, alreadyLocked, system(Int32)
}

/// An advisory lock for cooperating app processes. Keep it alive until all writes stop.
public final class LocalSessionLock {
    private let descriptor: Int32

    public init(directory: URL) throws {
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & 0o077 == 0
        else {
            throw LocalSessionLockError.unsafeDirectory
        }
        let path = directory.appendingPathComponent("session.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw LocalSessionLockError.system(errno) }
        do {
            try Self.acquire(fd)
        } catch {
            close(fd)
            throw error
        }
        descriptor = fd
    }

    deinit {
        close(descriptor)
    }

    private static func acquire(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw LocalSessionLockError.system(errno) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0
        else {
            throw LocalSessionLockError.unsafeLockFile
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                throw LocalSessionLockError.alreadyLocked
            }
            throw LocalSessionLockError.system(code)
        }
    }
}
