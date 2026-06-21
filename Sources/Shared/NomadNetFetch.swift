//
//  NomadNetFetch.swift
//  Columba-iOS
//
//  One-shot NomadNet page fetch over a fresh RNS Link, shared by BOTH the
//  foreground Swift backend (Model A — `SwiftRNSBackend`) and the Network
//  Extension node (Model B — `NEReticulumNode`, reached via the
//  `ProxyRequest.nomadnetFetch` IPC). Extracted verbatim from
//  `SwiftRNSBackend.fetchNomadNetPage` so the NE can serve page fetches without
//  duplicating the link/fetch logic.
//
//  Depends ONLY on Foundation + ReticulumSwift (no RNSAPI), so it compiles into
//  the extension target too. `Status`'s raw values mirror
//  `RNSAPI.NomadNetFetchResult.Status` so callers map across by rawValue.
//

import Foundation
import ReticulumSwift

/// One-shot NomadNet page fetch over a fresh RNS Link.
public enum NomadNetFetch {
    /// Outcome status. Raw values mirror `RNSAPI.NomadNetFetchResult.Status`.
    public enum Status: String, Sendable {
        case ok
        case noPath = "no-path"
        case linkFailed = "link-failed"
        case requestFailed = "request-failed"
        case timeout
        case badHash = "bad-hash"
        case notStarted = "not-started"
        case unknown
    }

    /// Result of a fetch: success flag, status, raw page bytes, content type.
    public struct Result: Sendable, Equatable {
        public let ok: Bool
        public let status: Status
        public let data: Data
        public let contentType: String
        public init(ok: Bool, status: Status, data: Data, contentType: String) {
            self.ok = ok
            self.status = status
            self.data = data
            self.contentType = contentType
        }
    }

    /// Resolve a path + node identity, open a link to the `nomadnetwork.node`
    /// destination, wait for it to become established, issue an RNS request for
    /// the page `path`, and await the response (racing each wait against a
    /// timeout). The link is one-shot — torn down on return. `formFields` arrive
    /// already "field_"-prefixed by the caller.
    ///
    /// Callers own the not-started / bad-hash guards: this takes a non-nil
    /// `transport`/`identity`/`pathTable` and an already-decoded `destHash`.
    public static func fetch(
        transport: ReticulumSwift.ReticulumTransport,
        identity: ReticulumSwift.Identity,
        pathTable: ReticulumSwift.PathTable,
        destHash: Data,
        path: String,
        timeout: TimeInterval,
        formFields: [String: String]?
    ) async throws -> Result {
        func fail(_ s: Status) -> Result {
            Result(ok: false, status: s, data: Data(), contentType: "")
        }

        // 1. Ensure a path, then recall the node identity from its announce.
        if await transport.hasPath(for: destHash) == false {
            await transport.requestPath(for: destHash)
            if await transport.awaitPath(for: destHash, timeout: 15.0) == false { return fail(.noPath) }
        }
        guard let entry = await pathTable.lookup(destinationHash: destHash),
              entry.publicKeys.count == 64,
              let nodeIdentity = try? ReticulumSwift.Identity(publicKeyBytes: entry.publicKeys) else {
            return fail(.noPath)
        }

        // 2. Establish a fresh link to the nomadnetwork.node destination.
        let dest = ReticulumSwift.Destination(
            identity: nodeIdentity, appName: "nomadnetwork", aspects: ["node"],
            type: .single, direction: .out
        )
        let link: ReticulumSwift.Link
        do {
            link = try await transport.initiateLink(to: dest, identity: identity)
        } catch {
            return fail(.linkFailed)
        }
        defer { let l = link; Task { await l.close(reason: .initiatorClosed) } }
        guard await awaitLinkEstablished(link, timeout: timeout) else { return fail(.linkFailed) }

        // 3. Build the request payload (form fields → msgpack map) and send it.
        let requestData: ReticulumSwift.MessagePackValue?
        if let formFields, !formFields.isEmpty {
            var map: [ReticulumSwift.MessagePackValue: ReticulumSwift.MessagePackValue] = [:]
            for (k, v) in formFields { map[.string(k)] = .string(v) }
            requestData = .map(map)
        } else {
            requestData = nil
        }
        let receipt = try await link.request(path: path, data: requestData, timeout: timeout)

        // 4. Await the response, racing the status stream against a timeout.
        let (data, status) = await awaitResponse(receipt, timeout: timeout + 2.0)
        guard status == .ok, let data else { return fail(status) }
        return Result(ok: true, status: .ok, data: data, contentType: "")
    }

    /// Wait for a link to reach an established state, racing against a timeout.
    private static func awaitLinkEstablished(_ link: ReticulumSwift.Link, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await st in await link.stateUpdates {
                    if st.isEstablished { return true }
                    if case .closed = st { return false }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                return false
            }
            let ok = await group.next() ?? false
            group.cancelAll()
            return ok
        }
    }

    /// Await an RNS request response, racing the status stream against a timeout.
    private static func awaitResponse(_ receipt: ReticulumSwift.RequestReceipt, timeout: TimeInterval) async -> (Data?, Status) {
        await withTaskGroup(of: (Data?, Status).self) { group in
            group.addTask {
                for await status in await receipt.statusUpdates {
                    switch status {
                    case .responseReceived:
                        let raw = await receipt.responseData
                        return (raw.map { unwrapResponseData($0) }, .ok)
                    case .failed: return (nil, .requestFailed)
                    case .timeout: return (nil, .timeout)
                    default: continue
                    }
                }
                return (nil, .requestFailed)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                return (nil, .timeout)
            }
            let result = await group.next() ?? (nil, .unknown)
            group.cancelAll()
            return result
        }
    }

    /// NomadNet responses come back msgpack-wrapped (binary or string); unwrap to
    /// the raw page bytes, falling back to the raw payload if it isn't msgpack.
    private static func unwrapResponseData(_ data: Data) -> Data {
        if let value = try? ReticulumSwift.unpackMsgPack(data) {
            switch value {
            case .binary(let bytes): return bytes
            case .string(let str): return str.data(using: .utf8) ?? data
            default: break
            }
        }
        return data
    }
}
