//
//  PeerChildInterfaceRegistry.swift
//  ColumbaApp
//
//  Synchronous, lock-protected set of interface ids known to be
//  peer-children of an AutoInterface / BLEInterface / MPCInterface
//  parent. Used by AppServices to attribute the `onInterfaceConnected`
//  event for peer-children to the peer-spawned auto-announce trigger,
//  not the tcp-reconnect trigger.
//
//  Why a lock and not an actor: the peer-spawned and connected callbacks
//  fire from independent reticulum-swift Tasks. If the registry were
//  actor-isolated, both record-and-lookup would require an `await` hop,
//  and Swift's task scheduler does not guarantee record-before-lookup
//  ordering between unrelated Tasks. By making the operations
//  synchronous, the peer-spawned closure can commit its record on its
//  first line — before any `await` — and the connected closure's lookup
//  sees the committed value regardless of how the schedulers interleave
//  the rest of the closure bodies.
//

import Foundation
import os.lock

/// Thread-safe registry of peer-child interface ids.
///
/// Backed by `os_unfair_lock` (the most lightweight option for a tiny
/// critical section). Access is non-isolated so the registry can be
/// touched from any thread / actor / Task without an additional hop.
public final class PeerChildInterfaceRegistry: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    public init() {}

    /// Mark `id` as a peer-child interface.
    public func record(_ id: String) {
        lock.withLock { ids in
            ids.insert(id)
        }
    }

    /// Whether `id` was previously recorded as a peer-child.
    public func contains(_ id: String) -> Bool {
        lock.withLock { ids in
            ids.contains(id)
        }
    }

    /// Test-only: clear all recorded ids.
    internal func reset() {
        lock.withLock { ids in
            ids.removeAll()
        }
    }
}
