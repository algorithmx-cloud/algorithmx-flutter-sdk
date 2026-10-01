//
//  NotificationActionRouter.swift
//  AlgorithmXSDK
//
//  Mirrors the Android `NotificationActionRouter`. Single place that interprets
//  `action_type` and routes to the right SDK / partner action.
//

import Foundation
import UIKit

enum NotificationActionRouter {

    /// `trackOpen: false` when the tap was already tracked (an action button whose
    /// handler didn't handle it falls back to this default routing).
    static func route(data: [String: Any], trackOpen: Bool = true) {
        // 1. Track open + click.
        if trackOpen { trackOpened(data: data) }

        // 2. Partner first.
        if AlgorithmX.shared.notificationClickListener?.onNotificationClick(data: data) == true {
            return
        }

        // 3. Default action handling.
        let actionData = parseActionData(data["actionData"] as? String)
        let actionType = data["action_type"] as? String
        var performed = false
        switch actionType {
        case "open_web_page":
            performed = openExternalUrl(actionData["url"] as? String)
        case "open_webview":
            performed = openCampaignWebView(data: data, actionData: actionData)
        case "open_screen":
            if let deepLinkString = actionData["deepLink"] as? String,
               let url = URL(string: deepLinkString) {
                _ = AlgorithmX.shared.openDeepLink(url: url)
                performed = true
            }
        case "custom_action":
            let customAction = actionData["action"] as? String
            var enriched = data
            enriched["parsedActionData"] = actionData
            _ = AlgorithmX.shared.notificationClickListener?.onCustomAction?(action: customAction, data: enriched)
            performed = true
        default:
            break
        }
        // Tell the partner the SDK ran a default action for this tap (same as Android).
        if performed, let actionType = actionType {
            AlgorithmX.shared.notificationClickListener?.onActionHandled?(action: actionType, data: data)
        }
    }

    private static func trackOpened(data: [String: Any]) {
        if let notifIdStr = data["algo_notification_id"] as? String,
           let notifId = Int(notifIdStr) {
            AlgorithmX.shared.updateNotificationStatus(notificationId: notifId, status: .opened)
        }
        if let campaignId = data["algo_campaign_id"] as? String {
            let variationId = data["engage_variation_id"] as? String ?? "default"
            AlgorithmX.shared.trackCampaignInteraction(
                campaignId: campaignId,
                variationId: variationId,
                interactionType: "click",
                payload: [
                    "notification_type": "push",
                    "action": data["action_type"] ?? "unknown"
                ]
            )
        }
    }

    private static func parseActionData(_ raw: String?) -> [String: Any] {
        guard let raw = raw, !raw.isEmpty, raw != "{}",
              let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    private static func openExternalUrl(_ urlString: String?) -> Bool {
        guard let urlString = urlString, !urlString.isEmpty, let url = URL(string: urlString) else { return false }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        return true
    }

    private static func openCampaignWebView(data: [String: Any], actionData: [String: Any]) -> Bool {
        guard let url = actionData["url"] as? String,
              let campaignId = data["algo_campaign_id"] as? String else { return false }
        let variationId = data["engage_variation_id"] as? String ?? "default"
        AlgorithmX.shared.showWebView(
            campaignId: campaignId, variationId: variationId,
            url: url, dynamicContent: nil
        )
        return true
    }
}
