package algorithmx.engage.webview

import algorithmx.engage.utils.JsonUtil
import algorithmx.engage.utils.SdkLog

/**
 * Display configuration for a webview campaign variation. Matches the iOS
 * struct field-for-field including default values.
 */
data class WebViewDisplayRule(
    val priority: Int = 0,
    val maxShowTime: Int = 1,
    val intervalMinutes: Int = 0,
    val showAgainAfterDays: Int = 0,
    val expiresAt: Long = 0L
) {
    fun isExpired(): Boolean = expiresAt > 0 && System.currentTimeMillis() > expiresAt
    fun getIntervalMs(): Long = intervalMinutes * 60 * 1000L

    fun toJson(): String = try {
        JsonUtil.toJson(mapOf(
            "priority" to priority,
            "maxShowTime" to maxShowTime,
            "intervalMinutes" to intervalMinutes,
            "showAgainAfterDays" to showAgainAfterDays,
            "expiresAt" to expiresAt
        ))
    } catch (e: Exception) {
        SdkLog.w(TAG, "Failed to encode display rule", e); "{}"
    }

    companion object {
        private const val TAG = "AlgorithmX"

        fun fromConfigs(configs: Map<String, Any>?): WebViewDisplayRule {
            if (configs == null) return WebViewDisplayRule()
            return try {
                WebViewDisplayRule(
                    priority = (configs["priority"] as? Number)?.toInt() ?: 0,
                    maxShowTime = (configs["maxShowTime"] as? Number)?.toInt() ?: 1,
                    intervalMinutes = (configs["intervalMinutes"] as? Number)?.toInt() ?: 0,
                    showAgainAfterDays = (configs["showAgainAfterDays"] as? Number)?.toInt() ?: 0,
                    expiresAt = (configs["expiresAt"] as? Number)?.toLong() ?: 0L
                )
            } catch (e: Exception) {
                SdkLog.w(TAG, "Failed to parse configs, using defaults", e)
                WebViewDisplayRule()
            }
        }

        fun fromJson(jsonString: String?): WebViewDisplayRule {
            if (jsonString.isNullOrEmpty()) return WebViewDisplayRule()
            return try {
                @Suppress("UNCHECKED_CAST")
                val configs = JsonUtil.fromJson(jsonString) as? Map<String, Any>
                fromConfigs(configs)
            } catch (e: Exception) {
                SdkLog.w(TAG, "Failed to parse JSON configs", e)
                WebViewDisplayRule()
            }
        }
    }
}
