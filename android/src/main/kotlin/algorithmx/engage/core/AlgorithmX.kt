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
import android.os.Handler
import android.os.Looper
import java.lang.ref.WeakReference
import android.net.ConnectivityManager
import android.net.Network
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.UUID
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
import algorithmx.engage.webview.InAppView
import algorithmx.engage.webview.InAppDisplay
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
    private var deviceId: String? = null
    private var identifiedUserId: String? = null
    private var identityPartnerId: String? = null
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
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private var foregroundActivity: WeakReference<Activity>? = null
    private var activeCampaignActivity: WeakReference<CampaignActivity>? = null
    private var pendingDisplay: InAppDisplay? = null
    private var inAppLanguage: String? = null
    private var inAppSessionId = UUID.randomUUID().toString()
    private var visitStartedAt = 0L
    private var fetchedInAppViews = false
    private var displayedInAppView = false
    private var fetchAttempts = 0
    private var pendingViews = emptyList<InAppView>()
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    enum class NotificationEventStatus(val value: Int) {
        SENT(1),
        DELIVERED(2),
        OPENED(3),
        FAILED_TO_SEND(4),
        FAILED_TO_DELIVER(5)
    }

    // region ─ Initialization ──────────────────────────────────────────────────

    /**
     * Safe to call more than once with the same partner ID; later calls update the base URL.
     * [partnerId] is sent as the `x-partner-id` header on every request.
     */
    fun initialize(application: Application, apiBaseUrl: String, partnerId: String) {
        require(!initialized || identityPartnerId == partnerId) { "Destroy the SDK before changing partnerId" }
        appContext = application.applicationContext
        apiUrl = apiBaseUrl.trimEnd('/')
        NetworkClient.partnerId = partnerId
        if (initialized) {
            bootstrapIdentity()
            return
        }
        identityPartnerId = partnerId
        initialized = true

        eventDispatcher = EventDispatcher(application.applicationContext)
        webViewQueueManager = WebViewQueueManager(application.applicationContext)
        webViewQueueManager?.clearQueue()
        notificationManager = EngageNotificationManager()

        lifecycleManager = ActivityLifecycleManager.getInstance()
        lifecycleManager?.register(application)

        // Installation/device identity is separate from the application's account ID.
        fingerprintDevice = storedUuid("anonymous_id")
        deviceId = storedUuid("device_id")
        identifiedUserId = prefs()?.getString(PREF_IDENTIFIED_USER_ID, null)
        bootstrapIdentity()
        identifiedUserId?.takeIf { it.isNotBlank() }?.let { identifyUser(it) }

        val connectivity = application.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                mainHandler.post {
                    if (foregroundActivity?.get() != null) {
                        bootstrapIdentity()
                        identifiedUserId?.let { identifyUser(it) }
                        fetchAttempts = 0
                        fetchInAppViews()
                    }
                }
            }
        }
        connectivity.registerDefaultNetworkCallback(networkCallback!!)

        SdkLog.d(TAG, "AlgorithmX initialized with apiBaseUrl=$apiUrl partnerId=$partnerId")
    }

    fun destroy() {
        appContext?.let { context ->
            if (context is Application) lifecycleManager?.unregister(context)
        }
        networkCallback?.let { callback ->
            val connectivity = appContext?.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            runCatching { connectivity?.unregisterNetworkCallback(callback) }
        }
        networkCallback = null
        foregroundActivity = null
        invalidateInAppViews()
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

    /** Legacy anonymous-ID override. Must be a UUID; use identifyUser for account IDs. */
    fun setDeviceFingerprint(fingerprint: String) {
        val anonymousId = UUID.fromString(fingerprint).toString()
        require(anonymousId.equals(fingerprint, ignoreCase = true)) { "fingerprint must be a canonical UUID" }
        if (anonymousId == fingerprintDevice) return
        fingerprintDevice = anonymousId
        identifiedUserId = null
        prefs()?.edit()?.putString("anonymous_id", anonymousId)?.remove(PREF_IDENTIFIED_USER_ID)?.apply()
        webViewQueueManager?.clearQueue()
        invalidateInAppViews()
        bootstrapIdentity()
        reRegisterDeviceToken()
        fetchInAppViews()
    }

    /** The SDK-generated anonymous UUID, also used in X-Anonymous-Id. */
    fun getAnonymousId(): String = resolveUserId()

    /** Compatibility alias for getAnonymousId. */
    fun getDeviceFingerprint(): String? = fingerprintDevice

    /** Link the anonymous profile to ExternalId, email/phone, and supported customer traits. */
    fun identifyUser(userId: String, attributes: Map<String, Any>? = null) {
        val previousCustomer = resolveCustomerId()
        val identifiers = IdentityPayload.identifiers(userId, attributes)
        val profile = IdentityPayload.profile(attributes)
        if (identifiedUserId != null && identifiedUserId != userId) resetIdentity()
        identifiedUserId = userId
        prefs()?.edit()?.putString(PREF_IDENTIFIED_USER_ID, userId)?.apply()
        bootstrapIdentity()
        eventDispatcher?.send("$apiUrl/api/v1/Identity", "POST", mapOf(
            "anonymousId" to resolveUserId(), "trustedIdentifiers" to identifiers
        ))
        if (profile.isNotEmpty()) sendUserProfile(profile)
        if (previousCustomer != resolveCustomerId() || profile.isNotEmpty()) { invalidateInAppViews(); fetchInAppViews() }
    }

    /** Submit supported customer traits. Ingestion replaces the complete profile; include all current values. */
    fun setUserProfile(attributes: Map<String, Any>) {
        require(attributes.keys.none { it in setOf("email", "phone", "userName") }) {
            "Use identifyUser for email, phone and userName"
        }
        val profile = IdentityPayload.profile(attributes)
        require(profile.isNotEmpty()) { "Profile must contain at least one supported field" }
        bootstrapIdentity()
        sendUserProfile(profile)
        invalidateInAppViews()
        fetchInAppViews()
    }

    private fun sendUserProfile(profile: Map<String, Any>) {
        eventDispatcher?.send("$apiUrl/api/v1/Customer/Ingest", "POST", profile,
            mapOf("X-Anonymous-Id" to resolveUserId(), "X-Device-Id" to deviceId.orEmpty()))
    }

    /** Logout starts a new anonymous profile while keeping the installation's device UUID. */
    fun resetIdentity() {
        identifiedUserId = null
        fingerprintDevice = UUID.randomUUID().toString()
        prefs()?.edit()?.remove(PREF_IDENTIFIED_USER_ID)
            ?.putString("anonymous_id", fingerprintDevice)?.apply()
        webViewQueueManager?.clearQueue()
        invalidateInAppViews()
        bootstrapIdentity()
        reRegisterDeviceToken()
        fetchInAppViews()
    }

    private fun reRegisterDeviceToken() { lastDeviceToken?.let { registerDeviceToken(it) } }

    private fun prefs() = appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun storedUuid(key: String): String {
        val saved = prefs()?.getString(key, null)
        val value = IdentityStorage.uuid(saved)
        prefs()?.edit()?.putString(key, value)?.apply()
        return value
    }

    private fun resolveUserId(): String = fingerprintDevice ?: storedUuid("anonymous_id").also { fingerprintDevice = it }

    private fun bootstrapIdentity() {
        if (!initialized) return
        eventDispatcher?.send("$apiUrl/api/v1/Identity/Bootstrap", "POST", mapOf(
            "anonymousId" to resolveUserId(),
            "deviceId" to (deviceId ?: storedUuid("device_id").also { deviceId = it }),
            "userAgent" to mapOf("os" to "Android ${Build.VERSION.RELEASE}",
                "deviceType" to "mobile", "deviceVendor" to Build.MANUFACTURER, "deviceModel" to Build.MODEL)
        ))
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
            mapOf("X-Anonymous-Id" to userId, "X-Device-Id" to deviceId.orEmpty())
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
        SdkLog.d(TAG, "Ignoring legacy silent-push in-app trigger; views are fetched from the API")
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
        if (context is CampaignActivity) return
        foregroundActivity = (context as? Activity)?.let { WeakReference(it) }
        visitStartedAt = System.currentTimeMillis()
        bootstrapIdentity()
        identifiedUserId?.let { identifyUser(it) }
        fetchInAppViews()
        showNextInAppView()
    }

    internal fun onActivityResumed(activity: Activity) {
        if (activity is CampaignActivity || activity is NotificationClickActivity) return
        foregroundActivity = WeakReference(activity)
        if (visitStartedAt == 0L) visitStartedAt = System.currentTimeMillis()
        fetchInAppViews()
        showNextInAppView()
    }

    fun onAppWentBackground() {
        foregroundActivity = null
        webViewQueueManager?.resetSessionFlag()
        pendingViews = emptyList()
        inAppSessionId = UUID.randomUUID().toString()
        fetchedInAppViews = false
        displayedInAppView = false
        fetchAttempts = 0
    }

    private fun resolveCustomerId(): String = identifiedUserId ?: resolveUserId()

    /** Optional override for an app language that differs from the device language. Empty text restores the default. */
    fun setInAppLanguage(language: String) {
        val value = language.trim()
        if (inAppLanguage == value) return
        inAppLanguage = value
        invalidateInAppViews()
        fetchInAppViews()
    }

    private fun invalidateInAppViews() {
        pendingViews = emptyList()
        fetchedInAppViews = false
        fetchAttempts = 0
        inAppSessionId = UUID.randomUUID().toString()
        activeCampaignActivity?.get()?.let { activity -> mainHandler.post { activity.finish() } }
        pendingDisplay = null
    }

    private fun fetchInAppViews() {
        if (Looper.myLooper() != Looper.getMainLooper()) { mainHandler.post { fetchInAppViews() }; return }
        if (!initialized || foregroundActivity?.get() == null || fetchedInAppViews) return
        val anonymousId = resolveUserId()
        val customerId = resolveCustomerId()
        val locale = appContext?.resources?.configuration?.locales?.get(0)?.toLanguageTag() ?: Locale.getDefault().toLanguageTag()
        val language = inAppLanguage?.takeIf { it.isNotBlank() } ?: locale
        val url = NetworkClient.inAppViewsUrl(apiUrl, language, customerId)
        val session = inAppSessionId
        fetchedInAppViews = true
        fetchAttempts++
        eventDispatcher?.getJsonArray(url, mapOf("X-Anonymous-Id" to anonymousId, "X-Device-Id" to deviceId.orEmpty())) { result ->
            mainHandler.post {
                if (session != inAppSessionId || anonymousId != resolveUserId() || customerId != resolveCustomerId()) return@post
                result.onSuccess { rows ->
                    pendingViews = rows.mapNotNull(InAppView::fromMap).sortedWith(compareByDescending<InAppView> { it.rule.priority }.thenBy { it.id })
                    showNextInAppView()
                }.onFailure { error ->
                    fetchedInAppViews = false
                    SdkLog.e(TAG, "In-app API fetch failed", error)
                    val status = (error as? NetworkClient.HttpFailure)?.status
                    if (fetchAttempts < 4 && (status == 409 || status == 408 || status == 429 ||
                        (status != null && status >= 500) || error is java.io.IOException)) {
                        mainHandler.postDelayed({ if (session == inAppSessionId) fetchInAppViews() }, fetchAttempts * 500L)
                    }
                }
            }
        }
    }

    private fun showNextInAppView(attempt: Int = 0) {
        val activity = foregroundActivity?.get() ?: return
        if (activity.isFinishing || activity.isDestroyed || isWebViewShowing || displayedInAppView || pendingViews.isEmpty()) return
        if (!activity.hasWindowFocus()) {
            if (attempt < 10) {
                val session = inAppSessionId
                mainHandler.postDelayed({ if (session == inAppSessionId) showNextInAppView(attempt + 1) }, 200)
            }
            return
        }
        for (view in pendingViews) {
            val variation = view.variation(resolveCustomerId()) ?: continue
            if (webViewQueueManager?.canDisplayWebView(view.campaignId, variation.id, resolveCustomerId(), view.rule) != true) continue
            val delay = (view.delaySeconds * 1000).toLong() - (System.currentTimeMillis() - visitStartedAt)
            if (delay > 0) {
                val session = inAppSessionId
                mainHandler.postDelayed({ if (session == inAppSessionId) showNextInAppView() }, delay)
                return
            }
            val display = InAppDisplay(UUID.randomUUID().toString(), view, variation, apiUrl, resolveUserId(), resolveCustomerId())
            pendingDisplay = display
            pendingViews = emptyList()
            displayedInAppView = true
            isWebViewShowing = true
            try {
                activity.startActivity(Intent(activity, CampaignActivity::class.java).putExtra(CampaignActivity.EXTRA_IN_APP_TOKEN, display.token))
            } catch (error: Exception) {
                pendingDisplay = null
                isWebViewShowing = false
                SdkLog.e(TAG, "Failed to display in-app view", error)
            }
            return
        }
        pendingViews = emptyList()
    }

    internal fun inAppDisplay(token: String): InAppDisplay? = pendingDisplay?.takeIf { it.token == token }
    internal fun attachInAppActivity(activity: CampaignActivity) { activeCampaignActivity = WeakReference(activity) }
    internal fun completeInAppDisplay(token: String) {
        if (pendingDisplay?.token == token) pendingDisplay = null
        activeCampaignActivity = null
    }

    internal fun trackInAppInteraction(display: InAppDisplay, interactionType: String, payload: Map<String, Any>) {
        val data = payload + mapOf("inAppViewId" to display.view.id, "campaignId" to display.view.campaignId,
            "variationId" to display.variation.id, "interactionType" to interactionType, "customerId" to display.customerId)
        val timestamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date())
        eventDispatcher?.send("$apiUrl/api/v1/Event/Log", "POST", listOf(mapOf(
            "eventType" to "inAppViewInteraction", "data" to data, "timestamp" to timestamp)),
            mapOf("X-Anonymous-Id" to display.anonymousId, "X-Device-Id" to deviceId.orEmpty()))
        campaignInteractionListener?.onCampaignInteraction(display.view.campaignId, display.variation.id, interactionType, data)
    }

    /** Record successful HTML loads against the identity captured when the view opened. */
    fun recordWebViewDisplaySuccess(campaignId: String, variationId: String, expiresAt: Long = 0L) {
        webViewQueueManager?.recordWebViewDisplay(campaignId, variationId, resolveUserId(), expiresAt)
    }

    internal fun recordInAppDisplaySuccess(display: InAppDisplay) {
        webViewQueueManager?.recordWebViewDisplay(display.view.campaignId, display.variation.id, display.customerId, display.view.rule.expiresAt)
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

    fun getQueueSize(): Int = pendingViews.size
    fun getWebViewQueueSize(): Int = getQueueSize()
    fun clearWebViewQueue(): Int {
        val count = pendingViews.size + (webViewQueueManager?.clearQueue() ?: 0)
        pendingViews = emptyList()
        inAppSessionId = UUID.randomUUID().toString()
        return count
    }
    fun clearAllWebViewData(): Boolean {
        clearWebViewQueue()
        return webViewQueueManager?.clearAllData() ?: false
    }
    fun getDisplayStats(campaignId: String, variationId: String): String =
        webViewQueueManager?.getDisplayStats(campaignId, variationId, resolveCustomerId())
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
