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
import algorithmx.engage.webview.InAppDisplay

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
        const val EXTRA_IN_APP_TOKEN = "extra_in_app_token"
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
    private var apiDisplay: InAppDisplay? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AlgorithmX.setWebViewShowing(true)
        setContentView(R.layout.activity_campaign)

        webView = findViewById(R.id.campaignWebView)
        progressBar = findViewById(R.id.progressBar)

        val token = intent.getStringExtra(EXTRA_IN_APP_TOKEN)
        apiDisplay = token?.let { AlgorithmX.inAppDisplay(it) }
        if (token != null && apiDisplay == null) { finish(); return }
        if (apiDisplay != null) AlgorithmX.attachInAppActivity(this)
        shown = savedInstanceState?.getBoolean("shown") ?: false
        trackedExplicitClose = savedInstanceState?.getBoolean("trackedExplicitClose") ?: false
        val url = apiDisplay?.baseUrl ?: intent.getStringExtra(EXTRA_URL)
        // Dynamic placeholders are optional. An empty bundle still lets the
        // HTML load and makes `${{key|fallback}}` use its fallback text.
        val dynamicContent = apiDisplay?.variation?.parameters?.let { parameters ->
            Bundle().apply { parameters.forEach { (key, value) -> putString(key, dynamicText(value)) } }
        } ?: intent.getBundleExtra(EXTRA_DYNAMIC_CONTENT) ?: Bundle()
        campaignId = apiDisplay?.view?.campaignId ?: intent.getStringExtra(EXTRA_CAMPAIGN_ID)
        variationId = apiDisplay?.variation?.id ?: intent.getStringExtra(EXTRA_VARIATION_ID)

        webView.settings.javaScriptEnabled = true
        webView.addJavascriptInterface(Bridge(), "EngageBridge")
        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                super.onProgressChanged(view, newProgress)
                if (newProgress == 100 && apiDisplay == null) {
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
                val loaded = {
                    progressBar.visibility = View.GONE
                    webView.visibility = View.VISIBLE
                    if (!shown && !isFinishing) {
                        shown = true
                        val cId = campaignId; val vId = variationId
                        if (!cId.isNullOrEmpty() && !vId.isNullOrEmpty()) {
                            val impressionPayload = mutableMapOf<String, Any>("url" to url, "timestamp" to System.currentTimeMillis())
                            if (!dynamicContent.isEmpty) impressionPayload["dynamicContent"] = dynamicContent.keySet().associateWith {
                                dynamicContent.getString(it) ?: ""
                            }
                            trackInteraction(cId, vId, "impression", impressionPayload, INTERACTION_ENDPOINT)
                            val display = apiDisplay
                            if (display != null) AlgorithmX.recordInAppDisplaySuccess(display)
                            else AlgorithmX.recordWebViewDisplaySuccess(cId, vId, intent.getLongExtra(EXTRA_EXPIRES_AT, 0L))
                        }
                    }
                }
                val display = apiDisplay
                if (display != null) view?.evaluateJavascript(display.variation.template.translationScript(display.view.language)) { loaded() }
                else loaded()
            }
        }

        apiDisplay?.let { display ->
            val html = resolveHtml(display.variation.template.document, dynamicContent)
            webView.loadDataWithBaseURL(url.trimEnd('/') + "/", html, "text/html", "utf-8", null)
            return
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

    private fun resolveHtml(html: String, content: Bundle): String {
        val resolved = Regex("\\$\\{\\{([^}]+)\\}\\}").replace(html) { match ->
            val parts = match.groupValues[1].split("|", limit = 2)
            content.getString(parts[0].trim())?.takeIf { it.isNotBlank() } ?: parts.getOrNull(1).orEmpty()
        }
        return resolved.replace("\${variationId}", variationId.orEmpty())
    }

    private fun dynamicText(value: Any): String = when (value) {
        is String -> value
        is Map<*, *>, is List<*> -> JsonUtil.toJson(value)
        is Double -> if (value % 1.0 == 0.0) value.toLong().toString() else value.toString()
        else -> value.toString()
    }

    private fun trackInteraction(campaign: String, variation: String, type: String,
        payload: Map<String, Any>, endpoint: String) {
        val display = apiDisplay
        if (display != null) AlgorithmX.trackInAppInteraction(display, type, payload)
        else AlgorithmX.trackCampaignInteraction(campaign, variation, type, payload, endpoint = endpoint)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("shown", shown)
        outState.putBoolean("trackedExplicitClose", trackedExplicitClose)
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        super.onDestroy()
        if (isChangingConfigurations) return
        if (shown && !trackedExplicitClose) {
            val cId = campaignId; val vId = variationId
            if (!cId.isNullOrEmpty() && !vId.isNullOrEmpty()) {
                trackInteraction(
                    cId, vId, "closeDismiss",
                    mapOf("reason" to "viewDismissed", "timestamp" to System.currentTimeMillis()),
                    endpoint = INTERACTION_ENDPOINT
                )
            }
        }
        apiDisplay?.let { AlgorithmX.completeInAppDisplay(it.token) }
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
                        trackInteraction(cId, vId, "close", payload, endpoint = INTERACTION_ENDPOINT)
                    }
                    runOnUiThread { finish() }
                }
                "campaignClick" -> {
                    if (!cId.isNullOrEmpty() && !vId.isNullOrEmpty()) {
                        trackInteraction(cId, vId, "click", payload, endpoint = INTERACTION_ENDPOINT)
                    }
                }
                "campaignSubmit" -> {
                    trackedExplicitClose = true
                    if (!cId.isNullOrEmpty() && !vId.isNullOrEmpty()) {
                        trackInteraction(cId, vId, "submit", payload, endpoint = INTERACTION_ENDPOINT)
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
                        trackInteraction(cId, vId, "copy", payload, endpoint = INTERACTION_ENDPOINT)
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
