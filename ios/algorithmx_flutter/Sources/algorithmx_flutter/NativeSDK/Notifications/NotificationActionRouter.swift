//
//  NotificationActionRouter.swift
//  AlgorithmXSDK
//
//  Mirrors the Android `NotificationActionRouter`. Single place that interprets
//  `actionType` and routes to the right SDK / partner action.
//

import Foundation
import UIKit

enum NotificationActionRouter {

    /// `trackOpen: false` when the tap was already tracked (an action button whose
    /// handler didn't handle it falls back to this default routing).
    static func route(data: [String: Any], trackOpen: Bool = true) {
        let data = EngageNotificationService.normalizedPushData(data)
        // 1. Track open + click.
        if trackOpen { trackOpened(data: data) }

        // 2. Partner first.
        if AlgorithmX.shared.notificationClickListener?.onNotificationClick(data: data) == true {
            return
        }

        // 3. Default action handling.
        let actionData = parseActionData(data["actionData"] as? String)
        let actionType = data["actionType"] as? String
        var performed = false
        switch actionType {
        case "openWebPage":
            performed = openExternalUrl(actionData["url"] as? String)
        case "openWebview":
            performed = openCampaignWebView(data: data, actionData: actionData)
        case "openScreen":
            if let deepLinkString = actionData["deepLink"] as? String,
               let url = URL(string: deepLinkString) {
                _ = AlgorithmX.shared.openDeepLink(url: url)
                performed = true
            }
        case "customAction":
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
        if let notifIdStr = data["algoNotificationId"] as? String,
           let notifId = Int(notifIdStr) {
            AlgorithmX.shared.updateNotificationStatus(notificationId: notifId, status: .opened)
        }
        if let campaignId = data["algoCampaignId"] as? String {
            let variationId = data["engageVariationId"] as? String ?? "default"
            AlgorithmX.shared.trackCampaignInteraction(
                campaignId: campaignId,
                variationId: variationId,
                interactionType: "click",
                payload: [
                    "notificationType": "push",
                    "action": data["actionType"] ?? "unknown"
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
              let campaignId = data["algoCampaignId"] as? String else { return false }
        let variationId = data["engageVariationId"] as? String ?? "default"
        AlgorithmX.shared.showWebView(
            campaignId: campaignId, variationId: variationId,
            url: url, dynamicContent: nil
        )
        return true
    }
}
