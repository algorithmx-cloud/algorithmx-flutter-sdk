package algorithmx.engage.activities

import android.annotation.SuppressLint
import android.os.Bundle
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.ProgressBar
import androidx.appcompat.app.AppCompatActivity
import algorithmx.engage.R
import algorithmx.engage.core.AlgorithmX
import algorithmx.engage.utils.JsonUtil
import algorithmx.engage.utils.SdkLog
import algorithmx.engage.utils.SdkPayload

/**
 * Hosts the campaign WebView. Mirrors iOS `CampaignViewController`:
 *
 *   - Impression tracked once the page has finished loading (onPageFinished),
 *     NOT on activity create. Display history recorded in the same place.
 *   - `closeDismiss` reported when a shown campaign is destroyed without a
 *     JS-bridge close or submit (a campaign that never loaded reports nothing).
 *   - Bridge interactions forward the template's own fields plus `timestamp`
 *     and `source`, exactly like iOS. The template owns the close button.
 */
class CampaignActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_CAMPAIGN_ID = "extra_campaign_id"
        const val EXTRA_VARIATION_ID = "extra_variation_id"
        const val EXTRA_URL = "extra_url"
        const val EXTRA_DYNAMIC_CONTENT = "extra_dynamic_content"
        const val EXTRA_EXPIRES_AT = "extra_expires_at"
        private const val INTERACTION_ENDPOINT = "/api/v1/tracks/algoViewInteract"
        private const val TAG = "AlgorithmX"
    }

    private lateinit var webView: WebView
    private lateinit var progressBar: ProgressBar
    private var campaignId: String? = null
    private var variationId: String? = null
    private var trackedExplicitClose: Boolean = false
    private var shown: Boolean = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AlgorithmX.setWebViewShowing(true)
        setContentView(R.layout.activity_campaign)

        webView = findViewById(R.id.campaignWebView)
        progressBar = findViewById(R.id.progressBar)

        val url = intent.getStringExtra(EXTRA_URL)
        // Dynamic placeholders are optional. An empty bundle still lets the
        // HTML load and makes `${{key|fallback}}` use its fallback text.
        val dynamicContent = intent.getBundleExtra(EXTRA_DYNAMIC_CONTENT) ?: Bundle()
        campaignId = intent.getStringExtra(EXTRA_CAMPAIGN_ID)
        variationId = intent.getStringExtra(EXTRA_VARIATION_ID)

        webView.settings.javaScriptEnabled = true
        webView.addJavascriptInterface(Bridge(), "EngageBridge")
        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                super.onProgressChanged(view, newProgress)
                if (newProgress == 100) {
                    progressBar.visibility = View.GONE
                    webView.visibility = View.VISIBLE
                }
            }
        }

        if (url.isNullOrEmpty()) {
            SdkLog.w(TAG, "Missing URL; closing CampaignActivity")
            finish()
            return
        }

        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, pageUrl: String?) {
                super.onPageFinished(view, pageUrl)
                if (shown) return
                shown = true
                // HTML loaded — now (and only now) record impression and display.
                val cId = campaignId; val vId = variationId
                if (!cId.isNullOrEmpty() && !vId.isNullOrEmpty()) {
                    val expiresAt = intent.getLongExtra(EXTRA_EXPIRES_AT, 0L)
                    val impressionPayload = mutableMapOf<String, Any>(
                        "url" to url,
                        "timestamp" to System.currentTimeMillis()
                    )
                    if (!dynamicContent.isEmpty) {
                        impressionPayload["dynamicContent"] = dynamicContent.keySet().associateWith { key ->
                            dynamicContent.getString(key) ?: ""
                        }
                    }
                    AlgorithmX.trackCampaignInteraction(
                        cId, vId, "impression", impressionPayload, endpoint = INTERACTION_ENDPOINT
                    )
                    AlgorithmX.recordWebViewDisplaySuccess(cId, vId, expiresAt)
                }
            }
        }

        Thread {
            try {
                val raw = java.net.URL(url).readText()
                var modified = Regex("\\$\\{\\{([^}]+)\\}\\}").replace(raw) { match ->
                    val parts = match.groupValues[1].split("|", limit = 2)
                    val key = parts[0].trim()
                    val fallback = if (parts.size > 1) parts[1] else null
                    val value = dynamicContent.getString(key)
                    if (!value.isNullOrBlank()) value else (fallback ?: "")
                }
                variationId?.let { modified = modified.replace("\${variationId}", it) }

                runOnUiThread {
                    webView.loadDataWithBaseURL(url, modified, "text/html", "utf-8", null)
                }
            } catch (e: Exception) {
                SdkLog.e(TAG, "Failed to load campaign HTML", e)
                runOnUiThread { finish() }
            }
        }.start()
    }

    override fun onDestroy() {
        super.onDestroy()
        if (shown && !trackedExplicitClose) {
            val cId = campaignId; val vId = variationId
            if (!cId.isNullOrEmpty() && !vId.isNullOrEmpty()) {
                AlgorithmX.trackCampaignInteraction(
                    cId, vId, "closeDismiss",
                    mapOf("reason" to "viewDismissed", "timestamp" to System.currentTimeMillis()),
                    endpoint = INTERACTION_ENDPOINT
                )
            }
        }
        AlgorithmX.setWebViewShowing(false)
    }

    inner class Bridge {
        @JavascriptInterface
        fun postMessage(json: String) {
            @Suppress("UNCHECKED_CAST")
            val data = (JsonUtil.fromJson(json) as? Map<String, Any>) ?: return
            val event = data["event"] as? String ?: return
            val cId = campaignId; val vId = variationId

            // Same payload as iOS: the template's fields, plus timestamp and source.
            val payload = (data - "event").toMutableMap<String, Any>().apply {
                put("timestamp", System.currentTimeMillis())
                put("source", "javascript")
            }

            when (SdkPayload.builtInEvent(event)) {
                "campaignClose" -> {
                    trackedExplicitClose = true
                    if (!cId.isNullOrEmpty() && !vId.isNullOrEmpty()) {
                        AlgorithmX.trackCampaignInteraction(cId, vId, "close", payload, endpoint = INTERACTION_ENDPOINT)
                    }
                    runOnUiThread { finish() }
                }
                "campaignClick" -> {
                    if (!cId.isNullOrEmpty() && !vId.isNullOrEmpty()) {
                        AlgorithmX.trackCampaignInteraction(cId, vId, "click", payload, endpoint = INTERACTION_ENDPOINT)
                    }
                }
                "campaignSubmit" -> {
                    trackedExplicitClose = true
                    if (!cId.isNullOrEmpty() && !vId.isNullOrEmpty()) {
                        AlgorithmX.trackCampaignInteraction(cId, vId, "submit", payload, endpoint = INTERACTION_ENDPOINT)
                    }
                    runOnUiThread { finish() }
                }
                "campaignCouponCopy", "copyCoupon" -> {
                    if (!cId.isNullOrEmpty() && !vId.isNullOrEmpty()) {
                        val couponCode = pickCouponCode(data)?.trim()
                        if (!couponCode.isNullOrEmpty()) {
                            val clipboard = getSystemService(android.content.Context.CLIPBOARD_SERVICE)
                                as? android.content.ClipboardManager
                            clipboard?.setPrimaryClip(android.content.ClipData.newPlainText("Coupon Code", couponCode))
                            payload["couponCode"] = couponCode
                        }
                        AlgorithmX.trackCampaignInteraction(cId, vId, "copy", payload, endpoint = INTERACTION_ENDPOINT)
                    }
                }
                else -> {
                    // Unknown event: forward as a generic track. Mirrors iOS.
                    AlgorithmX.trackEvent(event, data)
                }
            }
        }

        // Text values only, same as iOS.
        private fun pickCouponCode(data: Map<String, Any>): String? {
            val direct = listOf("couponCode", "coupon_code", "coupon", "code", "text")
                .firstNotNullOfOrNull { data[it] as? String }
            if (direct != null) return direct
            val payload = data["payload"] as? Map<*, *> ?: return null
            return listOf("couponCode", "coupon_code", "coupon", "code", "text")
                .firstNotNullOfOrNull { payload[it] as? String }
        }
    }
}
