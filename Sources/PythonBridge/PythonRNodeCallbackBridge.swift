//
//  PythonRNodeCallbackBridge.swift
//  Columba (ColumbaApp target — wired in the pbxproj alongside PythonBridge)
//
//  Glue between SwiftRNodeBridge's `RNodeCallbackInvoker` protocol and
//  PythonBridge's `invokeRNodeCallback`. Conforming class lives in the pbxproj
//  target (NOT the SwiftBLEBridge SwiftPM target) because invocation routes
//  through PythonBridge, which depends on Python.h. Mirror of
//  PythonBLECallbackBridge.
//

import Foundation
import SwiftBLEBridge

/// Bridges SwiftRNodeBridge's RNode event slots to PythonBridge's GIL-aware
/// invocation. Pass an instance to `SwiftRNodeBridge.setCallbackInvoker(_:)`
/// once the Python runtime is up.
public final class PythonRNodeCallbackBridge: RNodeCallbackInvoker, @unchecked Sendable {

    private let pythonBridge: PythonBridge

    public init(pythonBridge: PythonBridge) {
        self.pythonBridge = pythonBridge
    }

    public func invoke(slot: RNodeCallbackSlot, args: [Any]) {
        pythonBridge.invokeRNodeCallback(slot: slot.rawValue, args: convert(args))
    }

    // MARK: - Arg conversion

    /// The two RNode slots pass a small, fixed set of types:
    ///   "data"  → (Data)
    ///   "state" → (Bool, String)
    /// Bool is matched before Int (a Bool never matches `as Int` in Swift, but
    /// keeping it first documents intent). Unknown types fall through as a
    /// labelled string so misuse is loud rather than silently dropped.
    private func convert(_ args: [Any]) -> [BLEArg] {
        args.map { value in
            switch value {
            case let s as String:
                return .string(s)
            case let b as Bool:
                return .bool(b)
            case let d as Data:
                return .bytes(d)
            case let i as Int:
                return .int(i)
            case is NSNull:
                return .none
            default:
                return .string("<unsupported:\(type(of: value))>")
            }
        }
    }
}
