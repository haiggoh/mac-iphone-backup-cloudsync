import Foundation

/// A cross-process advisory lock, so two launches cannot archive at once.
///
/// The previous design guarded a boolean on one object in one process, which does
/// nothing when launchd starts a second copy while the first is still running —
/// and `open -b` returns immediately, so launchd will happily do exactly that.
///
/// `flock` is used rather than a lock directory because the kernel releases it
/// when the file descriptor closes, including on crash or SIGKILL. A directory or
/// pidfile left behind by a killed process becomes a permanent lock that requires
/// manual cleanup — which for an unattended tool means it silently stops working
/// forever.
public final class ProcessLock {

    public enum Acquisition: Equatable {
        case acquired
        /// Another live process holds it. For an unattended run this is a normal,
        /// successful outcome, not an error.
        case heldByAnotherProcess
    }

    public enum LockError: Error, Equatable {
        case cannotOpen(path: String, errno: Int32)
        case cannotLock(path: String, errno: Int32)
    }

    private let url: URL
    private let fileManager: FileManager
    private var descriptor: Int32 = -1

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public var isHeld: Bool { descriptor >= 0 }

    @discardableResult
    public func acquire() throws -> Acquisition {
        guard descriptor < 0 else { return .acquired }

        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 0o600: the path is per-user and the file records a pid; no reason for
        // anyone else to read or write it.
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw LockError.cannotOpen(path: url.path, errno: errno)
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            // EWOULDBLOCK is the whole point: somebody else is running.
            if code == EWOULDBLOCK || code == EAGAIN {
                return .heldByAnotherProcess
            }
            throw LockError.cannotLock(path: url.path, errno: code)
        }

        descriptor = fd
        writeDiagnosticPID()
        return .acquired
    }

    /// Records who holds the lock. Purely diagnostic — correctness comes from
    /// flock, never from reading this back, so a stale pid here is harmless.
    private func writeDiagnosticPID() {
        guard descriptor >= 0 else { return }
        ftruncate(descriptor, 0)
        lseek(descriptor, 0, SEEK_SET)
        let line = "\(getpid())\n"
        _ = line.withCString { pointer in
            write(descriptor, pointer, strlen(pointer))
        }
    }

    public func release() {
        guard descriptor >= 0 else { return }
        // Closing releases the flock; being explicit documents the intent.
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
