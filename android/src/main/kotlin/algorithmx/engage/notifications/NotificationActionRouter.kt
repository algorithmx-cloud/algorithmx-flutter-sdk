package algorithmx.engage.notifications

import android.content.Context
import android.content.Intent
import android.os.Bundle
import algorithmx.engage.core.AlgorithmX
import algorithmx.engage.utils.JsonUtil
import algorithmx.engage.utils.SdkLog

/**
 * Centralised handler for notification action routing. Mirrors the iOS click
 * handler so both platforms expose the same `action_type` semantics.
 *
 * Supported `action_type` values:
 *   - `open_web_page`  → SDK opens the URL from `actionData.url` in the browser.
 *   - `open_webview`   → SDK opens an in-app campaign WebView.
 *   - `open_screen`    → SDK calls the deep link handler with `actionData.deepLink`.
 *   - `custom_action`  → SDK extracts `actionData.action` and calls `onCustomAction`.
 *   - `standard` / null → No-op; partner reads notification data directly.
 */
object NotificationActionRouter {
    private const val TAG = "AlgorithmX"

    /** True when the intent extras come from an AlgorithmX notification. */
    fun isAlgorithmXExtras(extras: Bundle): Boolean =
        extras.containsKey("algo_notification_id") ||
            extras.containsKey("algo_campaign_id") ||
            extras.containsKey("engage_action")

    fun routeFromIntent(context: Context, extras: Bundle) {
        val data = mutableMapOf<String, Any>()
        for (key in extras.keySet()) {
            extras.get(key)?.let { data[key] = it }
        }
        route(context, data)
    }

    /**
     * `trackOpen = false` when the tap was already tracked (an action button
     * whose handler didn't handle it falls back to this default routing).
     */
    fun route(context: Context, data: Map<String, Any>, trackOpen: Boolean = true) {
        // 1. Track open + click.
        if (trackOpen) trackOpened(data)

        // 2. Give the partner the first chance to handle.
        val listener = AlgorithmX.getNotificationClickListener()
        if (listener?.onNotificationClick(data) == true) return

        // 3. Default SDK behaviour by action_type.
        val actionData = parseActionData(data["actionData"] as? String)
        val actionType = data["action_type"] as? String
        val performed = when (actionType) {
            "open_web_page" -> openWebPage(context, actionData["url"] as? String)
            "open_webview" -> openCampaignWebView(context, data, actionData)
            "open_screen" -> {
                val deepLink = actionData["deepLink"] as? String
                if (!deepLink.isNullOrEmpty()) { AlgorithmX.openDeepLink(context, deepLink); true } else false
            }
            "custom_action" -> {
                val customAction = actionData["action"] as? String
                listener?.onCustomAction(customAction, data + ("parsedActionData" to actionData))
                true
            }
            else -> false // standard / null / unknown — no-op
        }
        // Tell the partner the SDK ran a default action for this tap (same as iOS).
        if (performed && actionType != null) listener?.onActionHandled(actionType, data)
    }

    private fun trackOpened(data: Map<String, Any>) {
        (data["algo_notification_id"] as? String)?.toIntOrNull()?.let { id ->
            AlgorithmX.updateNotificationStatus(id, AlgorithmX.NotificationEventStatus.OPENED)
        }
        (data["algo_campaign_id"] as? String)?.let { campaignId ->
            val variationId = (data["engage_variation_id"] as? String) ?: "default"
            AlgorithmX.trackCampaignInteraction(
                campaignId,
                variationId,
                "click",
                mapOf(
                    "notification_type" to "push",
                    "action" to ((data["action_type"] as? String) ?: "unknown")
                )
            )
        }
    }

    private fun parseActionData(raw: String?): Map<String, Any> {
        if (raw.isNullOrEmpty() || raw == "{}") return emptyMap()
        return try {
            @Suppress("UNCHECKED_CAST")
            JsonUtil.fromJson(raw) as? Map<String, Any> ?: emptyMap()
        } catch (e: Exception) {
            SdkLog.e(TAG, "Failed to parse actionData", e); emptyMap()
        }
    }

    private fun openWebPage(context: Context, url: String?): Boolean {
        if (url.isNullOrEmpty()) return false
        return try {
            val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            SdkLog.e(TAG, "Failed to open external URL", e); false
        }
    }

    private fun openCampaignWebView(
        context: Context,
        data: Map<String, Any>,
        actionData: Map<String, Any>
    ): Boolean {
        val url = actionData["url"] as? String ?: return false
        val campaignId = data["algo_campaign_id"] as? String ?: return false
        val variationId = (data["engage_variation_id"] as? String) ?: "default"
        AlgorithmX.showWebView(context, campaignId, variationId, url, null)
        return true
    }
}
