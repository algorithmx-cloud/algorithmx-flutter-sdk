//
//  EngageNotificationService.swift
//  AlgorithmXSDK
//
//  Helper class for Notification Service Extension
//

import Foundation
import UserNotifications

@objc public class EngageNotificationService: NSObject {

    // Written by AlgorithmX into the App Group, read here. This file must stay
    // self-contained: extensions (e.g. Flutter/RN apps) may compile it alone.
    static let sharedApiBaseUrlKey = "algorithmx.apiBaseUrl"
    static let sharedPartnerIdKey = "algorithmx.partnerId"
    static let sharedFingerprintKey = "algorithmx.fingerprint"

    // Normalize only the SDK's push schema. Partner-owned data and action text
    // retain their original keys and values; explicit camelCase keys win.
    static func normalizedPushData(_ data: [String: Any]) -> [String: Any] {
        var result = data
        let aliases = [
            ("engage_action", "engageAction"),
            ("algo_campaign_id", "algoCampaignId"),
            ("algo_notification_id", "algoNotificationId"),
            ("engage_variation_id", "engageVariationId"),
            ("engage_webview_url", "engageWebviewUrl"),
            ("engage_user_id", "engageUserId"),
            ("engage_dynamic_content", "engageDynamicContent"),
            ("engage_meta_image_url", "engageMetaImageUrl"),
            ("action_type", "actionType"),
            ("action_buttons", "actionButtons"),
            ("image_url", "imageUrl")
        ]
        for (legacy, canonical) in aliases {
            if result[canonical] == nil { result[canonical] = result[legacy] }
            result.removeValue(forKey: legacy)
        }
        if let action = result["engageAction"] as? String {
            switch action {
            case "algo_trigger_webview": result["engageAction"] = "algoTriggerWebview"
            case "algo_show_notification": result["engageAction"] = "algoShowNotification"
            default: break
            }
        }
        if let action = result["actionType"] as? String {
            switch action {
            case "open_web_page": result["actionType"] = "openWebPage"
            case "open_webview": result["actionType"] = "openWebview"
            case "open_screen": result["actionType"] = "openScreen"
            case "custom_action": result["actionType"] = "customAction"
            default: break
            }
        }
        if let buttons = result["actionButtons"] as? [[String: Any]] {
            result["actionButtons"] = normalizedActionButtons(buttons)
        } else if let raw = result["actionButtons"] as? String,
                  let data = raw.data(using: .utf8),
                  let buttons = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let normalized = try? JSONSerialization.data(withJSONObject: normalizedActionButtons(buttons)),
                  let json = String(data: normalized, encoding: .utf8) {
            result["actionButtons"] = json
        }
        return result
    }

    static func normalizedUserInfo(_ userInfo: [AnyHashable: Any]) -> [AnyHashable: Any] {
        var data: [String: Any] = [:]
        var result: [AnyHashable: Any] = [:]
        for (key, value) in userInfo {
            if let key = key as? String { data[key] = value }
            else { result[key] = value }
        }
        for (key, value) in normalizedPushData(data) { result[key] = value }
        return result
    }

    private static func normalizedActionButtons(_ buttons: [[String: Any]]) -> [[String: Any]] {
        buttons.map { button in
            var result = button
            if result["actionText"] == nil { result["actionText"] = result["action_text"] }
            result.removeValue(forKey: "action_text")
            return result
        }
    }

    /// True for notifications sent by AlgorithmX. When your extension also serves
    /// another push provider, call `processNotification` only for these.
    @objc public static func isAlgorithmXPush(_ request: UNNotificationRequest) -> Bool {
        isAlgorithmXPush(userInfo: request.content.userInfo)
    }

    @objc public static func isAlgorithmXPush(userInfo: [AnyHashable: Any]) -> Bool {
        let userInfo = normalizedUserInfo(userInfo)
        guard let action = userInfo["engageAction"] as? String else { return false }
        return action == "algoTriggerWebview" || action == "algoShowNotification"
    }

    /// Process notification content in Notification Service Extension
    /// Call this from your NotificationService extension's didReceive method
    @objc public static func processNotification(
        request: UNNotificationRequest,
        bestAttemptContent: UNMutableNotificationContent,
        contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        processNotification(
            request: request, bestAttemptContent: bestAttemptContent,
            appGroup: nil, contentHandler: contentHandler
        )
    }

    /// Same as above, and reports "delivered" and the impression of the visible
    /// notification, like Android does when it posts one. Pass the App Group that
    /// the app gave to `AlgorithmX.shared.initialize(apiBaseUrl:partnerId:appGroup:)`.
    @objc public static func processNotification(
        request: UNNotificationRequest,
        bestAttemptContent: UNMutableNotificationContent,
        appGroup: String?,
        contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let userInfo = normalizedUserInfo(request.content.userInfo)
        let finish: (Bool) -> Void = { hasImage in
            reportDelivery(
                userInfo: userInfo, content: bestAttemptContent,
                hasImage: hasImage, appGroup: appGroup
            ) { contentHandler(bestAttemptContent) }
        }


        // 1. Add action buttons if present
        if let actionButtons = parseActionButtons(from: userInfo) {
            addActionButtons(actionButtons, to: bestAttemptContent)
        }

        // 2. Download and attach image if present
        if let imageUrl = extractImageUrl(from: userInfo) {
            downloadImage(from: imageUrl) { attachment in
                if let attachment = attachment {
                    bestAttemptContent.attachments = [attachment]
                } else {
                    print("⚠️ AlgorithmX: Failed to attach image")
                }
                finish(attachment != nil)
            }
        } else {
            // No image, deliver immediately
            finish(false)
        }
    }

    // MARK: - Delivery reporting (same requests Android sends when it posts a notification)

    private static func reportDelivery(
        userInfo: [AnyHashable: Any],
        content: UNNotificationContent,
        hasImage: Bool,
        appGroup: String?,
        completion: @escaping () -> Void
    ) {
        guard let appGroup = appGroup,
              let defaults = UserDefaults(suiteName: appGroup),
              let apiUrl = defaults.string(forKey: sharedApiBaseUrlKey), !apiUrl.isEmpty,
              let partnerId = defaults.string(forKey: sharedPartnerIdKey), !partnerId.isEmpty,
              let fingerprint = defaults.string(forKey: sharedFingerprintKey), !fingerprint.isEmpty
        else { completion(); return }

        let group = DispatchGroup()
        if let idString = userInfo["algoNotificationId"] as? String, let notificationId = Int(idString) {
            send(
                "\(apiUrl)/api/v1/inAppPushEvents/device/status", method: "PUT",
                body: [
                    "notificationId": notificationId,
                    "fingerprintDevice": fingerprint,
                    "status": 2 // Delivered
                ],
                partnerId: partnerId, group: group
            )
        }
        if let campaignId = userInfo["algoCampaignId"] as? String {
            let variationId = userInfo["engageVariationId"] as? String ?? "default"
            let impression: [String: Any] = [
                "notificationType": "push",
                "title": content.title,
                "body": content.body,
                "hasImage": hasImage
            ]
            var body: [String: Any] = [
                "fingerprintDevice": fingerprint,
                "campaignId": Int(campaignId) ?? 0,
                "variationId": Int(variationId) ?? 0,
                "interactionType": "impression"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: impression),
               let json = String(data: data, encoding: .utf8) {
                body["payload"] = json
            }
            send(
                "\(apiUrl)/api/v1/tracks/algoViewInteract", method: "POST", body: body,
                partnerId: partnerId, group: group
            )
        }
        // The extension may be stopped once the content is handed back, so wait
        // (briefly) for the requests first.
        DispatchQueue.global().async {
            _ = group.wait(timeout: .now() + 5)
            completion()
        }
    }

    private static func send(
        _ endpoint: String, method: String, body: [String: Any], partnerId: String, group: DispatchGroup
    ) {
        guard let url = URL(string: endpoint),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(partnerId, forHTTPHeaderField: "x-partner-id")
        request.httpBody = data
        group.enter()
        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error = error {
                print("[AlgorithmX] ❌ \(method) \(endpoint) failed: \(error.localizedDescription)")
            }
            group.leave()
        }.resume()
    }

    // MARK: - Action Buttons Parsing

    private static func parseActionButtons(from userInfo: [AnyHashable: Any]) -> [[String: Any]]? {
        // Try parsing from string
        if let actionButtonsString = userInfo["actionButtons"] as? String,
            let actionButtonsData = actionButtonsString.data(using: .utf8),
            let actionButtons = try? JSONSerialization.jsonObject(with: actionButtonsData)
                as? [[String: Any]]
        {
            return actionButtons
        }

        // Try parsing from array
        if let actionButtons = userInfo["actionButtons"] as? [[String: Any]] {
            return actionButtons
        }

        return nil
    }

    private static func addActionButtons(
        _ buttons: [[String: Any]],
        to content: UNMutableNotificationContent
    ) {
        guard !buttons.isEmpty else { return }

        var actions: [UNNotificationAction] = []

        // Same rules as Android: at most 3 buttons, `title` and `actionText`
        // required, `id` defaults to action_<index>.
        for (index, button) in buttons.prefix(3).enumerated() {
            guard let actionText = button["actionText"] as? String,
                let title = button["title"] as? String
            else {
                continue
            }

            let buttonId = button["id"] as? String ?? "action_\(index)"

            let action = UNNotificationAction(
                identifier: buttonId,
                title: title,
                options: [.foreground]
            )

            actions.append(action)
        }

        if !actions.isEmpty {
            let categoryIdentifier = "ENGAGE_DYNAMIC_\(UUID().uuidString)"
            let category = UNNotificationCategory(
                identifier: categoryIdentifier,
                actions: actions,
                intentIdentifiers: [],
                options: .customDismissAction
            )

            // Register category synchronously
            let semaphore = DispatchSemaphore(value: 0)

            UNUserNotificationCenter.current().getNotificationCategories { existingCategories in
                var categories = existingCategories
                categories.insert(category)
                UNUserNotificationCenter.current().setNotificationCategories(categories)
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 2)

            content.categoryIdentifier = categoryIdentifier
        }
    }

    // MARK: - Image Handling

    private static func extractImageUrl(from userInfo: [AnyHashable: Any]) -> URL? {
        var imageUrlString: String?

        // Check multiple possible keys
        if let url = userInfo["imageUrl"] as? String {
            imageUrlString = url
        } else if let url = userInfo["engageMetaImageUrl"] as? String {
            imageUrlString = url
        } else if let url = userInfo["image"] as? String {
            imageUrlString = url
        }

        if let urlString = imageUrlString {
            return URL(string: urlString)
        }

        return nil
    }

    private static func downloadImage(
        from url: URL,
        completion: @escaping (UNNotificationAttachment?) -> Void
    ) {
        URLSession.shared.downloadTask(with: url) { location, response, error in
            guard let location = location, error == nil else {
                print(
                    "❌ AlgorithmX: Failed to download image: \(error?.localizedDescription ?? "unknown")"
                )
                completion(nil)
                return
            }

            // Determine file extension
            var fileExtension = url.pathExtension
            if fileExtension.isEmpty {
                if let mimeType = response?.mimeType {
                    fileExtension = getFileExtension(from: mimeType)
                } else {
                    fileExtension = "jpg"
                }
            }

            let tmpDirectory = NSTemporaryDirectory()
            let tmpFile = "engage_image_\(UUID().uuidString).\(fileExtension)"
            let tmpPath = tmpDirectory + tmpFile

            do {
                try FileManager.default.moveItem(atPath: location.path, toPath: tmpPath)
                let attachment = try UNNotificationAttachment(
                    identifier: "engage_image",
                    url: URL(fileURLWithPath: tmpPath),
                    options: nil
                )
                completion(attachment)
            } catch {
                print("❌ AlgorithmX: Error creating attachment: \(error)")
                completion(nil)
            }
        }.resume()
    }

    private static func getFileExtension(from mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        default:
            return "jpg"
        }
    }
}
