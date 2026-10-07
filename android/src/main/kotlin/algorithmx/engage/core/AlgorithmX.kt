package algorithmx.engage.core

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import androidx.core.app.NotificationCompat
import algorithmx.engage.interfaces.AlgoWebViewListener
import algorithmx.engage.interfaces.NotificationClickListener
import algorithmx.engage.interfaces.DeepLinkHandler
import algorithmx.engage.interfaces.ActionButtonHandler
import algorithmx.engage.interfaces.CampaignInteractionListener
import algorithmx.engage.events.EventDispatcher
import algorithmx.engage.networking.NetworkClient
import algorithmx.engage.webview.WebViewQueueManager
import algorithmx.engage.webview.WebViewDisplayRule
import algorithmx.engage.notifications.EngageNotificationManager
import algorithmx.engage.notifications.NotificationActionRouter
import algorithmx.engage.activities.CampaignActivity
import algorithmx.engage.activities.NotificationClickActivity
import algorithmx.engage.utils.SdkLog
import algorithmx.engage.utils.SdkPayload
import algorithmx.engage.lifecycle.ActivityLifecycleManager

/**
 * Public entry point of the AlgorithmX in-app SDK.
 *
 * Mirrors the iOS `AlgorithmX` singleton: same method names, same payload shapes,
 * same notification payload keys (engageAction, algoCampaignId, etc.).
 */
object AlgorithmX {
    private const val TAG = "AlgorithmX"
    private const val PREFS_NAME = "algorithmx_sdk"
    private const val PREF_IDENTIFIED_USER_ID = "identified_user_id"

    private var apiUrl: String = "http://10.0.2.2:5000"
    private var appContext: Context? = null

    private var fingerprintDevice: String? = null
    private var engageUserId: String? = null

    private var eventDispatcher: EventDispatcher? = null
    private var webViewQueueManager: WebViewQueueManager? = null
    private var notificationManager: EngageNotificationManager? = null
    private var lifecycleManager: ActivityLifecycleManager? = null

    private var algoWebViewListener: AlgoWebViewListener? = null
    private var notificationClickListener: NotificationClickListener? = null
    private var deepLinkHandler: DeepLinkHandler? = null
    private var actionButtonHandler: ActionButtonHandler? = null
    private var campaignInteractionListener: CampaignInteractionListener? = null

    private var isWebViewShowing: Boolean = false
    private var smallIconResId: Int = android.R.drawable.ic_dialog_info
    private var initialized = false
    private var lastDeviceToken: String? = null

    enum class NotificationEventStatus(val value: Int) {
        SENT(1),
        DELIVERED(2),
        OPENED(3),
        FAILED_TO_SEND(4),
        FAILED_TO_DELIVER(5)
    }

    // region ─ Initialization ──────────────────────────────────────────────────

    /**
     * Safe to call more than once: later calls only update the base URL and partner ID.
     * [partnerId] is sent as the `x-partner-id` header on every request.
     */
    fun initialize(application: Application, apiBaseUrl: String, partnerId: String) {
        appContext = application.applicationContext
        apiUrl = apiBaseUrl.trimEnd('/')
        NetworkClient.partnerId = partnerId
        if (initialized) return
        initialized = true

        eventDispatcher = EventDispatcher(application.applicationContext)
        webViewQueueManager = WebViewQueueManager(application.applicationContext)
        notificationManager = EngageNotificationManager()

        lifecycleManager = ActivityLifecycleManager.getInstance()
        lifecycleManager?.register(application)

        // An identified user survives restarts (also when a push starts the
        // process); otherwise default to the Android ID like iOS uses IDFV.
        fingerprintDevice = loadIdentifiedUserId() ?: fingerprintDevice ?: readAndroidId()

        SdkLog.d(TAG, "AlgorithmX initialized with apiBaseUrl=$apiUrl partnerId=$partnerId")
    }

    fun destroy() {
        appContext?.let { context ->
            if (context is Application) lifecycleManager?.unregister(context)
        }
        lifecycleManager = null
        eventDispatcher?.destroy()
        eventDispatcher = null
        webViewQueueManager?.destroy()
        webViewQueueManager = null
        initialized = false
    }

    /** Debug logging (Logcat tag "AlgorithmX"). Off by default; warnings and errors are always logged. */
    fun setLoggingEnabled(enabled: Boolean) { SdkLog.enabled = enabled }

    // endregion

    // region ─ Identity & device ───────────────────────────────────────────────

    /** Set or override the device fingerprint. Called automatically during init. */
    fun setDeviceFingerprint(fingerprint: String) {
        fingerprintDevice = fingerprint
    }

    /** Get the current device fingerprint (no fallback). */
    fun getDeviceFingerprint(): String? = fingerprintDevice

    /**
     * Identify a user. Sets fingerprintDevice to `userId`, keeps it across app
     * restarts until [resetIdentity], and notifies backend.
     */
    fun identifyUser(userId: String, attributes: Map<String, Any>? = null) {
        val previous = resolveUserId()
        fingerprintDevice = userId
        prefs()?.edit()?.putString(PREF_IDENTIFIED_USER_ID, userId)?.apply()
        // previousFingerprintDevice lets the backend link what happened before login.
        val body = mutableMapOf<String, Any>(
            "fingerprintDevice" to userId,
            "previousFingerprintDevice" to previous
        )
        attributes?.let { body["attributes"] = it }
        eventDispatcher?.send("$apiUrl/api/v1/identify", "POST", body)
        if (previous != userId) reRegisterDeviceToken()
    }

    /** Forget the identified user (e.g. on logout) and go back to the device id. */
    fun resetIdentity() {
        val previous = resolveUserId()
        prefs()?.edit()?.remove(PREF_IDENTIFIED_USER_ID)?.apply()
        fingerprintDevice = readAndroidId()
        if (previous != resolveUserId()) reRegisterDeviceToken()
    }

    /** Pushes are sent to the token's owner, so move the token to the new identity at once. */
    private fun reRegisterDeviceToken() { lastDeviceToken?.let { registerDeviceToken(it) } }

    private fun prefs() = appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun loadIdentifiedUserId(): String? =
        prefs()?.getString(PREF_IDENTIFIED_USER_ID, null)?.takeIf { it.isNotEmpty() }

    /** Effective user ID used in payloads. */
    private fun resolveUserId(): String =
        fingerprintDevice ?: engageUserId ?: readAndroidId() ?: "anonymous"

    private fun readAndroidId(): String? = try {
        appContext?.let {
            Settings.Secure.getString(it.contentResolver, Settings.Secure.ANDROID_ID)
                .takeIf { id -> !id.isNullOrEmpty() }
        }
    } catch (e: Exception) {
        SdkLog.e(TAG, "Failed to read Android ID", e); null
    }

    // endregion

    // region ─ Event tracking ──────────────────────────────────────────────────

    fun trackEvent(name: String, properties: Map<String, Any>? = null) {
        val userId = resolveUserId()
        val timestamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }.format(Date())
        val body = mapOf<String, Any>(
            "eventType" to name,
            "data" to (properties ?: emptyMap<String, Any>()),
            "timestamp" to timestamp
        )
        eventDispatcher?.send(
            "$apiUrl/api/v1/Event/Log", "POST", listOf(body),
            mapOf("X-Anonymous-Id" to userId)
        )
    }

    fun trackCampaignInteraction(
        campaignId: String,
        variationId: String,
        interactionType: String,
        payload: Map<String, Any>? = null,
        sessionId: String? = null,
        endpoint: String? = null
    ) {
        val userId = resolveUserId()
        val body = mutableMapOf<String, Any>(
            "fingerprintDevice" to userId,
            "campaignId" to (campaignId.toIntOrNull() ?: 0),
            "variationId" to (variationId.toIntOrNull() ?: 0),
            "interactionType" to interactionType
        )
        payload?.let {
            try { body["payload"] = algorithmx.engage.utils.JsonUtil.toJson(it) }
            catch (e: Exception) { SdkLog.e(TAG, "Failed to serialize payload", e) }
        }
        sessionId?.let { body["sessionId"] = it }

        val endpointPath = endpoint ?: "/api/v1/tracks/algoViewInteract"
        eventDispatcher?.send("$apiUrl$endpointPath", "POST", body)

        campaignInteractionListener?.onCampaignInteraction(
            campaignId, variationId, interactionType, payload ?: emptyMap()
        )
    }

    fun updateNotificationStatus(
        notificationId: Int,
        status: NotificationEventStatus,
        errorMessage: String? = null
    ) {
        val body = mutableMapOf<String, Any>(
            "notificationId" to notificationId,
            "fingerprintDevice" to resolveUserId(),
            "status" to status.value
        )
        errorMessage?.let { body["errorMessage"] = it }
        eventDispatcher?.send(
            "$apiUrl/api/v1/inAppPushEvents/device/status",
            "PUT",
            body
        )
    }

    // endregion

    // region ─ Push token registration ─────────────────────────────────────────

    fun registerDeviceToken(token: String) {
        lastDeviceToken = token
        val body = mapOf<String, Any>(
            "fingerprintDevice" to resolveUserId(),
            "token" to token,
            "platform" to "android"
        )
        eventDispatcher?.send("$apiUrl/api/v1/notificationTokens", "POST", body)
    }

    // endregion

    // region ─ Push notification handling ──────────────────────────────────────

    /**
     * True for pushes sent by AlgorithmX. When your app also receives pushes from
     * another provider, forward only these to [handleFcmMessage]. Same check as
     * iOS `isAlgorithmXPush`.
     */
    fun isAlgorithmXPush(data: Map<String, String>): Boolean {
        val action = SdkPayload.notification(data)["engageAction"]
        return action == "algoTriggerWebview" || action == "algoShowNotification"
    }

    /**
     * Unified FCM message entry point. Routes between silent webview triggers and
     * normal notifications based on the `engageAction` field. Pushes that aren't
     * from AlgorithmX are ignored (like iOS), so forwarding every message is safe.
     */
    fun handleFcmMessage(
        context: Context,
        data: Map<String, String>,
        notificationTitle: String? = null,
        notificationBody: String? = null
    ) {
        val pushData = SdkPayload.notification(data)
        when (pushData["engageAction"]) {
            "algoTriggerWebview" -> processSilentNotification(context, pushData)
            "algoShowNotification" -> processNormalNotification(context, pushData, notificationTitle, notificationBody)
            else -> SdkLog.d(TAG, "Ignoring a push that isn't from AlgorithmX")
        }
    }

    fun processNormalNotification(
        context: Context,
        data: Map<String, String>,
        title: String? = null,
        body: String? = null
    ) {
        val pushData = SdkPayload.notification(data)
        pushData["algoNotificationId"]?.toIntOrNull()?.let {
            updateNotificationStatus(it, NotificationEventStatus.DELIVERED)
        }
        notificationManager?.handleNormalNotification(context, pushData, title, body)
            ?: createFallbackNotification(context, pushData, title, body)
    }

    fun processSilentNotification(context: Context, data: Map<String, String>) {
        val pushData = SdkPayload.notification(data)
        val action = pushData["engageAction"]
        if (action != "algoTriggerWebview") return

        val campaignId = pushData["algoCampaignId"]
        val variationId = pushData["engageVariationId"] ?: "0"
        val webviewUrl = pushData["engageWebviewUrl"]

        // Store the backend-issued user id separately from the device fingerprint.
        pushData["engageUserId"]?.takeIf { it.isNotEmpty() }?.let { engageUserId = it }

        if (campaignId.isNullOrEmpty() || webviewUrl.isNullOrEmpty()) return

        val dynamicContent = try {
            pushData["engageDynamicContent"]?.takeIf { it.isNotEmpty() }
                ?.let { algorithmx.engage.utils.JsonUtil.fromJson(it) as? Map<String, Any> }
        } catch (e: Exception) { null }

        val configs = try {
            pushData["configs"]?.takeIf { it.isNotEmpty() }
                ?.let { algorithmx.engage.utils.JsonUtil.fromJson(it) as? Map<String, Any> }
        } catch (e: Exception) { null }

        val displayRule = WebViewDisplayRule.fromConfigs(configs)
        val userId = resolveUserId()

        trackEvent("silentNotificationReceived", mapOf(
            "campaignId" to campaignId,
            "variationId" to variationId,
            "action" to action,
            "hasDynamicContent" to (dynamicContent != null),
            "hasConfigs" to (configs != null),
            "priority" to displayRule.priority
        ))

        // Only enqueue if the webview can be (or eventually will be) displayed,
        // also while another webview is showing: an entry that can never show
        // would stay queued and block its variation id.
        if (webViewQueueManager?.canDisplayWebView(campaignId, variationId, userId, displayRule) == true ||
            webViewQueueManager?.willBeAbleToDisplayLater(campaignId, variationId, userId, displayRule) == true) {
            webViewQueueManager?.enqueueWebView(campaignId, variationId, webviewUrl, dynamicContent, displayRule, pushData.toMap())
        }
    }

    // endregion

    // region ─ WebView display ─────────────────────────────────────────────────

    fun showWebView(
        context: Context,
        campaignId: String,
        variationId: String,
        url: String,
        dynamicContent: Map<String, Any>? = null,
        expiresAt: Long = 0L
    ) {
        try {
            val intent = Intent(context, CampaignActivity::class.java).apply {
                putExtra(CampaignActivity.EXTRA_CAMPAIGN_ID, campaignId)
                putExtra(CampaignActivity.EXTRA_VARIATION_ID, variationId)
                putExtra(CampaignActivity.EXTRA_URL, url)
                putExtra("extra_expires_at", expiresAt)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

                dynamicContent?.let { content ->
                    // Same as iOS: every value becomes text (objects/arrays as JSON).
                    val bundle = Bundle()
                    for ((key, value) in content) bundle.putString(key, dynamicValueText(value))
                    putExtra(CampaignActivity.EXTRA_DYNAMIC_CONTENT, bundle)
                }
            }
            setWebViewShowing(true)
            context.startActivity(intent)
        } catch (e: Exception) {
            SdkLog.e(TAG, "Failed to start CampaignActivity", e)
            setWebViewShowing(false)
        }
    }

    /**
     * Manual trigger for testing. Bypasses queueing and shows immediately if no
     * webview is currently showing.
     */
    fun triggerWebView(
        context: Context,
        campaignId: String,
        webviewUrl: String,
        dynamicContent: Map<String, Any>? = null
    ) {
        if (isWebViewShowing) return
        showWebView(context, campaignId, "default", webviewUrl, dynamicContent)
        algoWebViewListener?.onWebViewTrigger(campaignId, webviewUrl, dynamicContent)
    }

    private fun dynamicValueText(value: Any?): String = when (value) {
        null -> ""
        is String -> value
        is Map<*, *>, is List<*> -> try {
            algorithmx.engage.utils.JsonUtil.toJson(normalizedJson(value) ?: value)
        } catch (e: Exception) { value.toString() }
        is Double -> if (value % 1.0 == 0.0) value.toLong().toString() else value.toString()
        else -> value.toString()
    }

    /** Sorted keys and whole numbers without ".0", so the JSON text matches iOS. */
    private fun normalizedJson(value: Any?): Any? = when (value) {
        is Map<*, *> -> java.util.TreeMap<String, Any?>().apply {
            value.forEach { (k, v) -> put(k.toString(), normalizedJson(v)) }
        }
        is List<*> -> value.map { normalizedJson(it) }
        is Double -> if (value % 1.0 == 0.0) value.toLong() else value
        else -> value
    }

    fun setWebViewShowing(showing: Boolean) { isWebViewShowing = showing }
    fun isWebViewCurrentlyShowing(): Boolean = isWebViewShowing

    /**
     * Shows the next queued campaign. The SDK calls this itself when the app
     * comes to the foreground; calling it from the host as well is harmless.
     */
    fun onAppBecameActive(context: Context) {
        if (!isWebViewShowing) webViewQueueManager?.processQueuedWebViews(context, resolveUserId())
    }

    fun onAppWentBackground() { webViewQueueManager?.resetSessionFlag() }

    /** Records a successful webview HTML load. Called from CampaignActivity on page load. */
    fun recordWebViewDisplaySuccess(campaignId: String, variationId: String, expiresAt: Long = 0L) {
        webViewQueueManager?.recordWebViewDisplay(campaignId, variationId, resolveUserId(), expiresAt)
    }

    // endregion

    // region ─ Listeners ───────────────────────────────────────────────────────

    fun setAlgoWebViewListener(listener: AlgoWebViewListener) { algoWebViewListener = listener }
    fun removeAlgoWebViewListener() { algoWebViewListener = null }

    fun setNotificationClickListener(listener: NotificationClickListener) { notificationClickListener = listener }
    fun removeNotificationClickListener() { notificationClickListener = null }
    fun getNotificationClickListener(): NotificationClickListener? = notificationClickListener

    fun setDeepLinkHandler(handler: DeepLinkHandler) { deepLinkHandler = handler }
    fun removeDeepLinkHandler() { deepLinkHandler = null }
    fun getDeepLinkHandler(): DeepLinkHandler? = deepLinkHandler

    fun setActionButtonHandler(handler: ActionButtonHandler) { actionButtonHandler = handler }
    fun removeActionButtonHandler() { actionButtonHandler = null }
    fun getActionButtonHandler(): ActionButtonHandler? = actionButtonHandler

    fun setCampaignInteractionListener(listener: CampaignInteractionListener) { campaignInteractionListener = listener }
    fun removeCampaignInteractionListener() { campaignInteractionListener = null }

    // endregion

    // region ─ Deep links & action buttons ─────────────────────────────────────

    /**
     * Delegate-only deep link handling. Mirrors iOS: returns true if the client
     * handled it, false otherwise. The SDK never fires Intent.ACTION_VIEW itself —
     * the partner controls navigation.
     */
    fun openDeepLink(context: Context, deepLinkUrl: String): Boolean {
        val uri = try { android.net.Uri.parse(deepLinkUrl) } catch (e: Exception) { return false }
        return deepLinkHandler?.onDeepLinkReceived(uri) ?: false
    }

    /** Returns true when the partner's handler handled the button. */
    fun handleActionButtonClick(
        context: Context,
        buttonId: String,
        actionText: String,
        title: String,
        notificationData: Map<String, Any>
    ): Boolean =
        actionButtonHandler?.onActionButtonClicked(buttonId, actionText, title, SdkPayload.notification(notificationData)) ?: false

    // endregion

    // region ─ Intent handling (auto + manual) ─────────────────────────────────

    fun handleIntent(context: Context, intent: Intent?) {
        val extras = intent?.extras ?: return
        // NotificationClickActivity preserves tap extras for the host Activity
        // but has already routed that tap through its broadcast receiver.
        if (extras.getBoolean(NotificationClickActivity.EXTRA_ALREADY_ROUTED, false)) return
        if (NotificationActionRouter.isAlgorithmXExtras(extras)) {
            NotificationActionRouter.routeFromIntent(context, extras)
        }
    }

    fun handleNewIntent(activity: Activity, intent: Intent) {
        lifecycleManager?.handleNewIntent(activity, intent)
    }

    // endregion

    // region ─ Misc / debug ────────────────────────────────────────────────────

    fun getQueueSize(): Int = webViewQueueManager?.getQueueSize() ?: 0
    fun getWebViewQueueSize(): Int = getQueueSize()
    fun clearWebViewQueue(): Int = webViewQueueManager?.clearQueue() ?: 0
    fun clearAllWebViewData(): Boolean = webViewQueueManager?.clearAllData() ?: false
    fun getDisplayStats(campaignId: String, variationId: String): String =
        webViewQueueManager?.getDisplayStats(campaignId, variationId, resolveUserId())
            ?: "WebView queue manager not initialized"

    fun setSmallIcon(resId: Int) { smallIconResId = resId }
    fun getSmallIconResId(): Int = smallIconResId

    // endregion

    private fun createFallbackNotification(
        context: Context,
        data: Map<String, String>,
        title: String?,
        body: String?
    ) {
        try {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                mgr.createNotificationChannel(NotificationChannel(
                    "algorithmx_fallback", "AlgorithmX Notifications",
                    NotificationManager.IMPORTANCE_DEFAULT
                ))
            }
            val click = Intent(context, NotificationClickActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                data.forEach { (k, v) -> putExtra(k, v) }
            }
            val pi = PendingIntent.getActivity(
                context,
                System.currentTimeMillis().toInt(),
                click,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val n = NotificationCompat.Builder(context, "algorithmx_fallback")
                .setContentTitle(title ?: data["title"] ?: "Notification")
                .setContentText(body ?: data["body"] ?: "")
                .setSmallIcon(smallIconResId)
                .setAutoCancel(true)
                .setContentIntent(pi)
                .build()
            mgr.notify(10000 + System.currentTimeMillis().toInt() % 10000, n)
        } catch (e: Exception) {
            SdkLog.e(TAG, "Fallback notification failed", e)
        }
    }
}
