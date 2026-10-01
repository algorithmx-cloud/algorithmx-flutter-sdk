//
//  WebViewDisplayRule.swift
//  AlgorithmXSDK
//
//  Display configuration for a webview campaign variation. Mirrors the Android
//  struct field-for-field including default values.
//

import Foundation

struct WebViewDisplayRule: Codable {
    var priority: Int = 0
    var maxShowTime: Int = 1
    var intervalMinutes: Int = 0
    var showAgainAfterDays: Int = 0
    var expiresAt: Int64 = 0

    init(
        priority: Int = 0,
        maxShowTime: Int = 1,
        intervalMinutes: Int = 0,
        showAgainAfterDays: Int = 0,
        expiresAt: Int64 = 0
    ) {
        self.priority = priority
        self.maxShowTime = maxShowTime
        self.intervalMinutes = intervalMinutes
        self.showAgainAfterDays = showAgainAfterDays
        self.expiresAt = expiresAt
    }

    static func fromDict(_ dict: [String: Any]) -> WebViewDisplayRule {
        WebViewDisplayRule(
            priority: dict["priority"] as? Int ?? 0,
            maxShowTime: dict["maxShowTime"] as? Int ?? 1,
            intervalMinutes: dict["intervalMinutes"] as? Int ?? 0,
            showAgainAfterDays: dict["showAgainAfterDays"] as? Int ?? 0,
            expiresAt: (dict["expiresAt"] as? Int64) ?? Int64(dict["expiresAt"] as? Int ?? 0)
        )
    }

    static func fromJson(_ jsonString: String?) -> WebViewDisplayRule {
        guard let jsonString = jsonString,
              let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return WebViewDisplayRule() }
        return fromDict(dict)
    }

    func toJson() -> String? {
        let dict: [String: Any] = [
            "priority": priority,
            "maxShowTime": maxShowTime,
            "intervalMinutes": intervalMinutes,
            "showAgainAfterDays": showAgainAfterDays,
            "expiresAt": expiresAt
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    func isExpired() -> Bool {
        guard expiresAt > 0 else { return false }
        return Date().timeIntervalSince1970 * 1000 > Double(expiresAt)
    }

    func getIntervalMs() -> Int64 { Int64(intervalMinutes) * 60 * 1000 }
}
