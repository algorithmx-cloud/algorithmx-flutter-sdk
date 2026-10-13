//
//  AlgorithmX.swift
//  AlgorithmXSDK
//
//  Public entry point of the AlgorithmX in-app SDK. Mirrors the Android
//  `AlgorithmX` object: same method names, same payload shapes, same
//  notification payload keys (engageAction, algoCampaignId, etc.).
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
    private var deviceId: String?
    private var identifiedUserId: String?
    private var identityPartnerId: String?
    private var engageUserId: String?
    private var dispatcher: EventDispatcher?
    private var webViewQueueManager: WebViewQueueManager?
    private var isWebViewShowing: Bool = false
    private var appGroup: String?
    private var initialized = false
    private var lastDeviceToken: String?
    private var inAppLanguage: String?
    private var inAppSessionId = UUID()
    private var hasFetchedInAppViewsThisSession = false
    private var hasDisplayedInAppViewThisSession = false
    private var pendingInAppViews: [InAppView] = []
    private var pendingInAppCustomerId: String?
    private weak var inAppController: CampaignViewController?
    private var inAppFetchAttempts = 0
    private var inAppVisitStartedAt = Date()
    private var pendingInAppUserId: String?

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

    /// Safe to call more than once with the same partner ID; later calls update the base URL.
    /// `partnerId` is sent as the `x-partner-id` header on every request.
    @objc public func initialize(apiBaseUrl: String, partnerId: String) {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.initialize(apiBaseUrl: apiBaseUrl, partnerId: partnerId) }; return }
        guard !initialized || identityPartnerId == partnerId else { SdkLog.error("Cannot change partnerId after initialization"); return }
        let alreadyInitialized = initialized
        initializeIdentity(apiBaseUrl: apiBaseUrl, partnerId: partnerId)
        if alreadyInitialized { return }
        self.webViewQueueManager = WebViewQueueManager()
        _ = self.webViewQueueManager?.clearQueue()

        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWentBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )

        NotificationCenter.default.addObserver(self, selector: #selector(networkBecameAvailable),
            name: Notification.Name("AlgorithmXConnectivityRestored"), object: nil)
        registerNotificationCategories()
        // Initialization may happen after didBecomeActive, e.g. in a SwiftUI task.
        DispatchQueue.main.async {
            if UIApplication.shared.applicationState == .active { self.appBecameActive() }
        }
    }

    /**
     Same as `initialize(apiBaseUrl:partnerId:)`, and shares the backend URL, partner ID
     and user id with the Notification Service Extension through the App Group, so the
     extension can report "delivered" and the impression of visible notifications (like
     Android). Pass the same App Group to `EngageNotificationService.processNotification`.
     */
    @objc public func initialize(apiBaseUrl: String, partnerId: String, appGroup: String) {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.initialize(apiBaseUrl: apiBaseUrl, partnerId: partnerId, appGroup: appGroup) }; return }
        self.appGroup = appGroup
        initialize(apiBaseUrl: apiBaseUrl, partnerId: partnerId)
    }

    // Transport and identity setup is independent of notification/UI registration.
    func initializeIdentity(apiBaseUrl: String, partnerId: String) {
        guard !initialized || identityPartnerId == partnerId else { SdkLog.error("Cannot change partnerId after initialization"); return }
        self.apiUrl = apiBaseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        NetworkClient.shared.partnerId = partnerId
        if initialized {
            bootstrapIdentity()
            shareConfigWithExtension()
            return
        }
        identityPartnerId = partnerId
        initialized = true
        self.dispatcher = EventDispatcher.shared

        fingerprintDevice = storedUuid("algorithmx.anonymousId")
        deviceId = storedUuid("algorithmx.deviceId")
        identifiedUserId = UserDefaults.standard.string(forKey: Self.identifiedUserIdKey)
        bootstrapIdentity()
        if let userId = identifiedUserId, !userId.isEmpty { identifyUser(userId: userId) }
        shareConfigWithExtension()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Debug logging (console prefix "[AlgorithmX]"). Off by default; errors are always logged.
    @objc public func setLoggingEnabled(_ enabled: Bool) { SdkLog.enabled = enabled }

    private func shareConfigWithExtension() {
        guard let appGroup = appGroup, let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(apiUrl, forKey: EngageNotificationService.sharedApiBaseUrlKey)
        defaults.set(NetworkClient.shared.partnerId, forKey: EngageNotificationService.sharedPartnerIdKey)
        defaults.set(resolveUserId(), forKey: EngageNotificationService.sharedFingerprintKey)
    }

    // MARK: - Identity & device

    /// Legacy anonymous-ID override. Must be a UUID; use identifyUser for account IDs.
    @objc public func setDeviceFingerprint(_ fingerprint: String) {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.setDeviceFingerprint(fingerprint) }; return }
        guard let uuid = UUID(uuidString: fingerprint) else { SdkLog.error("fingerprint must be a UUID"); return }
        let value = uuid.uuidString.lowercased()
        if value == fingerprintDevice { return }
        fingerprintDevice = value
        identifiedUserId = nil
        UserDefaults.standard.set(value, forKey: "algorithmx.anonymousId")
        UserDefaults.standard.removeObject(forKey: Self.identifiedUserIdKey)
        _ = clearWebViewQueue()
        pendingInAppViews = []
        pendingInAppUserId = nil
        inAppSessionId = UUID()
        hasFetchedInAppViewsThisSession = false
        pendingInAppCustomerId = nil
        inAppFetchAttempts = 0
        inAppController?.dismiss(animated: false)
        inAppController = nil
        bootstrapIdentity()
        shareConfigWithExtension()
        reRegisterDeviceToken()
        fetchInAppViews()
    }

    @objc public func getAnonymousId() -> String { resolveUserId() }
    @objc public func getDeviceFingerprint() -> String? { fingerprintDevice }

    /// Link the anonymous profile to ExternalId and optional email, phone and customer traits.
    @objc public func identifyUser(userId: String, attributes: [String: Any]? = nil) {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.identifyUser(userId: userId, attributes: attributes) }; return }
        do {
            let previousCustomerId = resolveCustomerId()
            let identifiers = try IdentityPayload.identifiers(userId: userId, attributes: attributes)
            let profile = try IdentityPayload.profile(attributes)
            if let current = identifiedUserId, current != userId { resetIdentity() }
            identifiedUserId = userId
            UserDefaults.standard.set(userId, forKey: Self.identifiedUserIdKey)
            bootstrapIdentity()
            dispatcher?.send(endpoint: "\(apiUrl)/api/v1/Identity", method: "POST", payload: [
                "anonymousId": resolveUserId(), "trustedIdentifiers": identifiers
            ])
            if !profile.isEmpty { sendUserProfile(profile) }
            if previousCustomerId != resolveCustomerId() || !profile.isEmpty { refreshInAppIdentity() }
        } catch { SdkLog.error(error.localizedDescription) }
    }

    /// Ingestion replaces the complete profile; include all current values.
    @objc public func setUserProfile(_ attributes: [String: Any]) {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.setUserProfile(attributes) }; return }
        do {
            guard !attributes.keys.contains(where: { IdentityPayload.identifierFields[$0] != nil }) else {
                SdkLog.error("Use identifyUser for email, phone and userName"); return
            }
            let profile = try IdentityPayload.profile(attributes)
            guard !profile.isEmpty else { SdkLog.error("Profile must contain at least one supported field"); return }
            bootstrapIdentity()
            sendUserProfile(profile)
            refreshInAppIdentity()
        } catch { SdkLog.error(error.localizedDescription) }
    }

    private func sendUserProfile(_ profile: [String: Any]) {
        dispatcher?.send(endpoint: "\(apiUrl)/api/v1/Customer/Ingest", method: "POST", payload: profile,
            headers: ["X-Anonymous-Id": resolveUserId(), "X-Device-Id": deviceId ?? ""])
    }

    /// Logout starts a new anonymous profile while retaining the installation's device UUID.
    @objc public func resetIdentity() {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.resetIdentity() }; return }
        identifiedUserId = nil
        fingerprintDevice = UUID().uuidString.lowercased()
        UserDefaults.standard.removeObject(forKey: Self.identifiedUserIdKey)
        UserDefaults.standard.set(fingerprintDevice, forKey: "algorithmx.anonymousId")
        _ = clearWebViewQueue()
        pendingInAppViews = []
        pendingInAppUserId = nil
        inAppSessionId = UUID()
        hasFetchedInAppViewsThisSession = false
        pendingInAppCustomerId = nil
        inAppFetchAttempts = 0
        inAppController?.dismiss(animated: false)
        inAppController = nil
        bootstrapIdentity()
        shareConfigWithExtension()
        reRegisterDeviceToken()
        fetchInAppViews()
    }

    private func reRegisterDeviceToken() {
        if let token = lastDeviceToken { registerDeviceToken(token) }
    }

    private func storedUuid(_ key: String) -> String {
        let saved = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:))
        let value = (saved ?? UUID()).uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private func resolveUserId() -> String {
        if let value = fingerprintDevice { return value }
        let value = storedUuid("algorithmx.anonymousId")
        fingerprintDevice = value
        return value
    }

    private func bootstrapIdentity() {
        guard initialized else { return }
        if deviceId == nil { deviceId = storedUuid("algorithmx.deviceId") }
        dispatcher?.send(endpoint: "\(apiUrl)/api/v1/Identity/Bootstrap", method: "POST", payload: [
            "anonymousId": resolveUserId(), "deviceId": deviceId!,
            "userAgent": ["os": "iOS \(UIDevice.current.systemVersion)", "deviceType": "mobile",
                "deviceVendor": "Apple", "deviceModel": UIDevice.current.model]
        ])
    }

    /// Defaults to the device's preferred language. No call is needed for automatic fetching.
    @objc public func setInAppLanguage(_ language: String) {
        if !Thread.isMainThread { DispatchQueue.main.sync { self.setInAppLanguage(language) }; return }
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inAppLanguage != value else { return }
        inAppLanguage = value
        refreshInAppIdentity()
    }

    // MARK: - Event tracking

    @objc public func trackEvent(_ name: String, properties: [String: Any]? = nil) {
        let request = makeEventLogRequest(name, properties: properties)
        dispatcher?.send(
            endpoint: "\(apiUrl)/api/v1/Event/Log", method: "POST", payload: request.payload,
            headers: request.headers
        )
    }

    func makeEventLogRequest(_ name: String, properties: [String: Any]?)
        -> (payload: [[String: Any]], headers: [String: String]) {
        let userId = resolveUserId()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body: [String: Any] = [
            "eventType": name,
            "data": properties ?? [:],
            "timestamp": formatter.string(from: Date())
        ]
        return ([body], ["X-Anonymous-Id": userId, "X-Device-Id": deviceId ?? ""])
    }

    @objc public func trackCampaignInteraction(
        campaignId: String,
        variationId: String,
        interactionType: String,
        payload: [String: Any]? = nil,
        sessionId: String? = nil,
        endpoint: String? = nil
    ) {
        sendCampaignInteraction(campaignId: campaignId, variationId: variationId,
            interactionType: interactionType, payload: payload, sessionId: sessionId,
            endpoint: endpoint, userId: resolveUserId())
    }

    func sendCampaignInteraction(
        campaignId: String, variationId: String, interactionType: String,
        payload: [String: Any]?, sessionId: String? = nil, endpoint: String? = nil,
        userId: String? = nil
    ) {
        let userId = userId ?? resolveUserId()
        var payloadString: String?
        if let payload = payload,
           let data = try? JSONSerialization.data(withJSONObject: payload),
           let s = String(data: data, encoding: .utf8) {
            payloadString = s
        }

        var body = makeCampaignInteractionBody(
            campaignId: campaignId, variationId: variationId, interactionType: interactionType,
            userId: userId
        )
        if let payloadString = payloadString { body["payload"] = payloadString }
        if let sessionId = sessionId { body["sessionId"] = sessionId }

        let path = endpoint ?? "/api/v1/tracks/algoViewInteract"
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

    func makeCampaignInteractionBody(
        campaignId: String, variationId: String, interactionType: String, userId: String
    ) -> [String: Any] {
        ["fingerprintDevice": userId, "campaignId": campaignId,
         "variationId": variationId, "interactionType": interactionType]
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
            endpoint: "\(apiUrl)/api/v1/inAppPushEvents/device/status",
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
        dispatcher?.send(endpoint: "\(apiUrl)/api/v1/notificationTokens", method: "POST", payload: body)
    }

    // MARK: - Push notification handling

    /// True for pushes sent by AlgorithmX. When your app also receives pushes from
    /// another provider, forward only these to the SDK. Same check as Android.
    @objc public func isAlgorithmXPush(userInfo: [AnyHashable: Any]) -> Bool {
        EngageNotificationService.isAlgorithmXPush(userInfo: userInfo)
    }

    /**
     Unified notification entry point. Mirrors Android `handleFcmMessage`.
     Visual push handling stays separate from API-delivered in-app views.
     The completion handler must be called by iOS contract.
     */
    @objc public func handleNotification(
        userInfo: [AnyHashable: Any],
        completionHandler: @escaping () -> Void
    ) {
        let userInfo = EngageNotificationService.normalizedUserInfo(userInfo)
        guard let action = userInfo["engageAction"] as? String else {
            completionHandler(); return
        }
        switch action {
        case "algoTriggerWebview":
            SdkLog.debug("Ignoring legacy silent-push in-app trigger; views are fetched from the API")
        case "algoShowNotification":
            // iOS displays visual notifications via the OS automatically.
            break
        default:
            break
        }
        completionHandler()
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
        let userInfo = EngageNotificationService.normalizedUserInfo(userInfo)
        var data: [String: Any] = [:]
        for (k, v) in userInfo { if let k = k as? String { data[k] = v } }
        NotificationActionRouter.route(data: data)
    }

    /// Same as Android: always track opened + the button click, then give the
    /// partner's handler the button; if it doesn't handle it, the notification's
    /// own `actionType` runs.
    private func handleActionButton(buttonId: String, userInfo: [AnyHashable: Any]) {
        let userInfo = EngageNotificationService.normalizedUserInfo(userInfo)
        var data: [String: Any] = [:]
        for (k, v) in userInfo { if let k = k as? String { data[k] = v } }

        let buttons = parseActionButtons(from: userInfo)
        let button = buttons.enumerated().first(where: { index, button in
            (button["id"] as? String ?? "action_\(index)") == buttonId
        })?.element

        let actionText = button?["actionText"] as? String ?? ""
        let title = button?["title"] as? String ?? ""

        if let notifIdStr = data["algoNotificationId"] as? String, let notifId = Int(notifIdStr) {
            updateNotificationStatus(notificationId: notifId, status: .opened)
        }
        if let campaignId = data["algoCampaignId"] as? String {
            trackCampaignInteraction(
                campaignId: campaignId,
                variationId: data["engageVariationId"] as? String ?? "default",
                interactionType: "click",
                payload: [
                    "notificationType": "push",
                    "interactionType": "actionButton",
                    "buttonId": buttonId,
                    "actionText": actionText,
                    "buttonTitle": title
                ]
            )
        }

        let handled = actionButtonHandler?.onActionButtonClicked(
            buttonId: buttonId, actionText: actionText, title: title, notificationData: data
        ) ?? false
        if !handled { NotificationActionRouter.route(data: data, trackOpen: false) }
    }

    private func parseActionButtons(from userInfo: [AnyHashable: Any]) -> [[String: Any]] {
        if let s = userInfo["actionButtons"] as? String,
           let data = s.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return arr
        }
        if let arr = userInfo["actionButtons"] as? [[String: Any]] { return arr }
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

    @objc public func setWebViewShowing(_ showing: Bool) {
        isWebViewShowing = showing
        if !showing {
            DispatchQueue.main.async { self.showNextInAppView() }
        }
    }
    @objc public func isWebViewCurrentlyShowing() -> Bool { isWebViewShowing }

    /// Recorded by `CampaignViewController` after the HTML loads successfully.
    func recordWebViewDisplaySuccess(
        campaignId: String, variationId: String, expiresAt: Int64 = 0, userId: String? = nil
    ) {
        webViewQueueManager?.recordWebViewDisplay(
            campaignId: campaignId, variationId: variationId,
            userId: userId ?? resolveUserId(), expiresAt: expiresAt
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
        inAppVisitStartedAt = Date()
        bootstrapIdentity()
        if let userId = identifiedUserId { identifyUser(userId: userId) }
        fetchInAppViews()
        showNextInAppView()
    }

    @objc private func appWentBackground() {
        webViewQueueManager?.resetSessionFlag()
        inAppSessionId = UUID()
        hasFetchedInAppViewsThisSession = false
        hasDisplayedInAppViewThisSession = false
        pendingInAppViews = []
        pendingInAppUserId = nil
        pendingInAppCustomerId = nil
        inAppFetchAttempts = 0
    }

    // MARK: - API-delivered in-app views

    func makeInAppViewsRequest(language: String, customerId: String, anonymousId: String) -> URLRequest? {
        guard var components = URLComponents(string: "\(apiUrl)/api/v1/inAppViews") else { return nil }
        components.queryItems = [URLQueryItem(name: "language", value: language),
                                 URLQueryItem(name: "customerId", value: customerId)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(NetworkClient.shared.partnerId, forHTTPHeaderField: "X-Partner-Id")
        request.setValue(anonymousId, forHTTPHeaderField: "X-Anonymous-Id")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        return request
    }

    func sendInAppViewInteraction(campaignId: String, variationId: String, viewId: String,
        interactionType: String, payload: [String: Any]?, anonymousId: String, customerId: String) {
        var data = payload ?? [:]
        data["campaignId"] = campaignId
        data["variationId"] = variationId
        data["inAppViewId"] = viewId
        data["interactionType"] = interactionType
        data["customerId"] = customerId
        let body: [[String: Any]] = [["eventType": "inAppViewInteraction", "data": data,
            "timestamp": ISO8601DateFormatter().string(from: Date())]]
        dispatcher?.send(endpoint: "\(apiUrl)/api/v1/Event/Log", method: "POST", payload: body,
            headers: ["X-Anonymous-Id": anonymousId, "X-Device-Id": deviceId ?? ""])
        campaignInteractionListener?.onCampaignInteraction(campaignId: campaignId, variationId: variationId,
            interactionType: interactionType, payload: data)
    }

    private func resolveCustomerId() -> String { identifiedUserId ?? resolveUserId() }

    private func refreshInAppIdentity() {
        pendingInAppViews = []
        pendingInAppUserId = nil
        pendingInAppCustomerId = nil
        inAppSessionId = UUID()
        hasFetchedInAppViewsThisSession = false
        inAppFetchAttempts = 0
        inAppController?.dismiss(animated: false)
        inAppController = nil
        fetchInAppViews()
    }

    func makeCurrentInAppViewsRequest() -> URLRequest? {
        let language = inAppLanguage.flatMap { $0.isEmpty ? nil : $0 } ?? Locale.preferredLanguages.first ?? "en"
        return makeInAppViewsRequest(language: language, customerId: resolveCustomerId(), anonymousId: resolveUserId())
    }

    @objc private func networkBecameAvailable() {
        guard UIApplication.shared.applicationState == .active else { return }
        inAppFetchAttempts = 0
        bootstrapIdentity()
        if let userId = identifiedUserId { identifyUser(userId: userId) }
        fetchInAppViews()
    }

    private func fetchInAppViews() {
        if !Thread.isMainThread { DispatchQueue.main.async { self.fetchInAppViews() }; return }
        guard initialized, UIApplication.shared.applicationState == .active,
              !hasFetchedInAppViewsThisSession else { return }
        let userId = resolveUserId()
        let customerId = resolveCustomerId()
        guard let request = makeCurrentInAppViewsRequest() else { return }
        hasFetchedInAppViewsThisSession = true
        let sessionId = inAppSessionId
        inAppFetchAttempts += 1
        dispatcher?.getJsonArray(request: request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.inAppSessionId == sessionId,
                      self.resolveUserId() == userId, self.resolveCustomerId() == customerId else { return }
                switch result {
                case .success(let array):
                    self.pendingInAppCustomerId = customerId
                    self.pendingInAppUserId = userId
                    self.pendingInAppViews = array.compactMap(InAppView.init).sorted {
                        $0.rule.priority == $1.rule.priority ? $0.id < $1.id : $0.rule.priority > $1.rule.priority
                    }
                    SdkLog.debug("Fetched \(self.pendingInAppViews.count) in-app views via API")
                    self.showNextInAppView()
                case .failure(let error):
                    SdkLog.error("In-app API fetch failed: \(error.localizedDescription)")
                    self.hasFetchedInAppViewsThisSession = false
                    let status = (error as NSError).code
                    if self.inAppFetchAttempts < 4 && (status == 409 || status == 408 || status == 429 ||
                        (500...599).contains(status) || (error as NSError).domain == NSURLErrorDomain) {
                        let delay = Double(self.inAppFetchAttempts) * 0.5
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self = self, self.inAppSessionId == sessionId else { return }
                            self.fetchInAppViews()
                        }
                    }
                }
            }
        }
    }

    private func showNextInAppView(attempt: Int = 0) {
        guard UIApplication.shared.applicationState == .active, !isWebViewShowing,
              !hasDisplayedInAppViewThisSession, !pendingInAppViews.isEmpty else { return }
        // Wait briefly for the host's first window or a dismissing modal to settle.
        guard let top = topViewController(), top.viewIfLoaded?.window != nil,
              !top.isBeingDismissed, !top.isBeingPresented, top.presentedViewController == nil else {
            if attempt < 10 {
                let sessionId = inAppSessionId
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if self.inAppSessionId == sessionId { self.showNextInAppView(attempt: attempt + 1) }
                }
            }
            return
        }
        let userId = resolveUserId()
        guard pendingInAppUserId == userId, pendingInAppCustomerId == resolveCustomerId() else { pendingInAppViews = []; return }
        while !pendingInAppViews.isEmpty {
            let view = pendingInAppViews.removeFirst()
            guard let variation = view.variation(for: resolveCustomerId()),
                  webViewQueueManager?.canDisplayWebView(
                    campaignId: view.campaignId, variationId: variation.id,
                    userId: resolveCustomerId(), rule: view.rule
                  ) == true else { continue }
            let delay = max(0, view.delaySeconds - Date().timeIntervalSince(inAppVisitStartedAt))
            if delay > 0 {
                pendingInAppViews.insert(view, at: 0)
                let session = inAppSessionId
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, self.inAppSessionId == session else { return }
                    self.showNextInAppView()
                }
                return
            }
            let controller = CampaignViewController(view: view, variation: variation, baseURL: apiUrl,
                userId: userId, customerId: resolveCustomerId())
            inAppController = controller
            controller.modalPresentationStyle = .overFullScreen
            controller.modalTransitionStyle = .crossDissolve
            isWebViewShowing = true
            hasDisplayedInAppViewThisSession = true
            top.present(controller, animated: true)
            return
        }
    }

    // MARK: - Misc

    @objc public func getQueueSize() -> Int { pendingInAppViews.count }
    @objc public func getWebViewQueueSize() -> Int { getQueueSize() }
    @objc public func clearWebViewQueue() -> Int {
        let count = pendingInAppViews.count + (webViewQueueManager?.clearQueue() ?? 0)
        pendingInAppViews = []
        pendingInAppUserId = nil
        pendingInAppCustomerId = nil
        inAppSessionId = UUID()
        return count
    }
    @objc public func clearAllWebViewData() -> Bool {
        _ = clearWebViewQueue()
        return webViewQueueManager?.clearAllData() ?? false
    }

    @objc public func getDisplayStats(campaignId: String, variationId: String) -> String {
        webViewQueueManager?.getDisplayStats(
            campaignId: campaignId, variationId: variationId, userId: resolveCustomerId()
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
