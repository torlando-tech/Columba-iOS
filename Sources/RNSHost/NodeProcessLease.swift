import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Held for the node's lifetime. The kernel releases it if its process dies.
/// A mode preference or a disconnected tunnel status alone cannot establish
/// that the other process has finished releasing its interfaces.
final class NodeProcessLease {
    private var descriptor: Int32 = -1
    func acquire(at url: URL) -> Bool {
        if descriptor >= 0 { return true }
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        descriptor = fd
        return true
    }
    func release() {
        if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
    }
    deinit { release() }
}
