import Flutter
import Foundation
import UIKit
import UserNotifications

/// Flutter's iOS entry point for the native AlgorithmX SDK.
///
/// The native SDK sources are compiled into this plugin's module. This lets an
/// AppDelegate call `AlgorithmXFlutterPlugin.initializeForBackground` before
/// Dart starts, so an APNs background delivery can be handled on a cold start.
public final class AlgorithmXFlutterPlugin: NSObject, FlutterPlugin {
    private static let initializationLock = NSLock()
    private static var initializedApiBaseUrl: String?
    private static let callbacks = FlutterCallbackCoordinator()

    private let channel: FlutterMethodChannel
    private var isAttached = true

    private init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
        // The process-wide coordinator owns the weak native listener adapters.
        // Registration is earlier than Dart startup, so it buffers callbacks
        // until Dart calls initialize and its MethodChannel handler is ready.
        Self.callbacks.attach(self)
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "algorithmx_flutter/methods",
            binaryMessenger: registrar.messenger()
        )
        let plugin = AlgorithmXFlutterPlugin(channel: channel)
        registrar.addMethodCallDelegate(plugin, channel: channel)
        // FlutterAppDelegate only tells iOS it handles silent pushes when a plugin is
        // registered for them; without this, iOS never calls the host AppDelegate's
        // `didReceiveRemoteNotification` override and WebView campaigns never arrive.
        registrar.addApplicationDelegate(plugin)
    }

    /// Silent-push entry point for host apps that do not override
    /// `didReceiveRemoteNotification`. When the host AppDelegate overrides it (as in the
    /// integration guide) that override runs instead, so each push is handled once.
    public func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) -> Bool {
        AlgorithmX.shared.handleNotification(userInfo: userInfo) {
            completionHandler(.newData)
        }
        return true
    }

    /// Initializes the native SDK once, before Flutter's Dart isolate starts.
    ///
    /// Call this in the host AppDelegate's `didFinishLaunchingWithOptions` when
    /// silent APNs notifications must work on a cold start. Dart must later call
    /// `initialize` with the same URL; that second call is a no-op. Returning
    /// `false` means a different URL was already used during this process.
    /// Pass the `appGroup` shared with your Notification Service Extension so it
    /// can report delivered + impression (see the iOS integration guide).
    @discardableResult
    public static func initializeForBackground(apiBaseUrl: String, appGroup: String? = nil) -> Bool {
        let normalized = apiBaseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        initializationLock.lock()
        defer { initializationLock.unlock() }

        if let configured = initializedApiBaseUrl {
            let matches = configured == normalized
            if matches { callbacks.installNativeListeners() }
            return matches
        }
        if let appGroup = appGroup {
            AlgorithmX.shared.initialize(apiBaseUrl: normalized, appGroup: appGroup)
        } else {
            AlgorithmX.shared.initialize(apiBaseUrl: normalized)
        }
        initializedApiBaseUrl = normalized
        callbacks.installNativeListeners()
        return true
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        isAttached = false
        channel.setMethodCallHandler(nil)
        Self.callbacks.detach(self)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args: [String: Any]
        if call.arguments == nil {
            args = [:]
        } else if let map = call.arguments as? [String: Any] {
            args = map
        } else {
            result(argumentError("Arguments must be a map."))
            return
        }

        let sdk = AlgorithmX.shared
        switch call.method {
        case "initialize":
            guard let apiBaseUrl = requiredString(args, "apiBaseUrl", result) else { return }
            let normalized = apiBaseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                result(argumentError("apiBaseUrl must not be empty."))
                return
            }
            guard Self.initializeForBackground(apiBaseUrl: apiBaseUrl) else {
                result(FlutterError(
                    code: "already_initialized",
                    message: "AlgorithmX was already initialized with a different API base URL.",
                    details: nil
                ))
                return
            }
            result(nil)
            Self.callbacks.activate(self)

        case "setDeviceFingerprint":
            guard let fingerprint = requiredString(args, "fingerprint", result) else { return }
            sdk.setDeviceFingerprint(fingerprint)
            result(nil)

        case "getDeviceFingerprint":
            result(sdk.getDeviceFingerprint())

        case "identifyUser":
            guard let userId = requiredString(args, "userId", result) else { return }
            sdk.identifyUser(userId: userId, attributes: args["attributes"] as? [String: Any])
            result(nil)

        case "resetIdentity":
            sdk.resetIdentity()
            result(nil)

        case "trackEvent":
            guard let name = requiredString(args, "name", result) else { return }
            sdk.trackEvent(name, properties: args["properties"] as? [String: Any])
            result(nil)

        case "trackCampaignInteraction":
            guard let campaignId = requiredString(args, "campaignId", result),
                  let variationId = requiredString(args, "variationId", result),
                  let interactionType = requiredString(args, "interactionType", result)
            else { return }
            sdk.trackCampaignInteraction(
                campaignId: campaignId,
                variationId: variationId,
                interactionType: interactionType,
                payload: args["payload"] as? [String: Any],
                sessionId: args["sessionId"] as? String,
                endpoint: args["endpoint"] as? String
            )
            result(nil)

        case "updateNotificationStatus":
            guard let notificationId = (args["notificationId"] as? NSNumber)?.intValue,
                  let statusValue = (args["status"] as? NSNumber)?.intValue,
                  let status = AlgorithmX.NotificationEventStatus(rawValue: statusValue)
            else {
                result(argumentError("notificationId must be an integer and status must be 1...5."))
                return
            }
            sdk.updateNotificationStatus(
                notificationId: notificationId,
                status: status,
                errorMessage: args["errorMessage"] as? String
            )
            result(nil)

        case "registerDeviceToken":
            guard let token = requiredString(args, "token", result) else { return }
            sdk.registerDeviceToken(token)
            result(nil)

        case "handleNotification":
            guard let userInfo = requiredMap(args, "userInfo", result) else { return }
            sdk.handleNotification(userInfo: anyHashableMap(userInfo)) { result(nil) }

        case "handleNotificationResponse":
            guard let actionIdentifier = requiredString(args, "actionIdentifier", result),
                  let userInfo = requiredMap(args, "userInfo", result)
            else { return }
            sdk.handleNotificationResponse(
                actionIdentifier: actionIdentifier,
                userInfo: anyHashableMap(userInfo)
            ) { result(nil) }

        case "handleNotificationClick":
            guard let userInfo = requiredMap(args, "userInfo", result) else { return }
            sdk.handleNotificationClick(userInfo: anyHashableMap(userInfo))
            result(nil)

        case "openDeepLink":
            guard let urlString = requiredString(args, "url", result) else { return }
            guard URL(string: urlString) != nil else {
                result(argumentError("url must be a valid URL string."))
                return
            }
            // This call starts in Dart, so return the *actual* Dart handler
            // result. Calling the native synchronous listener would only
            // return the adapter's immediate acknowledgement (`true`).
            Self.callbacks.enqueueBoolean(
                "onDeepLink",
                arguments: ["url": urlString],
                onUnhandled: {},
                completion: { handled in result(handled) }
            )

        case "showWebView":
            guard let campaignId = requiredString(args, "campaignId", result),
                  let variationId = requiredString(args, "variationId", result),
                  let url = requiredString(args, "url", result)
            else { return }
            sdk.showWebView(
                campaignId: campaignId,
                variationId: variationId,
                url: url,
                dynamicContent: args["dynamicContent"] as? [String: Any]
            )
            result(nil)

        case "triggerWebView":
            guard let campaignId = requiredString(args, "campaignId", result),
                  let webviewUrl = requiredString(args, "webviewUrl", result)
            else { return }
            sdk.triggerWebView(
                campaignId: campaignId,
                webviewUrl: webviewUrl,
                dynamicContent: args["dynamicContent"] as? [String: Any]
            )
            result(nil)

        case "setWebViewShowing":
            guard let showing = args["showing"] as? Bool else {
                result(argumentError("showing must be a boolean."))
                return
            }
            sdk.setWebViewShowing(showing)
            result(nil)

        case "isWebViewCurrentlyShowing":
            result(sdk.isWebViewCurrentlyShowing())

        case "getQueueSize", "getWebViewQueueSize":
            result(sdk.getQueueSize())

        case "clearWebViewQueue":
            result(sdk.clearWebViewQueue())

        case "clearAllWebViewData":
            result(sdk.clearAllWebViewData())

        case "getDisplayStats":
            guard let campaignId = requiredString(args, "campaignId", result),
                  let variationId = requiredString(args, "variationId", result)
            else { return }
            result(sdk.getDisplayStats(campaignId: campaignId, variationId: variationId))

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func requiredString(
        _ args: [String: Any], _ key: String, _ result: FlutterResult
    ) -> String? {
        guard let value = args[key] as? String else {
            result(argumentError("\(key) must be a string."))
            return nil
        }
        return value
    }

    private func requiredMap(
        _ args: [String: Any], _ key: String, _ result: FlutterResult
    ) -> [String: Any]? {
        guard let value = args[key] as? [String: Any] else {
            result(argumentError("\(key) must be a map."))
            return nil
        }
        return value
    }

    private func argumentError(_ message: String) -> FlutterError {
        FlutterError(code: "invalid_arguments", message: message, details: nil)
    }

    private func anyHashableMap(_ map: [String: Any]) -> [AnyHashable: Any] {
        var result: [AnyHashable: Any] = [:]
        map.forEach { result[AnyHashable($0.key)] = $0.value }
        return result
    }

    // MARK: Process-wide callback coordinator -> Dart

    /// Called only after the coordinator sees a Dart `initialize` call. Keeping
    /// channel traffic here lets one process-wide listener survive engine
    /// recreation without retaining an old BinaryMessenger.
    fileprivate func sendToDart(
        _ method: String,
        arguments: [String: Any],
        reply: FlutterResult? = nil
    ) {
        guard isAttached else {
            reply?(FlutterMethodNotImplemented)
            return
        }
        let safeArguments = codecSafe(arguments)
        if let reply = reply {
            channel.invokeMethod(method, arguments: safeArguments, result: reply)
        } else {
            channel.invokeMethod(method, arguments: safeArguments)
        }
    }

    /// APNs dictionaries can contain Foundation values that Flutter's standard
    /// codec cannot encode. Convert them before crossing the platform channel.
    private func codecSafe(_ value: Any) -> Any {
        if value is NSNull { return NSNull() }
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value }
        if let value = value as? Data { return FlutterStandardTypedData(bytes: value) }
        if let value = value as? URL { return value.absoluteString }
        if let value = value as? Date { return ISO8601DateFormatter().string(from: value) }
        if let value = value as? [String: Any] {
            return value.mapValues { codecSafe($0) }
        }
        if let value = value as? [AnyHashable: Any] {
            var map: [String: Any] = [:]
            value.forEach { map[String(describing: $0.key)] = codecSafe($0.value) }
            return map
        }
        if let value = value as? [Any] { return value.map { codecSafe($0) } }
        return String(describing: value)
    }
}

/// Owns the SDK's weak listeners for the entire iOS process, including the
/// period before Flutter creates an engine. All queue state runs on the main
/// queue. A notification tap can be delayed briefly for Dart, but always gets
/// its normal native action if Dart never starts or does not claim it.
private final class FlutterCallbackCoordinator {
    private static let coldStartTimeout: TimeInterval = 30
    private static let dartReplyTimeout: TimeInterval = 5
    private static let maximumBufferedCallbacks = 100

    private final class PendingCallback {
        let id = UUID()
        let method: String
        let arguments: [String: Any]
        let onUnhandled: (() -> Void)?
        let completion: ((Bool) -> Void)?
        var sentGeneration: Int?

        var needsReply: Bool { onUnhandled != nil }

        init(
            method: String,
            arguments: [String: Any],
            onUnhandled: (() -> Void)? = nil,
            completion: ((Bool) -> Void)? = nil
        ) {
            self.method = method
            self.arguments = arguments
            self.onUnhandled = onUnhandled
            self.completion = completion
        }
    }

    private final class EngineEntry {
        weak var plugin: AlgorithmXFlutterPlugin?
        var dartReady = false
        init(plugin: AlgorithmXFlutterPlugin) { self.plugin = plugin }
    }

    // These five strong properties keep the native SDK's weak protocol
    // references alive even when no Flutter engine exists yet.
    private lazy var webViewListener = FlutterWebViewListener(coordinator: self)
    private lazy var notificationClickListener = FlutterNotificationClickListener(coordinator: self)
    private lazy var deepLinkHandler = FlutterDeepLinkHandler(coordinator: self)
    private lazy var actionButtonHandler = FlutterActionButtonHandler(coordinator: self)
    private lazy var campaignInteractionListener = FlutterCampaignInteractionListener(coordinator: self)

    // Weak references avoid retaining an engine that Flutter has removed.
    // The newest initialized engine receives callbacks; an older initialized
    // engine resumes automatically when the newer one detaches.
    private var engines: [EngineEntry] = []
    private var activePlugin: AlgorithmXFlutterPlugin? {
        engines.reversed().first(where: { $0.dartReady && $0.plugin != nil })?.plugin
    }
    private var dartReady: Bool { activePlugin != nil }
    private var deliveryGeneration = 0
    private var pending: [PendingCallback] = []
    fileprivate var forceNativeClickDefault = false

    func installNativeListeners() {
        let sdk = AlgorithmX.shared
        sdk.webViewListener = webViewListener
        sdk.notificationClickListener = notificationClickListener
        sdk.deepLinkHandler = deepLinkHandler
        sdk.actionButtonHandler = actionButtonHandler
        sdk.campaignInteractionListener = campaignInteractionListener
    }

    func attach(_ plugin: AlgorithmXFlutterPlugin) {
        onMain {
            self.engines.removeAll { $0.plugin == nil || $0.plugin === plugin }
            self.engines.append(EngineEntry(plugin: plugin))
            self.installNativeListeners()
        }
    }

    /// Dart installs its MethodChannel handler before it invokes initialize.
    /// Flushing at this point avoids losing callbacks to an engine that exists
    /// but has not yet started its Dart isolate.
    func activate(_ plugin: AlgorithmXFlutterPlugin) {
        onMain {
            let previous = self.activePlugin
            guard let entry = self.engines.first(where: { $0.plugin === plugin }) else { return }
            entry.dartReady = true
            if previous !== self.activePlugin { self.changeDeliveryGeneration() }
            self.flush()
        }
    }

    func detach(_ plugin: AlgorithmXFlutterPlugin) {
        onMain {
            let previous = self.activePlugin
            self.engines.removeAll { $0.plugin == nil || $0.plugin === plugin }
            if previous !== self.activePlugin { self.changeDeliveryGeneration() }
            // Keep the adapters installed for the next background APNs event.
            self.installNativeListeners()
            self.flush()
        }
    }

    private func changeDeliveryGeneration() {
        deliveryGeneration += 1
        // Callbacks waiting on a removed/replaced engine can be delivered to
        // the next ready engine. Their original cold-start timer still bounds
        // how long the notification action may be delayed in total.
        pending.forEach { $0.sentGeneration = nil }
    }

    fileprivate func enqueueVoid(_ method: String, arguments: [String: Any]) {
        onMain {
            self.append(PendingCallback(method: method, arguments: arguments))
            self.flush()
        }
    }

    fileprivate func enqueueBoolean(
        _ method: String,
        arguments: [String: Any],
        onUnhandled: @escaping () -> Void,
        completion: ((Bool) -> Void)? = nil
    ) {
        onMain {
            let callback = PendingCallback(
                method: method,
                arguments: arguments,
                onUnhandled: onUnhandled,
                completion: completion
            )
            self.append(callback)
            // The cold-start timer starts when the native tap arrives, even
            // when no Flutter engine is attached. A late Dart reply cannot
            // perform a second action after this timeout resolves the item.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.coldStartTimeout) {
                self.finish(callback.id, handled: false)
            }
            self.flush()
        }
    }

    private func append(_ callback: PendingCallback) {
        if pending.count >= Self.maximumBufferedCallbacks {
            let evicted = pending.removeFirst()
            if evicted.needsReply { resolve(evicted, handled: false) }
        }
        pending.append(callback)
    }

    private func flush() {
        guard dartReady, let plugin = activePlugin else { return }
        let generation = deliveryGeneration
        // Snapshot the array because a callback may synchronously reply or
        // cause another SDK event while we deliver the older callbacks.
        for callback in pending {
            guard pending.contains(where: { $0.id == callback.id }) else { continue }
            if callback.needsReply {
                guard callback.sentGeneration == nil else { continue }
                callback.sentGeneration = generation
                plugin.sendToDart(callback.method, arguments: callback.arguments) { [weak self] reply in
                    self?.onMain {
                        self?.finish(
                            callback.id,
                            handled: (reply as? Bool) == true,
                            generation: generation
                        )
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.dartReplyTimeout) {
                    self.finish(callback.id, handled: false, generation: generation)
                }
            } else {
                pending.removeAll { $0.id == callback.id }
                plugin.sendToDart(callback.method, arguments: callback.arguments)
            }
        }
    }

    private func finish(_ id: UUID, handled: Bool, generation: Int? = nil) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let callback = pending[index]
        if let generation = generation, callback.sentGeneration != generation { return }
        pending.remove(at: index)
        resolve(callback, handled: handled)
    }

    private func resolve(_ callback: PendingCallback, handled: Bool) {
        if !handled { callback.onUnhandled?() }
        callback.completion?(handled)
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// A button's `false` path enters the SDK click router once. If Dart never
    /// attached, let that click use the native route immediately instead of
    /// buffering it for another 30 seconds. Its open/click tracking still runs
    /// exactly once inside `handleNotificationClick`.
    fileprivate func handleUnclaimedButton(_ data: [String: Any]) {
        var userInfo: [AnyHashable: Any] = [:]
        data.forEach { userInfo[AnyHashable($0.key)] = $0.value }
        let needsImmediateDefault = !dartReady || activePlugin == nil
        if needsImmediateDefault { forceNativeClickDefault = true }
        AlgorithmX.shared.handleNotificationClick(userInfo: userInfo)
        if needsImmediateDefault { forceNativeClickDefault = false }
    }

    /// The SDK already recorded opened status and a campaign click before it
    /// called our notification listener. This method copies only its default
    /// action switch; calling `handleNotificationClick` here would double count.
    fileprivate func routeDefaultNotificationAction(data: [String: Any]) {
        let actionData = parseActionData(data["actionData"] as? String)
        switch data["action_type"] as? String {
        case "open_web_page":
            guard let raw = actionData["url"] as? String,
                  let url = URL(string: raw) else { return }
            UIApplication.shared.open(url)

        case "open_webview":
            guard let url = actionData["url"] as? String,
                  let campaignId = data["algo_campaign_id"] as? String else { return }
            AlgorithmX.shared.showWebView(
                campaignId: campaignId,
                variationId: data["engage_variation_id"] as? String ?? "default",
                url: url,
                dynamicContent: nil
            )

        case "open_screen":
            guard let raw = actionData["deepLink"] as? String,
                  let url = URL(string: raw) else { return }
            _ = AlgorithmX.shared.openDeepLink(url: url)

        case "custom_action":
            var enriched = data
            enriched["parsedActionData"] = actionData
            enqueueBoolean(
                "onCustomAction",
                arguments: ["action": actionData["action"] ?? NSNull(), "data": enriched],
                onUnhandled: {}
            )

        default:
            break
        }
    }

    private func parseActionData(_ raw: String?) -> [String: Any] {
        guard let raw = raw, !raw.isEmpty, raw != "{}",
              let data = raw.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return map
    }
}

private final class FlutterWebViewListener: NSObject, AlgoWebViewListener {
    weak var coordinator: FlutterCallbackCoordinator?
    init(coordinator: FlutterCallbackCoordinator) { self.coordinator = coordinator }

    func onWebViewTrigger(campaignId: String, webviewUrl: String, dynamicContent: [String: Any]?) {
        coordinator?.enqueueVoid("onWebViewTrigger", arguments: [
            "campaignId": campaignId,
            "webviewUrl": webviewUrl,
            "dynamicContent": dynamicContent ?? NSNull()
        ])
    }
}

private final class FlutterNotificationClickListener: NSObject, NotificationClickListener {
    weak var coordinator: FlutterCallbackCoordinator?
    init(coordinator: FlutterCallbackCoordinator) { self.coordinator = coordinator }

    func onNotificationClick(data: [String: Any]) -> Bool {
        guard let coordinator = coordinator else { return false }
        if coordinator.forceNativeClickDefault { return false }
        coordinator.enqueueBoolean("onNotificationClick", arguments: ["data": data]) {
            [weak coordinator] in coordinator?.routeDefaultNotificationAction(data: data)
        }
        return true
    }

    func onCustomAction(action: String?, data: [String: Any]) -> Bool {
        guard let coordinator = coordinator else { return false }
        coordinator.enqueueBoolean("onCustomAction", arguments: [
            "action": action ?? NSNull(), "data": data
        ], onUnhandled: {})
        return true
    }

    func onActionHandled(action: String, data: [String: Any]) {
        coordinator?.enqueueVoid("onActionHandled", arguments: ["action": action, "data": data])
    }
}

private final class FlutterDeepLinkHandler: NSObject, DeepLinkHandler {
    weak var coordinator: FlutterCallbackCoordinator?
    init(coordinator: FlutterCallbackCoordinator) { self.coordinator = coordinator }

    func onDeepLinkReceived(url: URL) -> Bool {
        guard let coordinator = coordinator else { return false }
        // The native SDK has no default navigation for an unclaimed deep link.
        coordinator.enqueueBoolean(
            "onDeepLink", arguments: ["url": url.absoluteString], onUnhandled: {}
        )
        return true
    }
}

private final class FlutterActionButtonHandler: NSObject, ActionButtonHandler {
    weak var coordinator: FlutterCallbackCoordinator?
    init(coordinator: FlutterCallbackCoordinator) { self.coordinator = coordinator }

    func onActionButtonClicked(
        buttonId: String,
        actionText: String,
        title: String,
        notificationData: [String: Any]
    ) -> Bool {
        guard let coordinator = coordinator else { return false }
        coordinator.enqueueBoolean("onActionButtonClicked", arguments: [
            "buttonId": buttonId,
            "actionText": actionText,
            "title": title,
            "notificationData": notificationData
        ]) { [weak coordinator] in
            coordinator?.handleUnclaimedButton(notificationData)
        }
        return true
    }
}

private final class FlutterCampaignInteractionListener: NSObject, CampaignInteractionListener {
    weak var coordinator: FlutterCallbackCoordinator?
    init(coordinator: FlutterCallbackCoordinator) { self.coordinator = coordinator }

    func onCampaignInteraction(
        campaignId: String,
        variationId: String,
        interactionType: String,
        payload: [String: Any]
    ) {
        coordinator?.enqueueVoid("onCampaignInteraction", arguments: [
            "campaignId": campaignId,
            "variationId": variationId,
            "interactionType": interactionType,
            "payload": payload
        ])
    }
}
