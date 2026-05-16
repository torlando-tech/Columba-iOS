// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  LXSTWireFormat.swift
//  LXSTSwift
//
//  Wire format pack/unpack matching Python LXST Network.py.
//  Signals: msgpack({0x00: [signal_int]})
//  Frames:  msgpack({0x01: codec_header + encoded_audio})
//  Preferred profile: msgpack({0x00: [0xFF + profile_byte]}) — single integer
//

import Foundation

// MARK: - Wire Format

public enum LXSTWireFormat {

    // MARK: - Signal Packing

    /// Pack a signal code for transmission.
    ///
    /// Python: `{FIELD_SIGNALLING: [signal]}` → msgpack
    ///
    /// - Parameter signal: The signal code to send
    /// - Returns: Msgpack-encoded data ready for RNS.Packet
    public static func packSignal(_ signal: LXSTSignal) -> Data {
        // {0: [signal_byte]}
        let value: MessagePackValue = .map([
            .uint(UInt64(LXSTField.signalling)): .array([.uint(UInt64(signal.rawValue))])
        ])
        return packMsgPack(value)
    }

    /// Pack a raw signal integer for transmission.
    ///
    /// Used for profile signals where value >= 0xFF.
    /// Python: `self.signal(Signalling.PREFERRED_PROFILE + profile, link)`
    ///
    /// - Parameter rawSignal: The raw signal integer (may be > 255)
    /// - Returns: Msgpack-encoded data
    public static func packRawSignal(_ rawSignal: UInt) -> Data {
        let value: MessagePackValue = .map([
            .uint(UInt64(LXSTField.signalling)): .array([.uint(UInt64(rawSignal))])
        ])
        return packMsgPack(value)
    }

    /// Pack a preferred profile signal for transmission.
    ///
    /// Python: `self.signal(Signalling.PREFERRED_PROFILE + self.active_call.profile, link)`
    /// This sends a SINGLE integer (0xFF + profile_byte) in the signals array.
    ///
    /// - Parameter profile: The preferred telephony profile
    /// - Returns: Msgpack-encoded data
    public static func packPreferredProfile(_ profile: TelephonyProfile) -> Data {
        let combined = UInt(LXSTSignal.preferredProfile) + UInt(profile.rawValue)
        return packRawSignal(combined)
    }

    /// Pack an audio frame for transmission.
    ///
    /// Python: `{FIELD_FRAMES: codec_header_byte + encoded_frame}`
    ///
    /// - Parameters:
    ///   - codecType: Codec type header byte
    ///   - encodedAudio: Encoded audio data from codec
    /// - Returns: Msgpack-encoded data
    public static func packFrame(codecType: LXSTCodecType, encodedAudio: Data) -> Data {
        var frameData = Data([codecType.rawValue])
        frameData.append(encodedAudio)
        let value: MessagePackValue = .map([
            .uint(UInt64(LXSTField.frames)): .binary(frameData)
        ])
        return packMsgPack(value)
    }

    // MARK: - Unpacking

    /// Parsed LXST packet content.
    public enum ParsedPacket: Sendable {
        /// One or more signal values (may include profile signals >= 0xFF).
        case signals([UInt])
        /// Audio frame: codec header byte + encoded data.
        case frame(codecHeader: UInt8, audioData: Data)
        /// Both signals and a frame in the same packet.
        case mixed(signals: [UInt], codecHeader: UInt8, audioData: Data)
    }

    /// Unpack a received LXST packet.
    ///
    /// Python LinkSource._packet() unpacks msgpack and checks for both
    /// FIELD_SIGNALLING and FIELD_FRAMES in the same dict.
    ///
    /// - Parameter data: Raw msgpack data from link packet callback
    /// - Returns: Parsed packet content
    /// - Throws: LXSTError.invalidWireFormat if not a valid LXST packet
    public static func unpack(_ data: Data) throws -> ParsedPacket {
        guard let value = try? unpackMsgPack(data),
              case .map(let dict) = value else {
            throw LXSTError.invalidWireFormat("Expected msgpack map")
        }

        var signals: [UInt]?
        var frame: (UInt8, Data)?

        // Check for signalling field.
        // Android/Python encode small int keys as signed (positive fixint → .int),
        // so we must try both .uint and .int to handle cross-platform msgpack encoders.
        let sigValue = dict[MessagePackValue.uint(UInt64(LXSTField.signalling))]
            ?? dict[MessagePackValue.int(Int64(LXSTField.signalling))]
        if let sigValue = sigValue {
            switch sigValue {
            case .array(let arr):
                signals = arr.compactMap { elem -> UInt? in
                    if case .uint(let v) = elem { return UInt(v) }
                    if case .int(let v) = elem, v >= 0 { return UInt(v) }
                    return nil
                }
            case .uint(let v):
                signals = [UInt(v)]
            case .int(let v) where v >= 0:
                signals = [UInt(v)]
            default:
                break
            }
        }

        // Check for frames field (same uint/int dual-lookup for cross-platform compat).
        let frameValue = dict[MessagePackValue.uint(UInt64(LXSTField.frames))]
            ?? dict[MessagePackValue.int(Int64(LXSTField.frames))]
        if let frameValue = frameValue {
            let frameBytes: Data
            switch frameValue {
            case .binary(let d):
                frameBytes = d
            case .array(let arr):
                // Array format: either single-element [frame_bytes] or batch [f1, f2, ...]
                // Each element is bytes(codec_type + opus_data).
                // Use the first element for routing — LinkSource handles full batch delivery.
                if let first = arr.first, case .binary(let d) = first {
                    frameBytes = d
                } else {
                    frameBytes = Data()
                }
            default:
                frameBytes = Data()
            }

            if frameBytes.count >= 2 {
                let header = frameBytes[frameBytes.startIndex]
                let audio = Data(frameBytes[(frameBytes.startIndex + 1)...])
                frame = (header, audio)
            }
        }

        switch (signals, frame) {
        case (let s?, let (h, a)?):
            return .mixed(signals: s, codecHeader: h, audioData: a)
        case (let s?, nil):
            return .signals(s)
        case (nil, let (h, a)?):
            return .frame(codecHeader: h, audioData: a)
        default:
            throw LXSTError.invalidWireFormat("No signalling or frame field found")
        }
    }

    /// Extract a preferred profile from a signal value.
    ///
    /// Python: `signal >= Signalling.PREFERRED_PROFILE` → `profile = signal - PREFERRED_PROFILE`
    ///
    /// - Parameter signal: A signal value (potentially >= 0xFF)
    /// - Returns: The preferred profile if this is a profile signal, nil otherwise
    public static func extractPreferredProfile(from signal: UInt) -> TelephonyProfile? {
        guard signal >= UInt(LXSTSignal.preferredProfile) else { return nil }
        let profileByte = UInt8(signal - UInt(LXSTSignal.preferredProfile))
        return TelephonyProfile(rawValue: profileByte)
    }

    /// Extract a regular signal code from a signal value.
    ///
    /// - Parameter signal: A signal value
    /// - Returns: The LXSTSignal if this is a regular signal (< 0xFF), nil otherwise
    public static func extractSignal(from signal: UInt) -> LXSTSignal? {
        guard signal < UInt(LXSTSignal.preferredProfile) else { return nil }
        return LXSTSignal(rawValue: UInt8(signal))
    }
}
