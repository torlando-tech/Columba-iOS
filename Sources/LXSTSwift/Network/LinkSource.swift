// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  LinkSource.swift
//  LXSTSwift
//
//  Stub link source matching Python LXST Network.py LinkSource class.
//  Receives decoded audio frames from the remote peer via link packets.
//

import Foundation
import os.log

private let lsLogger = Logger(subsystem: "com.lxst.swift", category: "LinkSource")

/// LinkSource receives audio frames from a remote peer over a Reticulum link.
///
/// Python `LinkSource` (Network.py:98) sets `link.set_packet_callback(_packet)`
/// to receive incoming packets, unpacks msgpack, detects codec from header byte,
/// and delivers decoded frames to a sink.
public actor LinkSource {

    /// Current codec type detected from incoming frames.
    public private(set) var currentCodecType: LXSTCodecType = .null

    /// Whether the source is active.
    public private(set) var isRunning: Bool = false

    /// Callback for received decoded frames (Phase 4: will deliver to Mixer/Sink).
    private var frameCallback: (@Sendable (LXSTCodecType, Data) async -> Void)?

    /// Signal callback for forwarding signals to the Telephone.
    private var signalCallback: (@Sendable ([UInt]) async -> Void)?

    public init() {}

    /// Set callback for received audio frames.
    public func setFrameCallback(_ callback: @escaping @Sendable (LXSTCodecType, Data) async -> Void) {
        self.frameCallback = callback
    }

    /// Set callback for received signals.
    public func setSignalCallback(_ callback: @escaping @Sendable ([UInt]) async -> Void) {
        self.signalCallback = callback
    }

    /// Start receiving.
    public func start() {
        isRunning = true
    }

    /// Stop receiving.
    public func stop() {
        isRunning = false
    }

    /// Handle an incoming packet (set as link packet callback).
    ///
    /// Python `_packet()` (Network.py:109): Unpacks msgpack, routes frames
    /// and signals. Detects codec changes from header byte.
    ///
    /// Parses the msgpack map directly to support both single-frame and
    /// Android batch formats `{0x01: [f1, f2, f3]}` where each element
    /// is bytes(codec_type + opus_data).
    ///
    /// - Parameters:
    ///   - data: Decrypted packet data
    ///   - packet: The original packet
    public func handlePacket(data: Data, packet: Packet) async {
        guard isRunning else { return }

        guard let value = try? unpackMsgPack(data),
              case .map(let dict) = value else { return }

        // Handle signals (dual-key lookup: Python/Android encode small int keys as fixint → .int)
        let sigValue = dict[MessagePackValue.uint(UInt64(LXSTField.signalling))]
            ?? dict[MessagePackValue.int(Int64(LXSTField.signalling))]
        if let sigValue = sigValue {
            var signals: [UInt] = []
            switch sigValue {
            case .array(let arr):
                signals = arr.compactMap { elem -> UInt? in
                    if case .uint(let v) = elem { return UInt(v) }
                    if case .int(let v) = elem, v >= 0 { return UInt(v) }
                    return nil
                }
            case .uint(let v): signals = [UInt(v)]
            case .int(let v) where v >= 0: signals = [UInt(v)]
            default: break
            }
            if !signals.isEmpty {
                await signalCallback?(signals)
            }
        }

        // Handle frames — single binary or batch array of complete frame bytes.
        let frameValue = dict[MessagePackValue.uint(UInt64(LXSTField.frames))]
            ?? dict[MessagePackValue.int(Int64(LXSTField.frames))]
        guard let frameValue = frameValue else { return }

        switch frameValue {
        case .binary(let d) where d.count >= 2:
            // Single frame: bytes(codec_type + opus_data)
            await deliverFrame(codecHeader: d[d.startIndex], audioData: Data(d[(d.startIndex + 1)...]))

        case .array(let arr):
            // Batch: [frame1_bytes, frame2_bytes, ...]
            // Each element is bytes(codec_type + opus_data). Deliver all frames.
            for elem in arr {
                guard case .binary(let d) = elem, d.count >= 2 else { continue }
                await deliverFrame(codecHeader: d[d.startIndex], audioData: Data(d[(d.startIndex + 1)...]))
            }

        default:
            break
        }
    }

    private var deliverCount = 0

    private func deliverFrame(codecHeader: UInt8, audioData: Data) async {
        deliverCount += 1
        if deliverCount <= 5 || deliverCount % 50 == 0 {
            let first4 = audioData.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
            lsLogger.debug("[LINKSOURCE] frame #\(self.deliverCount, privacy: .public): hdr=0x\(String(format: "%02x", codecHeader), privacy: .public) audioBytes=\(audioData.count, privacy: .public) first4=[\(first4, privacy: .public)]")
        }
        guard let codecType = LXSTCodecType(rawValue: codecHeader) else {
            lsLogger.error("[LINKSOURCE] UNKNOWN codec header: 0x\(String(format: "%02x", codecHeader), privacy: .public) — dropping frame")
            return
        }
        if codecType != currentCodecType {
            currentCodecType = codecType
        }
        await frameCallback?(codecType, audioData)
    }
}
