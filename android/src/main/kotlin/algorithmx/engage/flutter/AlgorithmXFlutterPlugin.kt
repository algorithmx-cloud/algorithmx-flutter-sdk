package algorithmx.engage.flutter

import algorithmx.engage.core.AlgorithmX
import algorithmx.engage.activities.NotificationClickActivity
import algorithmx.engage.interfaces.ActionButtonHandler
import algorithmx.engage.interfaces.AlgoWebViewListener
import algorithmx.engage.interfaces.CampaignInteractionListener
import algorithmx.engage.interfaces.DeepLinkHandler
import algorithmx.engage.interfaces.NotificationClickListener
import algorithmx.engage.utils.JsonUtil
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Flutter's Android adapter for the bundled native [AlgorithmX] SDK.
 *
 * The channel is bidirectional. Dart calls the methods handled by [onMethodCall],
 * and this class invokes Dart methods named `onNotificationClick`,
 * `onCampaignInteraction`, etc. All arguments are named maps, so adding an
 * optional field does not change positional argument order.
 *
 * The SDK stays process-wide. A host [android.app.Service] can call
 * [initializeForBackground] before forwarding an FCM message, even when no
 * Flutter engine exists. Dart's later `initialize` call uses the same helper,
 * preserving the pending campaign queue and current identity.
 */
class AlgorithmXFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware, Application.ActivityLifecycleCallbacks,
    AlgoWebViewListener, NotificationClickListener, DeepLinkHandler,
    ActionButtonHandler, CampaignInteractionListener {

    companion object {
        private const val TAG = "AlgorithmXFlutter"
        private const val CHANNEL = "algorithmx_flutter/methods"
        private const val COLD_START_TIMEOUT_MS = 30_000L
        private const val DART_REPLY_TIMEOUT_MS = 5_000L
        private const val MAX_PENDING_CALLBACKS = 100

        private val initializationLock = Any()
        private val callbackLock = Any()
        private val callbackHandler = Handler(Looper.getMainLooper())
        private var nativeInitialized = false
        private var initializedApiUrl: String? = null
        private var backgroundApplication: Application? = null
        // Multiple Flutter engines may initialize this process-wide SDK. The
        // latest ready engine receives callbacks; when it detaches, an earlier
        // ready engine resumes without needing another initialize call.
        private val readyPlugins = mutableListOf<AlgorithmXFlutterPlugin>()
        @Volatile private var activePlugin: AlgorithmXFlutterPlugin? = null
        @Volatile private var dartReady = false

        /** A callback captured before Flutter's Dart method handler is ready. */
        private data class PendingCallback(
            val method: String,
            val payload: Map<String, Any?>,
            val clickData: Map<String, Any>? = null
        )

        private val pendingCallbacks = ArrayDeque<PendingCallback>()

        /**
         * The native singleton holds this process-wide listener, not a Flutter
         * engine instance. NotificationClickActivity can therefore deliver a
         * tap while the app is being launched and before Dart starts.
         */
        private val callbackProxy = object : AlgoWebViewListener, NotificationClickListener,
            DeepLinkHandler, ActionButtonHandler, CampaignInteractionListener {

            override fun onWebViewTrigger(
                campaignId: String, webviewUrl: String, dynamicContent: Map<String, Any>?
            ) {
                val plugin = activePlugin?.takeIf { dartReady }
                if (plugin != null) plugin.onWebViewTrigger(campaignId, webviewUrl, dynamicContent)
                else enqueue(PendingCallback("onWebViewTrigger", mapOf(
                    "campaignId" to campaignId,
                    "webviewUrl" to webviewUrl,
                    "dynamicContent" to portable(dynamicContent)
                )))
            }

            override fun onNotificationClick(data: Map<String, Any>): Boolean {
                val plugin = activePlugin?.takeIf { dartReady }
                if (plugin != null) return plugin.onNotificationClick(data)
                enqueue(PendingCallback(
                    "onNotificationClick", mapOf("data" to portable(data)), data.toMap()
                ))
                // The SDK already recorded OPENED/click. Defer its action until
                // Dart replies or the bounded startup timeout expires.
                return true
            }

            override fun onCustomAction(action: String?, data: Map<String, Any>): Boolean {
                val plugin = activePlugin?.takeIf { dartReady }
                if (plugin != null) return plugin.onCustomAction(action, data)
                enqueue(PendingCallback("onCustomAction", mapOf(
                    "action" to action, "data" to portable(data)
                )))
                return true
            }

            override fun onActionHandled(action: String, data: Map<String, Any>) {
                val plugin = activePlugin?.takeIf { dartReady }
                if (plugin != null) plugin.onActionHandled(action, data)
                else enqueue(PendingCallback("onActionHandled", mapOf(
                    "action" to action, "data" to portable(data)
                )))
            }

            override fun onDeepLinkReceived(uri: Uri): Boolean {
                val plugin = activePlugin?.takeIf { dartReady }
                if (plugin != null) return plugin.onDeepLinkReceived(uri)
                enqueue(PendingCallback("onDeepLink", mapOf("url" to uri.toString())))
                return true
            }

            override fun onActionButtonClicked(
                buttonId: String, actionText: String, title: String,
                notificationData: Map<String, Any>
            ): Boolean {
                val plugin = activePlugin?.takeIf { dartReady }
                if (plugin != null) return plugin.onActionButtonClicked(
                    buttonId, actionText, title, notificationData
                )
                enqueue(PendingCallback("onActionButtonClicked", mapOf(
                    "buttonId" to buttonId,
                    "actionText" to actionText,
                    "title" to title,
                    "notificationData" to portable(notificationData)
                )))
                return true
            }

            override fun onCampaignInteraction(
                campaignId: String, variationId: String,
                interactionType: String, payload: Map<String, Any>
            ) {
                val plugin = activePlugin?.takeIf { dartReady }
                if (plugin != null) plugin.onCampaignInteraction(
                    campaignId, variationId, interactionType, payload
                ) else enqueue(PendingCallback("onCampaignInteraction", mapOf(
                    "campaignId" to campaignId,
                    "variationId" to variationId,
                    "interactionType" to interactionType,
                    "payload" to portable(payload)
                )))
            }
        }

        private fun installProcessListeners() {
            AlgorithmX.setAlgoWebViewListener(callbackProxy)
            AlgorithmX.setNotificationClickListener(callbackProxy)
            AlgorithmX.setDeepLinkHandler(callbackProxy)
            AlgorithmX.setActionButtonHandler(callbackProxy)
            AlgorithmX.setCampaignInteractionListener(callbackProxy)
        }

        private fun removeProcessListeners() {
            AlgorithmX.removeAlgoWebViewListener()
            AlgorithmX.removeNotificationClickListener()
            AlgorithmX.removeDeepLinkHandler()
            AlgorithmX.removeActionButtonHandler()
            AlgorithmX.removeCampaignInteractionListener()
        }

        /** Queue events briefly; a timed-out click takes its native default. */
        private fun enqueue(callback: PendingCallback) {
            val evicted = synchronized(callbackLock) {
                val oldest = if (pendingCallbacks.size >= MAX_PENDING_CALLBACKS)
                    pendingCallbacks.removeFirst() else null
                pendingCallbacks.addLast(callback)
                oldest
            }
            evicted?.clickData?.let(::applyClickDefault)
            if (callback.clickData != null) {
                callbackHandler.postDelayed({
                    val expired = synchronized(callbackLock) { pendingCallbacks.remove(callback) }
                    if (expired) applyClickDefault(callback.clickData)
                }, COLD_START_TIMEOUT_MS)
            }
        }

        private fun applyClickDefault(data: Map<String, Any>) {
            val context = backgroundApplication ?: return
            callbackHandler.post {
                routeDefaultNotificationAction(context, data) { action, actionData ->
                    callbackProxy.onCustomAction(action, actionData)
                }
            }
        }

        /** Deliver startup callbacks after Dart has installed its handler. */
        private fun activate(plugin: AlgorithmXFlutterPlugin) {
            synchronized(callbackLock) {
                readyPlugins.remove(plugin)
                readyPlugins.add(plugin)
                activePlugin = plugin
                dartReady = false
            }
            // Keep the proxy in buffering mode until the backlog is drained.
            // A concurrent push cannot jump ahead of an older cold-start tap.
            while (true) {
                val callbacks = synchronized(callbackLock) {
                    if (activePlugin !== plugin) return
                    if (pendingCallbacks.isEmpty()) {
                        dartReady = true
                        return
                    }
                    pendingCallbacks.toList().also { pendingCallbacks.clear() }
                }
                callbacks.forEach { callback ->
                    val data = callback.clickData
                    if (data != null) plugin.onNotificationClick(data)
                    else plugin.emit(callback.method, callback.payload)
                }
            }
        }

        private fun deactivate(plugin: AlgorithmXFlutterPlugin) {
            val fallback: AlgorithmXFlutterPlugin?
            val callbacks: List<PendingCallback>
            synchronized(callbackLock) {
                readyPlugins.remove(plugin)
                if (activePlugin !== plugin) return
                fallback = readyPlugins.lastOrNull()
                activePlugin = fallback
                dartReady = fallback != null
                callbacks = if (fallback != null) {
                    pendingCallbacks.toList().also { pendingCallbacks.clear() }
                } else emptyList()
            }
            if (fallback != null) {
                callbacks.forEach { callback ->
                    val data = callback.clickData
                    if (data != null) fallback.onNotificationClick(data)
                    else fallback.emit(callback.method, callback.payload)
                }
            }
        }

        /**
         * Initialize the native SDK from a FirebaseMessagingService before
         * `AlgorithmX.handleFcmMessage` or `registerDeviceToken` is called.
         *
         * This is safe to call again with the same URL. The Flutter `initialize`
         * method also calls it, so it will not reset an identified user when a
         * background message started the process first. Use the same API URL in
         * native and Dart startup code. No Flutter engine or Activity is needed.
         */
        @JvmStatic
        fun initializeForBackground(application: Application, apiBaseUrl: String) {
            val normalizedUrl = apiBaseUrl.trimEnd('/')
            require(normalizedUrl.isNotBlank()) { "apiBaseUrl must not be blank" }
            synchronized(initializationLock) {
                backgroundApplication = application
                if (nativeInitialized) {
                    require(initializedApiUrl == normalizedUrl) {
                        "AlgorithmX is already initialized with a different apiBaseUrl"
                    }
                    installProcessListeners()
                    return
                }
                AlgorithmX.initialize(application, normalizedUrl)
                initializedApiUrl = normalizedUrl
                nativeInitialized = true
                installProcessListeners()
            }
        }

        /** True once the native singleton has been initialized in this process. */
        @JvmStatic
        fun isInitialized(): Boolean = synchronized(initializationLock) { nativeInitialized }

        private fun destroyNative() {
            val pendingClicks = synchronized(callbackLock) {
                readyPlugins.clear()
                activePlugin = null
                dartReady = false
                pendingCallbacks.mapNotNull { it.clickData }.also { pendingCallbacks.clear() }
            }
            pendingClicks.forEach(::applyClickDefault)
            synchronized(initializationLock) {
                removeProcessListeners()
                if (nativeInitialized) AlgorithmX.destroy()
                nativeInitialized = false
                initializedApiUrl = null
                backgroundApplication = null
            }
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var application: Application? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    // A set avoids miscounting the Activity that was already started before
    // Flutter attached, and survives Activity recreation during rotation.
    private val startedActivities = mutableSetOf<Activity>()
    private var foregroundWasReported = false

    /** Flutter's Activity binding reports intents delivered to a running app. */
    private val newIntentListener = PluginRegistry.NewIntentListener { intent ->
        activity?.let { AlgorithmX.handleNewIntent(it, intent) }
        false // Other Flutter plugins may also need the same intent.
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val app = binding.applicationContext as? Application
            ?: error("AlgorithmX requires an Android Application context")
        application = app
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        app.registerActivityLifecycleCallbacks(this)
        // The process-wide proxy already buffers callbacks from a native FCM
        // service. We wait for Dart's initialize call before flushing them.
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Switch the process proxy back to buffering before clearing fields.
        deactivate(this)
        detachFromActivity()
        application?.unregisterActivityLifecycleCallbacks(this)
        application = null
        channel?.setMethodCallHandler(null)
        channel = null
        // Keep the SDK and proxy alive for background FCM delivery. A tap that
        // arrives between Flutter engines can still reach the next Dart isolate.
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addOnNewIntentListener(newIntentListener)
        // The Activity may already have started before this plugin attached.
        // A posted check runs after its current onCreate/onStart stack, so we
        // handle both fresh starts and attachment to an existing Activity.
        mainHandler.post {
            if (activity === binding.activity && !binding.activity.isFinishing) {
                startedActivities.add(binding.activity)
                reportForegroundIfNeeded(binding.activity)
            }
        }
    }

    override fun onDetachedFromActivityForConfigChanges() = detachFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)
    override fun onDetachedFromActivity() = detachFromActivity()

    private fun detachFromActivity() {
        activityBinding?.removeOnNewIntentListener(newIntentListener)
        activityBinding = null
        activity = null
    }

    /**
     * Translate one Dart method call to its native counterpart. A platform
     * error is returned for malformed input, rather than allowing a cast or
     * missing field to crash the Android process.
     */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            val args = Arguments(call)
            when (call.method) {
                "initialize" -> {
                    initializeForBackground(requiredApplication(), args.string("apiBaseUrl"))
                    activate(this)
                    activity?.let(::reportForegroundIfNeeded)
                    result.success(null)
                }
                "destroy" -> {
                    deactivate(this)
                    destroyNative()
                    foregroundWasReported = false
                    result.success(null)
                }
                "setDeviceFingerprint" -> {
                    AlgorithmX.setDeviceFingerprint(args.string("fingerprint"))
                    result.success(null)
                }
                "getDeviceFingerprint" -> result.success(AlgorithmX.getDeviceFingerprint())
                "identifyUser" -> {
                    AlgorithmX.identifyUser(args.string("userId"), args.optionalMap("attributes"))
                    result.success(null)
                }
                "resetIdentity" -> {
                    AlgorithmX.resetIdentity()
                    result.success(null)
                }
                "trackEvent" -> {
                    AlgorithmX.trackEvent(args.string("name"), args.optionalMap("properties"))
                    result.success(null)
                }
                "trackCampaignInteraction" -> {
                    AlgorithmX.trackCampaignInteraction(
                        args.string("campaignId"), args.string("variationId"),
                        args.string("interactionType"), args.optionalMap("payload"),
                        args.optionalString("sessionId"), args.optionalString("endpoint")
                    )
                    result.success(null)
                }
                "updateNotificationStatus" -> {
                    val statusValue = args.int("status")
                    val status = AlgorithmX.NotificationEventStatus.values()
                        .firstOrNull { it.value == statusValue }
                        ?: throw IllegalArgumentException("Unknown notification status: $statusValue")
                    AlgorithmX.updateNotificationStatus(
                        args.int("notificationId"), status, args.optionalString("errorMessage")
                    )
                    result.success(null)
                }
                "registerDeviceToken" -> {
                    AlgorithmX.registerDeviceToken(args.string("token"))
                    result.success(null)
                }
                "handleFcmMessage" -> {
                    AlgorithmX.handleFcmMessage(
                        requiredContext(), args.stringMap("data"),
                        args.optionalString("notificationTitle"),
                        args.optionalString("notificationBody")
                    )
                    result.success(null)
                }
                "processNormalNotification" -> {
                    AlgorithmX.processNormalNotification(
                        requiredContext(), args.stringMap("data"),
                        args.optionalString("title"), args.optionalString("body")
                    )
                    result.success(null)
                }
                "processSilentNotification" -> {
                    AlgorithmX.processSilentNotification(requiredContext(), args.stringMap("data"))
                    result.success(null)
                }
                "showWebView" -> {
                    AlgorithmX.showWebView(
                        requiredContext(), args.string("campaignId"),
                        args.string("variationId"), args.string("url"),
                        args.optionalMap("dynamicContent") ?: emptyMap(),
                        args.optionalLong("expiresAt") ?: 0L
                    )
                    result.success(null)
                }
                "triggerWebView" -> {
                    AlgorithmX.triggerWebView(
                        requiredContext(), args.string("campaignId"),
                        args.string("webviewUrl"),
                        args.optionalMap("dynamicContent") ?: emptyMap()
                    )
                    result.success(null)
                }
                "setWebViewShowing" -> {
                    AlgorithmX.setWebViewShowing(args.boolean("showing"))
                    result.success(null)
                }
                "isWebViewCurrentlyShowing" -> result.success(AlgorithmX.isWebViewCurrentlyShowing())
                "onAppBecameActive" -> {
                    AlgorithmX.onAppBecameActive(activity ?: requiredContext())
                    result.success(null)
                }
                "onAppWentBackground" -> {
                    AlgorithmX.onAppWentBackground()
                    result.success(null)
                }
                "recordWebViewDisplaySuccess" -> {
                    AlgorithmX.recordWebViewDisplaySuccess(
                        args.string("campaignId"), args.string("variationId"),
                        args.optionalLong("expiresAt") ?: 0L
                    )
                    result.success(null)
                }
                "openDeepLink" -> {
                    // The native method only invokes a synchronous delegate.
                    // For a Dart-originated call, wait for Dart's bool reply so
                    // this method has the same useful meaning in Flutter.
                    val url = args.string("url")
                    Uri.parse(url)
                    invokeDartBoolean("onDeepLink", mapOf("url" to url)) {
                        result.success(it)
                    }
                }
                "handleActionButtonClick" -> {
                    AlgorithmX.handleActionButtonClick(
                        requiredContext(), args.string("buttonId"),
                        args.string("actionText"), args.string("title"),
                        args.optionalMap("notificationData") ?: emptyMap()
                    )
                    result.success(null)
                }
                "handleIntent" -> {
                    val current = requiredActivity()
                    AlgorithmX.handleIntent(current, current.intent)
                    result.success(null)
                }
                "handleNewIntent" -> {
                    val current = requiredActivity()
                    AlgorithmX.handleNewIntent(current, current.intent)
                    result.success(null)
                }
                "getQueueSize" -> result.success(AlgorithmX.getQueueSize())
                "getWebViewQueueSize" -> result.success(AlgorithmX.getWebViewQueueSize())
                "clearWebViewQueue" -> result.success(AlgorithmX.clearWebViewQueue())
                "clearAllWebViewData" -> result.success(AlgorithmX.clearAllWebViewData())
                "getDisplayStats" -> result.success(AlgorithmX.getDisplayStats(
                    args.string("campaignId"), args.string("variationId")
                ))
                "setSmallIcon" -> {
                    AlgorithmX.setSmallIcon(args.int("resourceId"))
                    result.success(null)
                }
                "getSmallIconResId" -> result.success(AlgorithmX.getSmallIconResId())
                else -> result.notImplemented()
            }
        } catch (error: IllegalArgumentException) {
            result.error("INVALID_ARGUMENT", error.message, null)
        } catch (error: IllegalStateException) {
            result.error("INVALID_STATE", error.message, null)
        } catch (error: Exception) {
            Log.e(TAG, "Failed to handle ${call.method}", error)
            result.error("NATIVE_ERROR", error.message, null)
        }
    }

    private fun requiredApplication(): Application =
        application ?: throw IllegalStateException("Flutter engine is not attached")

    private fun requiredContext(): Context =
        application ?: throw IllegalStateException("Flutter engine is not attached")

    private fun requiredActivity(): Activity =
        activity ?: throw IllegalStateException("No foreground Activity is attached")

    /**
     * The native queue displays at most one campaign in a foreground session.
     * Android's own lifecycle manager processes notification intents but does
     * not call `onAppBecameActive`; this plugin therefore does it explicitly.
     */
    private fun reportForegroundIfNeeded(context: Context) {
        if (!isInitialized() || foregroundWasReported) return
        foregroundWasReported = true
        AlgorithmX.onAppBecameActive(context)
    }

    override fun onActivityStarted(activity: Activity) {
        // The transparent click trampoline is not the partner's foreground UI.
        if (activity is NotificationClickActivity) return
        startedActivities.add(activity)
        reportForegroundIfNeeded(activity)
    }

    override fun onActivityStopped(activity: Activity) {
        startedActivities.remove(activity)
        if (startedActivities.isEmpty() && foregroundWasReported) {
            foregroundWasReported = false
            AlgorithmX.onAppWentBackground()
        }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) {
        startedActivities.remove(activity)
        if (startedActivities.isEmpty() && foregroundWasReported) {
            foregroundWasReported = false
            AlgorithmX.onAppWentBackground()
        }
    }

    /**
     * Invoke a Dart callback and complete with its Boolean reply. Native
     * notification listeners are synchronous, so they return immediately and
     * this result is used later for the plugin's local default action. A timeout
     * also supplies `false` if Dart has no listener or never responds.
     */
    private fun invokeDartBoolean(
        method: String, payload: Map<String, Any?>, completion: (Boolean) -> Unit
    ): Boolean {
        val activeChannel = channel ?: run { completion(false); return false }
        val completed = AtomicBoolean(false)
        val finish: (Boolean) -> Unit = { handled ->
            if (completed.compareAndSet(false, true)) completion(handled)
        }
        mainHandler.post {
            if (channel !== activeChannel) {
                finish(false)
                return@post
            }
            val timeout = Runnable { finish(false) }
            mainHandler.postDelayed(timeout, DART_REPLY_TIMEOUT_MS)
            try {
                activeChannel.invokeMethod(method, payload, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        mainHandler.removeCallbacks(timeout)
                        finish(result == true)
                    }
                    override fun error(code: String, message: String?, details: Any?) {
                        Log.w(TAG, "Dart $method callback failed: $code $message")
                        mainHandler.removeCallbacks(timeout)
                        finish(false)
                    }
                    override fun notImplemented() {
                        mainHandler.removeCallbacks(timeout)
                        finish(false)
                    }
                })
            } catch (error: Exception) {
                mainHandler.removeCallbacks(timeout)
                Log.e(TAG, "Could not invoke Dart $method callback", error)
                finish(false)
            }
        }
        return true
    }

    /** Fire-and-forget native event; Dart may omit its handler. */
    private fun emit(method: String, payload: Map<String, Any?>) {
        mainHandler.post { channel?.invokeMethod(method, payload) }
    }

    override fun onWebViewTrigger(
        campaignId: String, webviewUrl: String, dynamicContent: Map<String, Any>?
    ) = emit("onWebViewTrigger", mapOf(
        "campaignId" to campaignId,
        "webviewUrl" to webviewUrl,
        "dynamicContent" to portable(dynamicContent)
    ))

    override fun onNotificationClick(data: Map<String, Any>): Boolean {
        val context = application ?: return false
        // AlgorithmX's router already recorded OPENED and campaign click before
        // invoking us. Return true now to prevent immediate default routing.
        // If Dart declines, execute only the action (never track a second time).
        invokeDartBoolean("onNotificationClick", mapOf("data" to portable(data))) { handled ->
            if (!handled) routeDefaultNotificationAction(context, data) { action, actionData ->
                onCustomAction(action, actionData)
            }
        }
        return true
    }

    override fun onCustomAction(action: String?, data: Map<String, Any>): Boolean {
        invokeDartBoolean("onCustomAction", mapOf(
            "action" to action, "data" to portable(data)
        )) { /* The native router has no further custom-action fallback. */ }
        return true
    }

    override fun onActionHandled(action: String, data: Map<String, Any>) {
        emit("onActionHandled", mapOf("action" to action, "data" to portable(data)))
    }

    override fun onDeepLinkReceived(uri: Uri): Boolean {
        // The native SDK has no URL-opening fallback for deep links; navigation
        // belongs to the Flutter host application.
        return invokeDartBoolean("onDeepLink", mapOf("url" to uri.toString())) { }
    }

    override fun onActionButtonClicked(
        buttonId: String, actionText: String, title: String,
        notificationData: Map<String, Any>
    ): Boolean {
        invokeDartBoolean("onActionButtonClicked", mapOf(
            "buttonId" to buttonId,
            "actionText" to actionText,
            "title" to title,
            "notificationData" to portable(notificationData)
        )) { /* Native SDK ignores this handler's Boolean return value. */ }
        return true
    }

    override fun onCampaignInteraction(
        campaignId: String, variationId: String,
        interactionType: String, payload: Map<String, Any>
    ) = emit("onCampaignInteraction", mapOf(
        "campaignId" to campaignId,
        "variationId" to variationId,
        "interactionType" to interactionType,
        "payload" to portable(payload)
    ))

}

/**
 * Apply the native router's action semantics after Dart declines a click.
 * NotificationActionRouter.route cannot be called again: it would record
 * OPENED and click twice and invoke onNotificationClick a second time.
 */
private fun routeDefaultNotificationAction(
    context: Context, data: Map<String, Any>,
    onCustomAction: (String?, Map<String, Any>) -> Unit
) {
    val actionData = try {
        @Suppress("UNCHECKED_CAST")
        JsonUtil.fromJson(data["actionData"] as? String ?: "{}") as? Map<String, Any>
            ?: emptyMap()
    } catch (error: Exception) {
        Log.w("AlgorithmXFlutter", "Malformed notification actionData", error)
        emptyMap()
    }
    try {
        when (data["action_type"] as? String) {
            "open_web_page" -> {
                val url = actionData["url"] as? String
                if (!url.isNullOrEmpty()) context.startActivity(
                    Intent(Intent.ACTION_VIEW, Uri.parse(url))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }
            "open_webview" -> {
                val url = actionData["url"] as? String
                val campaignId = data["algo_campaign_id"] as? String
                if (!url.isNullOrEmpty() && !campaignId.isNullOrEmpty()) {
                    AlgorithmX.showWebView(
                        context, campaignId,
                        data["engage_variation_id"] as? String ?: "default", url,
                        emptyMap() // Native CampaignActivity requires non-null content.
                    )
                }
            }
            "open_screen" -> {
                val url = actionData["deepLink"] as? String
                if (!url.isNullOrEmpty()) AlgorithmX.openDeepLink(context, url)
            }
            "custom_action" -> {
                onCustomAction(
                    actionData["action"] as? String,
                    data + ("parsedActionData" to actionData)
                )
            }
            // Standard and unknown actions require no further SDK work.
        }
    } catch (error: Exception) {
        Log.e("AlgorithmXFlutter", "Default notification action failed", error)
    }
}

/**
 * Checked accessor for the named argument map used by every Dart API method.
 * Flutter's standard codec represents numbers as Int or Long and dictionaries
 * as Java maps, so the helpers accept either integer width and nested maps.
 */
private class Arguments(call: MethodCall) {
    private val values: Map<*, *> = call.arguments as? Map<*, *>
        ?: throw IllegalArgumentException("${call.method} expects a named argument map")

    fun string(key: String): String = values[key] as? String
        ?: throw IllegalArgumentException("Missing or invalid '$key' string")

    fun optionalString(key: String): String? {
        val value = values[key] ?: return null
        return value as? String
            ?: throw IllegalArgumentException("Invalid '$key' string")
    }

    fun int(key: String): Int = (values[key] as? Number)?.toInt()
        ?: throw IllegalArgumentException("Missing or invalid '$key' integer")

    fun optionalLong(key: String): Long? {
        val value = values[key] ?: return null
        return (value as? Number)?.toLong()
            ?: throw IllegalArgumentException("Invalid '$key' integer")
    }

    fun boolean(key: String): Boolean = values[key] as? Boolean
        ?: throw IllegalArgumentException("Missing or invalid '$key' boolean")

    fun optionalMap(key: String): Map<String, Any>? {
        val value = values[key] ?: return null
        val map = value as? Map<*, *>
            ?: throw IllegalArgumentException("Invalid '$key' map")
        require(map.keys.all { it is String }) { "Invalid '$key' map keys" }
        @Suppress("UNCHECKED_CAST")
        return map as Map<String, Any>
    }

    fun stringMap(key: String): Map<String, String> {
        val map = optionalMap(key)
            ?: throw IllegalArgumentException("Missing '$key' map")
        return map.mapValues { (_, value) -> value.toString() }
    }
}

/** Convert Android Bundle and nested values into Flutter's standard codec types. */
private fun portable(value: Any?): Any? = when (value) {
    null, is String, is Boolean, is Number, is ByteArray -> value
    is Uri -> value.toString()
    is Bundle -> value.keySet().associateWith { portable(value.get(it)) }
    is Map<*, *> -> value.entries.associate { it.key.toString() to portable(it.value) }
    is Iterable<*> -> value.map(::portable)
    is Array<*> -> value.map(::portable)
    else -> value.toString()
}
