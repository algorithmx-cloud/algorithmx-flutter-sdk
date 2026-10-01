//
//  AlgorithmX.swift
//  AlgorithmXSDK
//
//  Public entry point of the AlgorithmX in-app SDK. Mirrors the Android
//  `AlgorithmX` object: same method names, same payload shapes, same
//  notification payload keys (engage_action, algo_campaign_id, etc.).
//

import Foundation
import UIKit
import UserNotifications

@objc public class AlgorithmX: NSObject {

    // MARK: - Singleton
    @objc public static let shared = AlgorithmX()

    // MARK: - State
    private var apiUrl: String = ""
    private var fingerprintDevice: String?
    private var engageUserId: String?
    private var dispatcher: EventDispatcher?
    private var webViewQueueManager: WebViewQueueManager?
    private var isWebViewShowing: Bool = false
    private var appGroup: String?
    private var initialized = false
    private var lastDeviceToken: String?

    static let identifiedUserIdKey = "algorithmx.identifiedUserId"

    // MARK: - Listeners (weak to avoid retain cycles)
    public weak var webViewListener: AlgoWebViewListener?
    public weak var notificationClickListener: NotificationClickListener?
    public weak var deepLinkHandler: DeepLinkHandler?
    public weak var actionButtonHandler: ActionButtonHandler?
    public weak var campaignInteractionListener: CampaignInteractionListener?

    // MARK: - Notification status enum
    @objc public enum NotificationEventStatus: Int {
        case sent = 1
        case delivered = 2
        case opened = 3
        case failedToSend = 4
        case failedToDeliver = 5
    }

    // MARK: - Initialization

    /// Safe to call more than once: later calls only update the base URL.
    @objc public func initialize(apiBaseUrl: String) {
        self.apiUrl = apiBaseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if initialized { shareConfigWithExtension(); return }
        initialized = true
        self.dispatcher = EventDispatcher.shared
        self.webViewQueueManager = WebViewQueueManager()

        // An identified user survives restarts. Otherwise default the fingerprint
        // to the iOS vendor identifier so partners don't have to set anything by
        // hand. They can still override with setDeviceFingerprint.
        if let saved = UserDefaults.standard.string(forKey: Self.identifiedUserIdKey), !saved.isEmpty {
            fingerprintDevice = saved
        } else if fingerprintDevice == nil,
           let vendorId = UIDevice.current.identifierForVendor?.uuidString {
            fingerprintDevice = vendorId
        }
        shareConfigWithExtension()

        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWentBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )

        registerNotificationCategories()
    }

    /**
     Same as `initialize(apiBaseUrl:)`, and shares the backend URL and user id with
     the Notification Service Extension through the App Group, so the extension can
     report "delivered" and the impression of visible notifications (like Android).
     Pass the same App Group to `EngageNotificationService.processNotification`.
     */
    @objc public func initialize(apiBaseUrl: String, appGroup: String) {
        self.appGroup = appGroup
        initialize(apiBaseUrl: apiBaseUrl)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Debug logging (console prefix "[AlgorithmX]"). Off by default; errors are always logged.
    @objc public func setLoggingEnabled(_ enabled: Bool) { SdkLog.enabled = enabled }

    private func shareConfigWithExtension() {
        guard let appGroup = appGroup, let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(apiUrl, forKey: EngageNotificationService.sharedApiBaseUrlKey)
        defaults.set(resolveUserId(), forKey: EngageNotificationService.sharedFingerprintKey)
    }

    // MARK: - Identity & device

    @objc public func setDeviceFingerprint(_ fingerprint: String) {
        fingerprintDevice = fingerprint
        shareConfigWithExtension()
    }

    @objc public func getDeviceFingerprint() -> String? { fingerprintDevice }

    /// Identify a user. Kept across app restarts until `resetIdentity()`.
    @objc public func identifyUser(userId: String, attributes: [String: Any]? = nil) {
        let previous = resolveUserId()
        fingerprintDevice = userId
        UserDefaults.standard.set(userId, forKey: Self.identifiedUserIdKey)
        shareConfigWithExtension()
        // previousFingerprintDevice lets the backend link what happened before login.
        var body: [String: Any] = ["fingerprintDevice": userId, "previousFingerprintDevice": previous]
        if let attributes = attributes { body["attributes"] = attributes }
        dispatcher?.send(endpoint: "\(apiUrl)/api/v1/identify", method: "POST", payload: body)
        if previous != userId { reRegisterDeviceToken() }
    }

    /// Forget the identified user (e.g. on logout) and go back to the device id.
    @objc public func resetIdentity() {
        let previous = resolveUserId()
        UserDefaults.standard.removeObject(forKey: Self.identifiedUserIdKey)
        fingerprintDevice = UIDevice.current.identifierForVendor?.uuidString
        shareConfigWithExtension()
        if previous != resolveUserId() { reRegisterDeviceToken() }
    }

    /// Pushes are sent to the token's owner, so move the token to the new identity at once.
    private func reRegisterDeviceToken() {
        if let token = lastDeviceToken { registerDeviceToken(token) }
    }

    private func resolveUserId() -> String {
        fingerprintDevice ?? engageUserId ?? UIDevice.current.identifierForVendor?.uuidString ?? "anonymous"
    }

    // MARK: - Event tracking

    @objc public func trackEvent(_ name: String, properties: [String: Any]? = nil) {
        let userId = resolveUserId()
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        var body: [String: Any] = [
            "event": name,
            "fingerprintDevice": userId,
            "timestamp": timestampMs
        ]
        if let properties = properties { body["payload"] = properties }
        dispatcher?.send(endpoint: "\(apiUrl)/api/v1/tracks/\(name)", method: "POST", payload: body)
    }

    @objc public func trackCampaignInteraction(
        campaignId: String,
        variationId: String,
        interactionType: String,
        payload: [String: Any]? = nil,
        sessionId: String? = nil,
        endpoint: String? = nil
    ) {
        let userId = resolveUserId()

        var payloadString: String?
        if let payload = payload,
           let data = try? JSONSerialization.data(withJSONObject: payload),
           let s = String(data: data, encoding: .utf8) {
            payloadString = s
        }

        var body: [String: Any] = [
            "FingerprintDevice": userId,
            "CampaignId": Int(campaignId) ?? 0,
            "VariationId": Int(variationId) ?? 0,
            "InteractionType": interactionType
        ]
        if let payloadString = payloadString { body["Payload"] = payloadString }
        if let sessionId = sessionId { body["sessionId"] = sessionId }

        let path = endpoint ?? "/api/v1/tracks/algo_view_interact"
        dispatcher?.send(endpoint: "\(apiUrl)\(path)", method: "POST", payload: body)

        if let listener = campaignInteractionListener {
            let cbPayload = payload ?? [:]
            DispatchQueue.main.async { [weak listener] in
                listener?.onCampaignInteraction(
                    campaignId: campaignId,
                    variationId: variationId,
                    interactionType: interactionType,
                    payload: cbPayload
                )
            }
        }
    }

    @objc public func updateNotificationStatus(
        notificationId: Int,
        status: NotificationEventStatus,
        errorMessage: String? = nil
    ) {
        var body: [String: Any] = [
            "notificationId": notificationId,
            "fingerprintDevice": resolveUserId(),
            "status": status.rawValue
        ]
        if let err = errorMessage { body["errorMessage"] = err }
        dispatcher?.send(
            endpoint: "\(apiUrl)/api/v1/in-app-push-events/device/status",
            method: "PUT", payload: body
        )
    }

    // MARK: - Push token registration

    @objc public func registerDeviceToken(_ token: String) {
        lastDeviceToken = token
        let body: [String: Any] = [
            "fingerprintDevice": resolveUserId(),
            "token": token,
            "platform": "ios"
        ]
        dispatcher?.send(endpoint: "\(apiUrl)/api/v1/notification-tokens", method: "POST", payload: body)
    }

    // MARK: - Push notification handling

    /// True for pushes sent by AlgorithmX. When your app also receives pushes from
    /// another provider, forward only these to the SDK. Same check as Android.
    @objc public func isAlgorithmXPush(userInfo: [AnyHashable: Any]) -> Bool {
        EngageNotificationService.isAlgorithmXPush(userInfo: userInfo)
    }

    /**
     Unified notification entry point. Mirrors Android `handleFcmMessage`.
     Routes silent webview triggers vs. visual notifications based on
     `engage_action`. The completion handler must be called by iOS contract.
     */
    @objc public func handleNotification(
        userInfo: [AnyHashable: Any],
        completionHandler: @escaping () -> Void
    ) {
        guard let action = userInfo["engage_action"] as? String else {
            completionHandler(); return
        }
        switch action {
        case "algo_trigger_webview":
            processSilentNotification(userInfo: userInfo)
        case "algo_show_notification":
            // iOS displays visual notifications via the OS automatically.
            break
        default:
            break
        }
        completionHandler()
    }

    private func processSilentNotification(userInfo: [AnyHashable: Any]) {
        guard let campaignId = userInfo["algo_campaign_id"] as? String, !campaignId.isEmpty,
              let webviewUrl = userInfo["engage_webview_url"] as? String, !webviewUrl.isEmpty else { return }
        // Same as Android: a missing variation id defaults to "0".
        let variationId = userInfo["engage_variation_id"] as? String ?? "0"

        if let userIdFromPayload = userInfo["engage_user_id"] as? String, !userIdFromPayload.isEmpty {
            engageUserId = userIdFromPayload
        }

        var dynamicContent: [String: Any]?
        if let str = userInfo["engage_dynamic_content"] as? String,
           let data = str.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dynamicContent = json
        }

        var displayRule = WebViewDisplayRule()
        if let str = userInfo["configs"] as? String,
           let data = str.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            displayRule = WebViewDisplayRule.fromDict(json)
        }

        let userId = resolveUserId()

        trackEvent("silent_notification_received", properties: [
            "campaignId": campaignId,
            "variationId": variationId,
            "action": "algo_trigger_webview",
            "hasDynamicContent": dynamicContent != nil,
            "hasConfigs": true,
            "priority": displayRule.priority
        ])

        // Match Android: only enqueue if the webview can be (or eventually will be) displayed,
        // also while another webview is showing: an entry that can never show would stay
        // queued and block its variation id.
        let canShow = webViewQueueManager?.canDisplayWebView(
            campaignId: campaignId, variationId: variationId, userId: userId, rule: displayRule
        ) ?? false
        let willShowLater = webViewQueueManager?.willBeAbleToDisplayLater(
            campaignId: campaignId, variationId: variationId, userId: userId, rule: displayRule
        ) ?? false

        if canShow || willShowLater {
            _ = webViewQueueManager?.enqueueWebView(
                campaignId: campaignId, variationId: variationId,
                webviewUrl: webviewUrl, dynamicContent: dynamicContent, displayRule: displayRule
            )
        }
    }

    // MARK: - Notification response (tap / action button)

    @objc public func handleNotificationResponse(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any],
        completionHandler: @escaping () -> Void
    ) {
        // Only AlgorithmX notifications; the host's own notifications are never touched.
        guard isAlgorithmXPush(userInfo: userInfo) else { completionHandler(); return }
        let isActionButton = actionIdentifier != "com.apple.UNNotificationDefaultActionIdentifier"
            && actionIdentifier != "com.apple.UNNotificationDismissActionIdentifier"

        if isActionButton {
            handleActionButton(buttonId: actionIdentifier, userInfo: userInfo)
        } else if actionIdentifier == "com.apple.UNNotificationDismissActionIdentifier" {
            // Notification was swiped away — nothing to do.
        } else {
            handleNotificationClick(userInfo: userInfo)
        }
        completionHandler()
    }

    @objc public func handleNotificationClick(userInfo: [AnyHashable: Any]) {
        guard isAlgorithmXPush(userInfo: userInfo) else { return }
        var data: [String: Any] = [:]
        for (k, v) in userInfo { if let k = k as? String { data[k] = v } }
        NotificationActionRouter.route(data: data)
    }

    /// Same as Android: always track opened + the button click, then give the
    /// partner's handler the button; if it doesn't handle it, the notification's
    /// own `action_type` runs.
    private func handleActionButton(buttonId: String, userInfo: [AnyHashable: Any]) {
        var data: [String: Any] = [:]
        for (k, v) in userInfo { if let k = k as? String { data[k] = v } }

        let buttons = parseActionButtons(from: userInfo)
        let button = buttons.enumerated().first(where: { index, button in
            (button["id"] as? String ?? "action_\(index)") == buttonId
        })?.element

        let actionText = button?["action_text"] as? String ?? ""
        let title = button?["title"] as? String ?? ""

        if let notifIdStr = data["algo_notification_id"] as? String, let notifId = Int(notifIdStr) {
            updateNotificationStatus(notificationId: notifId, status: .opened)
        }
        if let campaignId = data["algo_campaign_id"] as? String {
            trackCampaignInteraction(
                campaignId: campaignId,
                variationId: data["engage_variation_id"] as? String ?? "default",
                interactionType: "click",
                payload: [
                    "notification_type": "push",
                    "interaction_type": "action_button",
                    "button_id": buttonId,
                    "action_text": actionText,
                    "button_title": title
                ]
            )
        }

        let handled = actionButtonHandler?.onActionButtonClicked(
            buttonId: buttonId, actionText: actionText, title: title, notificationData: data
        ) ?? false
        if !handled { NotificationActionRouter.route(data: data, trackOpen: false) }
    }

    private func parseActionButtons(from userInfo: [AnyHashable: Any]) -> [[String: Any]] {
        if let s = userInfo["action_buttons"] as? String,
           let data = s.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return arr
        }
        if let arr = userInfo["action_buttons"] as? [[String: Any]] { return arr }
        return []
    }

    // MARK: - Deep link

    /**
     Delegate-only: if no `deepLinkHandler` is set the SDK does NOT navigate.
     Returns true iff the partner reported they handled the URL.
     */
    @objc public func openDeepLink(url: URL) -> Bool {
        deepLinkHandler?.onDeepLinkReceived(url: url) ?? false
    }

    // MARK: - WebView display

    @objc public func showWebView(
        campaignId: String,
        variationId: String,
        url: String,
        dynamicContent: [String: Any]?,
        expiresAt: Int64 = 0
    ) {
        guard !isWebViewShowing else { return }
        isWebViewShowing = true

        DispatchQueue.main.async {
            let vc = CampaignViewController(
                campaignId: campaignId, variationId: variationId,
                url: url, dynamicContent: dynamicContent, expiresAt: expiresAt
            )
            // Over the app with a clear background, like Android's translucent
            // activity: the template draws its own backdrop and close button.
            vc.modalPresentationStyle = .overFullScreen
            vc.modalTransitionStyle = .crossDissolve

            // Present on top of whatever is on screen (a modal included); presenting
            // from a controller that is already presenting would silently fail.
            if let top = self.topViewController() {
                top.present(vc, animated: true)
            } else {
                self.isWebViewShowing = false
            }
        }
    }

    @objc public func setWebViewShowing(_ showing: Bool) { isWebViewShowing = showing }
    @objc public func isWebViewCurrentlyShowing() -> Bool { isWebViewShowing }

    /// Recorded by `CampaignViewController` after the HTML loads successfully.
    func recordWebViewDisplaySuccess(campaignId: String, variationId: String, expiresAt: Int64 = 0) {
        webViewQueueManager?.recordWebViewDisplay(
            campaignId: campaignId, variationId: variationId,
            userId: resolveUserId(), expiresAt: expiresAt
        )
    }

    @objc public func triggerWebView(
        campaignId: String,
        webviewUrl: String,
        dynamicContent: [String: Any]?
    ) {
        guard !isWebViewShowing else { return }
        showWebView(campaignId: campaignId, variationId: "default", url: webviewUrl, dynamicContent: dynamicContent)
        webViewListener?.onWebViewTrigger(
            campaignId: campaignId, webviewUrl: webviewUrl, dynamicContent: dynamicContent
        )
    }

    // MARK: - Lifecycle

    @objc private func appBecameActive() {
        if !isWebViewShowing {
            _ = webViewQueueManager?.processQueuedWebViews(userId: resolveUserId())
        }
    }

    @objc private func appWentBackground() {
        webViewQueueManager?.resetSessionFlag()
    }

    // MARK: - Misc

    @objc public func getQueueSize() -> Int { webViewQueueManager?.getQueueSize() ?? 0 }
    @objc public func getWebViewQueueSize() -> Int { getQueueSize() }
    @objc public func clearWebViewQueue() -> Int { webViewQueueManager?.clearQueue() ?? 0 }
    @objc public func clearAllWebViewData() -> Bool { webViewQueueManager?.clearAllData() ?? false }

    @objc public func getDisplayStats(campaignId: String, variationId: String) -> String {
        webViewQueueManager?.getDisplayStats(
            campaignId: campaignId, variationId: variationId, userId: resolveUserId()
        ) ?? "WebView queue manager not initialized"
    }

    /// Adds the SDK's category to the ones the host app registered (never replaces them).
    private func registerNotificationCategories() {
        let dynamicCategory = UNNotificationCategory(
            identifier: "ENGAGE_DYNAMIC_ACTIONS",
            actions: [], intentIdentifiers: [],
            options: .customDismissAction
        )
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            var categories = existing.filter { $0.identifier != dynamicCategory.identifier }
            categories.insert(dynamicCategory)
            center.setNotificationCategories(categories)
        }
    }

    /// Dynamic content value as text, same on both platforms: strings as-is,
    /// booleans as true/false, numbers as written, objects/arrays as JSON.
    static func dynamicValueText(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: value)
    }

    private func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
