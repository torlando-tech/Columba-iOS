// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  LXSTErrors.swift
//  LXSTSwift
//
//  Error types for LXST protocol operations.
//

import Foundation

public enum LXSTError: Error, Sendable {
    case invalidWireFormat(String)
    case codecError(String)
    case callError(String)
    case notConnected
    case alreadyInCall
    case linkNotActive
    case identityRequired
    case callRejected
    case callBusy
    case ringTimeout
    case connectTimeout
}
