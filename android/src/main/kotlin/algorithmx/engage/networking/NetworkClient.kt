package algorithmx.engage.networking

import algorithmx.engage.utils.JsonUtil
import algorithmx.engage.utils.SdkLog
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * HTTP transport for the SDK. Synchronous calls dispatched from EventDispatcher's
 * IO coroutine scope. Timeouts mirror iOS: 10s connect, 30s read.
 * Every request carries the partner ID in the `x-partner-id` header.
 */
object NetworkClient {
    private const val TAG = "AlgorithmX"
    private const val PARTNER_ID_HEADER = "x-partner-id"
    private val jsonMediaType = "application/json; charset=utf-8".toMediaTypeOrNull()

    /** Set by `AlgorithmX.initialize`. */
    @Volatile var partnerId: String = ""

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    fun postJson(url: String, body: Any, headers: Map<String, String> = emptyMap()) {
        try {
            val req = Request.Builder().url(url)
                .header(PARTNER_ID_HEADER, partnerId)
                .apply { headers.forEach { (name, value) -> header(name, value) } }
                .post(JsonUtil.toJson(body).toRequestBody(jsonMediaType))
                .build()
            client.newCall(req).execute().use { res ->
                if (!res.isSuccessful) {
                    SdkLog.e(TAG, "POST $url failed: ${res.code} ${res.message}")
                } else {
                    SdkLog.d(TAG, "POST status=${res.code} url=$url")
                }
            }
        } catch (e: Exception) {
            SdkLog.e(TAG, "POST $url threw", e)
        }
    }

    fun putJson(url: String, body: Any, headers: Map<String, String> = emptyMap()) {
        try {
            val req = Request.Builder().url(url)
                .header(PARTNER_ID_HEADER, partnerId)
                .apply { headers.forEach { (name, value) -> header(name, value) } }
                .put(JsonUtil.toJson(body).toRequestBody(jsonMediaType))
                .build()
            client.newCall(req).execute().use { res ->
                if (!res.isSuccessful) {
                    SdkLog.e(TAG, "PUT $url failed: ${res.code} ${res.message}")
                } else {
                    SdkLog.d(TAG, "PUT status=${res.code} url=$url")
                }
            }
        } catch (e: Exception) {
            SdkLog.e(TAG, "PUT $url threw", e)
        }
    }

    fun inAppViewsUrl(baseUrl: String, language: String, customerId: String): String =
        "${baseUrl.trimEnd('/')}/api/v1/inAppViews".toHttpUrl().newBuilder()
            .addQueryParameter("language", language).addQueryParameter("customerId", customerId).build().toString()

    @Suppress("UNCHECKED_CAST")
    fun getJsonArray(url: String, headers: Map<String, String>): List<Map<String, Any>> {
        val request = Request.Builder().url(url).header(PARTNER_ID_HEADER, partnerId)
            .header("Accept", "application/json").header("Cache-Control", "no-cache")
            .apply { headers.forEach { (key, value) -> header(key, value) } }.get().build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw HttpFailure(response.code)
            return JsonUtil.fromJsonArray(response.body?.string() ?: "")
        }
    }

    class HttpFailure(val status: Int) : Exception("Backend returned HTTP $status")

    fun getJson(url: String): Any? {
        return try {
            val req = Request.Builder().url(url)
                .header(PARTNER_ID_HEADER, partnerId)
                .get()
                .build()
            client.newCall(req).execute().use { res ->
                val body = res.body?.string() ?: return null
                JsonUtil.fromJson(body)
            }
        } catch (e: Exception) {
            SdkLog.e(TAG, "GET $url threw", e); null
        }
    }
}
