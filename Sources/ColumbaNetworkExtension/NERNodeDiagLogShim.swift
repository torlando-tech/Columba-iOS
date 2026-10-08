//
//  NERNodeDiagLogShim.swift
//  ColumbaNetworkExtension
//
//  Minimal `DiagLog` shim so the RNode CoreBluetooth radio (the shared
//  `PythonRNodeBLEBridge.swift`) compiles in the NE target. In the app target
//  the real `DiagLog` (defined in `AppServices.swift`) is used instead; the two
//  targets each compile their own copy, so there is no symbol collision. The
//  NE copy forwards to `ExtensionDiagLog` (the NE's PII-free `ext-diag.log`
//  channel).
//

import Foundation

enum DiagLog {
    static func log(_ message: String) {
        ExtensionDiagLog.log(message)
    }
}
