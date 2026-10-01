//
//  NotificationClickListener.swift
//  AlgorithmXSDK
//
//  Protocol for handling notification click actions. Matches the Android
//  interface shape — method names are aligned across platforms.
//

import Foundation

@objc public protocol NotificationClickListener: AnyObject {

    /// Return true if you handled the click; false to let the SDK fall through
    /// to its default action router (open_web_page, open_webview, open_screen).
    func onNotificationClick(data: [String: Any]) -> Bool

    /// Called for `action_type: "custom_action"`. The `action` parameter is the
    /// value of `actionData.action` parsed by the SDK.
    @objc optional func onCustomAction(action: String?, data: [String: Any]) -> Bool

    /// Called after the SDK handles a standard action — useful for analytics.
    @objc optional func onActionHandled(action: String, data: [String: Any])
}
