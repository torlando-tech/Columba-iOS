// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  CallState.swift
//  LXSTSwift
//
//  Call state machine matching Python LXST Telephony.py call flow.
//

import Foundation

/// State of a telephony call.
public enum CallState: Sendable, Equatable {
    /// Idle, no call in progress.
    case idle
    /// Outgoing call initiated, waiting for callee to respond.
    case calling
    /// Incoming link received, sent AVAILABLE.
    case available
    /// Callee identified, sent/received RINGING.
    case ringing
    /// Connecting audio pipelines.
    case connecting
    /// Call established, audio flowing.
    case established
    /// Call ended (with reason).
    case ended(CallEndReason)
}

/// Reason a call ended.
public enum CallEndReason: Sendable, Equatable {
    /// Normal hangup by local user.
    case localHangup
    /// Remote peer hung up.
    case remoteHangup
    /// Remote peer rejected the call.
    case rejected
    /// Remote peer is busy.
    case busy
    /// Ring timeout expired (60s).
    case ringTimeout
    /// Connect timeout expired.
    case connectTimeout
    /// Link closed unexpectedly.
    case linkClosed
}
