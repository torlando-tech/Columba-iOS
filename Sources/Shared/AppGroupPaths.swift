//
//  AppGroupPaths.swift
//  Columba Shared
//
//  Single source of truth for the App-Group-shared on-disk paths the app and the
//  Network Extension MUST agree on (Model B). Before this file existed, the two
//  processes each computed the canonical LXMF store path independently — the app
//  in `AppServices.grdbDatabaseFilePath(for:)`, the NE in
//  `NEReticulumNode.appGroupLXMFDatabasePath(identityHashHex:)` — and any drift in
//  the layout meant they opened DIFFERENT GRDB files and never converged. This
//  enum is the one place that layout is defined; BOTH sides delegate here so they
//  CANNOT drift.
//
//  Layout (rooted at the App-Group container so both processes reach the same
//  files — the app's Application Support container is process-local and the NE
//  cannot see it):
//
//    <App-Group container>/Columba/python-<identityHashHex>/lxmf-swift.db   (+ -wal / -shm)
//    <App-Group container>/Columba/python-<identityHashHex>/ratchets
//
//  `identityHashHex` is the RAW identity hash (`identity.hexHash`) — NOT the
//  lxmf.delivery destination hash — exactly as `AppServices` keyed it before, so
//  the per-identity subdirectory resolves to the identical file on both sides.
//
//  This file imports ONLY Foundation and is compiled into BOTH the ColumbaApp and
//  ColumbaNetworkExtension targets (like `SharedFrameQueue` / `ExtensionDiagLog`).
//  It MUST stay free of ReticulumSwift / LXMFSwift / RNSAPI so it compiles in the
//  NE target (which links none of those) and so the app's `AppServices` can use it
//  WITHOUT gaining an `import LXMFSwift` (the A0 collision rule).
//

import Foundation

/// App-Group-shared path helper — the single source of truth for the canonical
/// LXMF store and ratchet-storage locations both the app and the Network Extension
/// open. See the file header for the exact layout and why it's centralized.
///
/// Foundation-only by contract (no Reticulum/LXMF/RNSAPI imports) so it is safe in
/// both targets.
public enum AppGroupPaths {

    /// Subdirectory under the App-Group container holding all Columba state.
    private static let columbaDirectoryName = "Columba"

    /// LXMF GRDB store filename — matches the name the app previously used at the
    /// process-local path and the name the NE hardcodes, so the two converge.
    private static let lxmfDatabaseFileName = "lxmf-swift.db"

    /// Ratchet-storage filename (LXMF/Reticulum writes the ratchet state here),
    /// co-located with the GRDB store under the per-identity directory.
    private static let ratchetStorageFileName = "ratchets"

    // MARK: - Public API

    /// The App-Group container root, or `nil` when the container is unavailable
    /// (e.g. an unsigned / simulator build with no App-Group entitlement). All the
    /// other helpers return `nil` in that case rather than silently falling back to
    /// a process-local path — a process-local path is exactly the drift this enum
    /// exists to prevent. Callers decide how to handle the `nil` (the NE logs and
    /// uses tmp; the app keeps its existing process-local path).
    public static func containerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    /// URL of the App-Group-shared canonical `lxmf-swift.db` for `identityHashHex`
    /// (the raw identity hash — NOT the lxmf.delivery destination hash). Creates the
    /// intermediate `Columba/python-<hash>/` directory as a side effect. Returns
    /// `nil` if the App-Group container is unavailable.
    ///
    /// - Parameter identityHashHex: Hex of the raw identity hash (`identity.hexHash`).
    public static func lxmfDatabaseURL(identityHashHex: String) -> URL? {
        guard let dir = perIdentityDirectoryURL(identityHashHex: identityHashHex) else {
            return nil
        }
        return dir.appendingPathComponent(lxmfDatabaseFileName)
    }

    /// URL of the App-Group-shared ratchet storage for `identityHashHex`, alongside
    /// the GRDB store so all per-identity state co-locates in the shared container.
    /// Creates the intermediate directory as a side effect. Returns `nil` if the
    /// App-Group container is unavailable.
    ///
    /// - Parameter identityHashHex: Hex of the raw identity hash (`identity.hexHash`).
    public static func ratchetStorageURL(identityHashHex: String) -> URL? {
        guard let dir = perIdentityDirectoryURL(identityHashHex: identityHashHex) else {
            return nil
        }
        return dir.appendingPathComponent(ratchetStorageFileName)
    }

    /// Resolve (creating if needed) the per-identity directory
    /// `<App-Group container>/Columba/python-<identityHashHex>/`. Returns `nil` when
    /// the App-Group container is unavailable. The directory-create is best-effort
    /// (a failure here surfaces later when the store/ratchet open fails, with a
    /// clearer error than an opaque path string would give).
    ///
    /// - Parameter identityHashHex: Hex of the raw identity hash (`identity.hexHash`).
    public static func perIdentityDirectoryURL(identityHashHex: String) -> URL? {
        guard let container = containerURL() else { return nil }
        let dir = container
            .appendingPathComponent(columbaDirectoryName, isDirectory: true)
            .appendingPathComponent("python-\(identityHashHex)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
