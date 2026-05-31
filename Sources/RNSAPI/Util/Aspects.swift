import Foundation

/// Announce aspect strings Columba tracks.
///
/// Reticulum destinations identify themselves by an aspect (e.g.
/// `"lxmf.delivery"`) — the same string is the source of truth for routing,
/// destination construction, `Transport.registerKnownAspect` calls, and the
/// announce-handler aspect filter. Previously each backend + the shared
/// `AppDataParser` / `NodeType.fromAspect` listed the literals
/// independently; this enum centralises them so the protocol-leaf strings
/// cannot drift.
///
/// Python-side, `event_bridge.py._KNOWN_ASPECTS` is a parallel tuple of the
/// same strings — kept in sync by hand because the embedded Python can't
/// read Swift constants. The strings here are the canonical reference.
///
/// Mirrors `Aspects.kt` in Columba Android's `rns-api`.
public enum Aspects {
    /// Peer-to-peer LXMF messaging destination (`<identity>.lxmf.delivery`).
    public static let lxmfDelivery = "lxmf.delivery"

    /// LXMF propagation / store-and-forward node.
    public static let lxmfPropagation = "lxmf.propagation"

    /// NomadNet content node (Sites, pages, files).
    public static let nomadnetNode = "nomadnetwork.node"

    /// LXST telephony / voice call destination.
    public static let lxstTelephony = "lxst.telephony"

    /// Every aspect Columba tracks — handy for set-membership tests.
    public static let all: Set<String> = [
        lxmfDelivery,
        lxmfPropagation,
        nomadnetNode,
        lxstTelephony,
    ]
}
