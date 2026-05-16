// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  Packetizer.swift
//  LXSTSwift
//
//  Stub packetizer matching Python LXST Network.py Packetizer class.
//  Sends encoded audio frames as link DATA packets.
//

import Foundation

/// Packetizer sends encoded audio frames over a Reticulum link.
///
/// Python `Packetizer` (Network.py:49) wraps audio frames with codec headers
/// and sends them as `RNS.Packet(link, msgpack({FIELD_FRAMES: header+frame}))`.
public actor Packetizer {

    /// The link to send frames on.
    private weak var link: Link?

    /// Send callback for transmitting packet data.
    private var sendCallback: (@Sendable (Data) async throws -> Void)?

    /// Whether the packetizer is active.
    public private(set) var isRunning: Bool = false

    /// Create a packetizer for a link.
    ///
    /// - Parameter link: The link to send audio over
    public init(link: Link) {
        self.link = link
    }

    /// Set the send callback for packet transmission.
    public func setSendCallback(_ callback: @escaping @Sendable (Data) async throws -> Void) {
        self.sendCallback = callback
    }

    /// Start the packetizer.
    public func start() {
        isRunning = true
    }

    /// Stop the packetizer.
    public func stop() {
        isRunning = false
    }

    /// Send an encoded audio frame.
    ///
    /// Wraps the frame with codec header and sends as msgpack DATA packet.
    /// Python: `frame = codec_header_byte(type(self.source.codec)) + frame`
    ///         `packet_data = {FIELD_FRAMES: frame}`
    ///
    /// - Parameters:
    ///   - codecType: The codec type for the header byte
    ///   - encodedAudio: The encoded audio data
    public func sendFrame(codecType: LXSTCodecType, encodedAudio: Data) async throws {
        guard isRunning else { return }
        guard let link = link else { return }

        let packetData = LXSTWireFormat.packFrame(codecType: codecType, encodedAudio: encodedAudio)

        // Encrypt and send as link DATA packet
        let encrypted = try await link.encrypt(packetData)
        if let send = sendCallback {
            try await send(encrypted)
        }
    }
}
