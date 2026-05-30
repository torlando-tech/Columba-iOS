//
//  PythonBLECallbackBridge.swift
//  Columba (ColumbaApp target — auto-picked up by configure-xcodeproj.rb)
//
//  Glue between SwiftBLEBridge's `BleCallbackInvoker` protocol and PythonBridge's
//  `invokeBLECallback` / `invokeBLECallbackBoolSync`. Conforming class lives in
//  the pbxproj target (NOT the SwiftBLEBridge SwiftPM target) because invocation
//  routes through PythonBridge which depends on Python.h.
//

import Foundation
import SwiftBLEBridge

/// Bridges SwiftBLEBridge's BLE event slots to PythonBridge's GIL-aware
/// invocation primitives. Pass an instance of this to
/// `SwiftBLEBridge.setCallbackInvoker(_:)` after the Python runtime is up.
public final class PythonBLECallbackBridge: BleCallbackInvoker, @unchecked Sendable {

    private let pythonBridge: PythonBridge

    public init(pythonBridge: PythonBridge) {
        self.pythonBridge = pythonBridge
    }

    public func invoke(slot: BleCallbackSlot, args: [Any]) {
        pythonBridge.invokeBLECallback(slot: slot.rawValue, args: convert(args))
    }

    public func invokeBool(slot: BleCallbackSlot, args: [Any]) -> Bool {
        pythonBridge.invokeBLECallbackBoolSync(
            slot: slot.rawValue,
            args: convert(args)
        )
    }

    // MARK: - Arg conversion

    /// Bridge boundary: the Swift CB delegates can pass any-typed args; we
    /// match each one to a known BLEArg variant. Unknown types fall through
    /// as `.string("<unsupported>")` which is logged on the Python side via
    /// PyErr_Print — the goal is to catch type misuse loudly in dev rather
    /// than silently dropping the call.
    private func convert(_ args: [Any]) -> [BLEArg] {
        args.map { value in
            switch value {
            case let s as String:
                return .string(s)
            case let i as Int:
                return .int(i)
            case let i as Int32:
                return .int(Int(i))
            case let i as Int64:
                return .int(Int(i))
            case let u as UInt:
                return .int(Int(u))
            case let b as Bool:
                return .bool(b)
            case let d as Data:
                return .bytes(d)
            case let arr as [String]:
                return .stringList(arr)
            case is NSNull:
                return .none
            default:
                return .string("<unsupported:\(type(of: value))>")
            }
        }
    }
}
