import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Held for the node's lifetime. The kernel releases it if its process dies.
/// A mode preference or a disconnected tunnel status alone cannot establish
/// that the other process has finished releasing its interfaces.
///
/// iOS SIGKILLs (0xdead10cc) any app suspended while holding a file lock on a
/// shared (App Group) container, so the app-side owner must drop the lock
/// before suspension via `releaseForBackground()` and restore it on return
/// with `resumeFromBackground(reacquireAt:)`. While the suspension flag is
/// set, `acquire(at:)` refuses, so a startup thread still running during the
/// background window cannot re-take the lock after the handler dropped it.
final class NodeProcessLease: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var suspendedForBackground = false
    private var heldURL: URL?
    private var restoreOnResume = false

    func acquire(at url: URL) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if suspendedForBackground { return false }
        if descriptor >= 0 { return true }
        return flockNewDescriptorLocked(url)
    }

    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        closeDescriptorLocked(explicit: true)
    }

    /// Drop the flock before iOS suspends the process. The node's threads are
    /// frozen by suspension anyway, so the lock protects nothing across it.
    /// Remembers whether THIS call dropped a held lock, so a resume restores
    /// ownership even when the caller's node-state snapshot cannot see an
    /// in-flight `start()` that acquired it.
    func releaseForBackground() {
        stateLock.lock()
        defer { stateLock.unlock() }
        suspendedForBackground = true
        restoreOnResume = descriptor >= 0
        closeDescriptorLocked()
    }

    /// Clear the suspension flag after returning to the foreground. Pass the
    /// lease URL when a live node still needs ownership (re-taking the flock
    /// if someone else claimed it meanwhile); pass nil when the caller's
    /// node-state snapshot shows no live node. With nil, a lease that was
    /// HELD at background time still restores its own ownership: a `start()`
    /// in flight acquired the lease before `isRunning` flips, so the caller
    /// cannot see that ownership must come back. An explicit `release()`
    /// during the background window (a completed stop) suppresses this. The
    /// suspension flag is cleared even when re-acquisition fails, so a later
    /// `start()` can try again.
    func resumeFromBackground(reacquireAt url: URL?) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        suspendedForBackground = false
        let restore = restoreOnResume
        restoreOnResume = false
        guard let url else {
            guard restore, let heldURL else { return true }
            return flockNewDescriptorLocked(heldURL)
        }
        if descriptor >= 0 { return true }
        return flockNewDescriptorLocked(url)
    }

    deinit { release() }

    /// Caller must hold `stateLock`.
    private func flockNewDescriptorLocked(_ url: URL) -> Bool {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        descriptor = fd
        heldURL = url
        return true
    }

    /// Caller must hold `stateLock`. An explicit close is a deliberate
    /// relinquishment (node stopped), so it cancels any pending
    /// background-restore; the suspend path keeps the intent to restore.
    private func closeDescriptorLocked(explicit: Bool = false) {
        if explicit { restoreOnResume = false }
        if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
    }
}
