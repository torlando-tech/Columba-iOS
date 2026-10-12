import Foundation

// Runs the production Foundation-only host seam on Darwin and Linux.
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let first = NodeProcessLease()
let second = NodeProcessLease()
let lockURL = root.appendingPathComponent("owner.lock")
require(first.acquire(at: lockURL), "first host must own the lease")
require(!second.acquire(at: lockURL), "second host must not start concurrently")
first.release()
require(second.acquire(at: lockURL), "ownership must transfer after release")
require(!first.acquire(at: lockURL), "old host must not take new owner's lock")
second.release()

let source = root.appendingPathComponent("private")
let destination = root.appendingPathComponent("shared")
try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
try Data("old".utf8).write(to: source.appendingPathComponent("known_destinations"))
try Data("new".utf8).write(to: destination.appendingPathComponent("known_destinations"))
try Data("routes".utf8).write(to: source.appendingPathComponent("path_table"))
try Data("wal".utf8).write(to: source.appendingPathComponent("lxmf-swift.db-wal"))
try NodeStateMigration.copyMissingState(from: source, to: destination)
try NodeStateMigration.copyMissingState(from: source, to: destination)
let existing = try Data(contentsOf: destination.appendingPathComponent("known_destinations"))
let migrated = try Data(contentsOf: destination.appendingPathComponent("path_table"))
require(existing == Data("new".utf8), "migration must retain newer shared state")
require(migrated == Data("routes".utf8), "migration must retain old route state")
require(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("lxmf-swift.db-wal").path), "SQLite migration owns WAL consistency")

let request = ProxyRequest.lxmfSend(destHashHex: "peer", content: "body", method: "direct", fieldsData: Data([1, 2]), sendId: "stable", failureFallbackMethod: "propagated")
let decoded = try ProxyIPC.decodeRequest(ProxyIPC.encodeRequest(request))
guard case .lxmfSend(let hash, let body, let method, let fields, let id, let fallback) = decoded else {
    fatalError("send command failed to round-trip")
}
require(hash == "peer" && body == "body" && method == "direct", "command must preserve send intent")
require(fields == Data([1, 2]) && id == "stable" && fallback == "propagated", "command must retain fields, dedup, and fallback")
let entry = OutboxEntry(destHashHex: hash, content: body, method: method, fieldsData: fields, messageHashHex: nil, sendId: id, createdAt: 1, failureFallbackMethod: fallback)
let restored = try JSONDecoder().decode(OutboxEntry.self, from: JSONEncoder().encode(entry))
require(restored == entry, "durable recovery must preserve the complete command")
let legacy = Data("{\"destHashHex\":\"peer\",\"content\":\"old\",\"method\":\"direct\",\"createdAt\":1}".utf8)
let oldEntry = try JSONDecoder().decode(OutboxEntry.self, from: legacy)
require(oldEntry.failureFallbackMethod == nil && oldEntry.sendId == nil, "old outbox records must remain readable")

let suiteName = "test.host-mode.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }
require(NodeHostingMode.resolve(defaults: defaults) == .networkExtension, "background must be the default")
NodeHostingMode.activateSelection(defaults: defaults)
defaults.set("foreground", forKey: NodeHostingMode.preferenceKey)
require(NodeHostingMode.resolveActive(defaults: defaults) == .networkExtension, "saving a choice must not affect tunnel reconnect before app relaunch")
NodeHostingMode.activateSelection(defaults: defaults)
require(NodeHostingMode.resolveActive(defaults: defaults) == .foreground, "fresh app launch must activate the saved choice")

defaults.set("foreground", forKey: NodeHostingMode.preferenceKey)
require(NodeHostingMode.resolve(defaults: defaults) == .foreground, "foreground selection must survive persistence")
defaults.set("unknown", forKey: NodeHostingMode.preferenceKey)
require(NodeHostingMode.resolve(defaults: defaults) == .networkExtension, "invalid preferences must recover safely")
print("Host contracts passed")
