//
//  GRDBVocabulary.swift
//  ColumbaApp
//
//  The shared persistence vocabulary for the `messages.state` and
//  `messages.method` columns.
//
//  ── ANDROID-PARITY STORE (frozen DB bytes) ────────────────────────────────
//  These byte values are FROZEN: they are the canonical serialization of the
//  message state and delivery method in the shared GRDB store, and they are
//  shared across processes. The app writes them; the Network Extension's
//  embedded Python node writes the same bytes directly into the same table
//  (rns_bridge.py: `_GRDB_STATE_DELIVERED = 0x08`, and
//  `_inbound_delivery_method_name` maps to the same opportunistic/direct/
//  propagated/paper vocabulary). The values are lifted verbatim from the
//  LXMFSwift package's `LXMessageState` / `LXDeliveryMethod` (which documents
//  them against the Python LXMF implementation) and re-scoped to the app so
//  the store does not depend on the wire library.
//
//  The app-facing RNSAPI enums (`RNSAPI.LXMessageState`, `RNSAPI.LXDeliveryMethod`)
//  are the *semantic* model the UI speaks; `MessageRepository.mapState*` /
//  `mapMethod*` bridge between them and these raw bytes.
//

import Foundation

/// Message state byte values persisted in `messages.state`.
///
/// Reference: LXMF `LXMessage.py` lines 14-22 (mirrored by LXMFSwift).
public enum GRDBState: UInt8 {
    /// Message is being constructed (not yet ready to send). Python: GENERATING
    case generating = 0x00
    /// Message is ready to send (queued for outbound). Python: OUTBOUND
    case outbound = 0x01
    /// Message is actively being transmitted. Python: SENDING
    case sending = 0x02
    /// Message successfully sent to transport. Python: SENT
    case sent = 0x04
    /// Message delivered to destination (delivery receipt received). Python: DELIVERED
    case delivered = 0x08
    /// Message rejected by recipient (unused in client mode). Python: REJECTED
    case rejected = 0xFD
    /// Message cancelled by sender before delivery. Python: CANCELLED
    case cancelled = 0xFE
    /// Message delivery failed after all retry attempts. Python: FAILED
    case failed = 0xFF
}

/// Delivery method byte values persisted in `messages.method`.
///
/// Reference: LXMF `LXMessage.py` lines 29-33 (mirrored by LXMFSwift). The
/// app also persists a sentinel `0` for the RNSAPI `.unknown` method, which has
/// no value in this vocabulary (see `MessageRepository.mapMethodToGRDB`); raw
/// reads map `0` back to `.unknown`.
public enum GRDBDeliveryMethod: UInt8 {
    /// Opportunistic delivery (single packet, no link required). Python: OPPORTUNISTIC
    case opportunistic = 0x01
    /// Direct delivery over established link. Python: DIRECT
    case direct = 0x02
    /// Propagated delivery via propagation nodes. Python: PROPAGATED
    case propagated = 0x03
    /// Paper message (QR code or physical medium). Python: PAPER
    case paper = 0x05
}
