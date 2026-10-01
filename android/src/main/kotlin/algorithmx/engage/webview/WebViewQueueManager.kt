package algorithmx.engage.webview

import android.content.Context
import algorithmx.engage.core.AlgorithmX
import algorithmx.engage.utils.JsonUtil
import algorithmx.engage.utils.SdkLog

/**
 * Coordinates the SQLite-backed queue and display rules. Mirrors iOS
 * `WebViewQueueManager` field-for-field.
 *
 * Display recording: webview is recorded as "displayed" by CampaignActivity
 * only after the HTML loads successfully (`recordWebViewDisplaySuccess`).
 * Failed loads do not consume the max-show counter.
 */
class WebViewQueueManager(private val context: Context) {
    private val db = WebViewDatabaseHelper(context)
    private var hasProcessedQueueThisSession = false

    fun canDisplayWebView(
        campaignId: String,
        variationId: String,
        userId: String,
        rule: WebViewDisplayRule
    ): Boolean {
        // A user only ever sees one variation of a campaign.
        if (db.hasSeenOtherVariation(campaignId, variationId, userId)) return false
        if (rule.isExpired()) return false

        val history = db.getDisplayHistory(campaignId, variationId, userId)
        if (history.displayCount >= rule.maxShowTime) {
            if (rule.showAgainAfterDays > 0) {
                val daysSinceReset = (System.currentTimeMillis() - history.lastResetAt) / (24 * 60 * 60 * 1000)
                if (daysSinceReset >= rule.showAgainAfterDays) {
                    resetDisplayHistory(campaignId, variationId, userId, rule.expiresAt)
                    return true
                }
            }
            return false
        }
        if (history.lastShownAt > 0 && rule.intervalMinutes > 0) {
            val sinceLast = System.currentTimeMillis() - history.lastShownAt
            if (sinceLast < rule.getIntervalMs()) return false
        }
        return true
    }

    fun willBeAbleToDisplayLater(
        campaignId: String,
        variationId: String,
        userId: String,
        rule: WebViewDisplayRule
    ): Boolean {
        // A user only ever sees one variation of a campaign.
        if (db.hasSeenOtherVariation(campaignId, variationId, userId)) return false
        if (rule.isExpired()) return false
        val history = db.getDisplayHistory(campaignId, variationId, userId)
        if (history.displayCount >= rule.maxShowTime) {
            if (rule.showAgainAfterDays > 0) {
                val daysSinceReset = (System.currentTimeMillis() - history.lastResetAt) / (24 * 60 * 60 * 1000)
                return daysSinceReset >= rule.showAgainAfterDays
            }
            return false
        }
        return true
    }

    private fun resetDisplayHistory(
        campaignId: String,
        variationId: String,
        userId: String,
        expiresAt: Long
    ) {
        val now = System.currentTimeMillis()
        db.upsertDisplayHistory(WebViewDisplayHistory(
            id = 0,
            campaignId = campaignId,
            variationId = variationId,
            userId = userId,
            displayCount = 0,
            lastShownAt = 0,
            lastResetAt = now,
            expiresAt = expiresAt,
            createdAt = now
        ))
    }

    fun recordWebViewDisplay(
        campaignId: String,
        variationId: String,
        userId: String,
        expiresAt: Long = 0L
    ) {
        val history = db.getDisplayHistory(campaignId, variationId, userId)
        val now = System.currentTimeMillis()
        db.upsertDisplayHistory(history.copy(
            displayCount = history.displayCount + 1,
            lastShownAt = now,
            expiresAt = if (expiresAt > 0) expiresAt else history.expiresAt
        ))
    }

    fun enqueueWebView(
        campaignId: String,
        variationId: String,
        webviewUrl: String,
        dynamicContent: Map<String, Any>?,
        rule: WebViewDisplayRule,
        metadata: Map<String, Any>? = null
    ): Long {
        // Same campaign + variation already waiting → keep the queued one.
        val existing = db.getPendingWebViews().find { it.campaignId == campaignId && it.variationId == variationId }
        if (existing != null) return existing.id

        val dynamicJson = try { dynamicContent?.let { JsonUtil.toJson(it) } } catch (e: Exception) { null }
        val metadataJson = try { metadata?.let { JsonUtil.toJson(it) } } catch (e: Exception) { null }

        return db.insertQueuedWebView(
            campaignId, variationId, webviewUrl, dynamicJson, rule.toJson(), metadataJson, rule.priority
        )
    }

    fun processQueuedWebViews(context: Context, userId: String): Boolean {
        if (hasProcessedQueueThisSession) return false
        db.cleanupExpiredWebViews()
        db.pruneDisplayHistory()
        val queued = db.getPendingWebViews()
        if (queued.isEmpty()) return false

        for (entry in queued) {
            val rule = WebViewDisplayRule.fromJson(entry.configs)
            if (rule.isExpired()) {
                db.removeFromQueue(entry.id)
                continue
            }
            if (canDisplayWebView(entry.campaignId, entry.variationId, userId, rule)) {
                val dynamic = try {
                    @Suppress("UNCHECKED_CAST")
                    entry.dynamicContent?.let { JsonUtil.fromJson(it) as? Map<String, Any> }
                } catch (e: Exception) { null }
                AlgorithmX.showWebView(context, entry.campaignId, entry.variationId, entry.webviewUrl, dynamic, rule.expiresAt)
                db.removeFromQueue(entry.id)
                hasProcessedQueueThisSession = true
                return true
            }
            // Drop entries that can never show (e.g. campaign already seen);
            // left queued they never leave and block their variation id.
            if (!willBeAbleToDisplayLater(entry.campaignId, entry.variationId, userId, rule)) {
                db.removeFromQueue(entry.id)
            }
        }
        return false
    }

    fun getQueueSize(): Int = db.getQueueSize()

    fun clearQueue(): Int {
        var cleared = 0
        db.getPendingWebViews().forEach { if (db.removeFromQueue(it.id)) cleared++ }
        return cleared
    }

    fun clearAllData(): Boolean = db.clearAllData()

    fun resetSessionFlag() { hasProcessedQueueThisSession = false }

    fun destroy() = try { db.close() } catch (e: Exception) { SdkLog.e(TAG, "DB close failed", e) }

    fun getDisplayStats(campaignId: String, variationId: String, userId: String): String {
        val h = db.getDisplayHistory(campaignId, variationId, userId)
        return buildString {
            append("Campaign ID: $campaignId\n")
            append("Variation ID: $variationId\n")
            append("User: $userId\n")
            append("Display Count: ${h.displayCount}\n")
            append("Last Shown: ${if (h.lastShownAt > 0) java.util.Date(h.lastShownAt) else "Never"}\n")
            append("Last Reset: ${java.util.Date(h.lastResetAt)}\n")
            append("Expires At: ${if (h.expiresAt > 0) java.util.Date(h.expiresAt) else "Never"}\n")
            append("Created At: ${java.util.Date(h.createdAt)}\n")
        }
    }

    companion object { private const val TAG = "AlgorithmX" }
}
