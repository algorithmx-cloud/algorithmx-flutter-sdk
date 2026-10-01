//
//  SdkLog.swift
//  AlgorithmXSDK
//
//  Single logging switch. Mirrors Android `SdkLog`: debug output only when
//  enabled with `AlgorithmX.shared.setLoggingEnabled(_:)`, errors always.
//  Never log request bodies or notification payloads.
//

import Foundation

enum SdkLog {
    static var enabled = false

    static func debug(_ message: @autoclosure () -> String) {
        if enabled { print("[AlgorithmX] \(message())") }
    }

    static func error(_ message: @autoclosure () -> String) {
        print("[AlgorithmX] ❌ \(message())")
    }
}
