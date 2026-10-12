import Foundation

/// Copies legacy process-local RNS state without replacing newer shared state.
/// The caller records completion only after every copy succeeds.
enum NodeStateMigration {
    static func copyMissingState(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            // The GRDB migration owns SQLite and its WAL/SHM as one snapshot.
            // Config is regenerated; identity is supplied from shared keychain.
            guard item.lastPathComponent != "config", item.lastPathComponent != "identity.bin",
                  !item.lastPathComponent.hasPrefix("lxmf-swift.db") else { continue }
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if !fileManager.fileExists(atPath: target.path) {
                try fileManager.copyItem(at: item, to: target)
            }
        }
    }
}
