package algorithmx.engage.networking

import algorithmx.engage.utils.JsonUtil
import algorithmx.engage.utils.SdkLog
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * HTTP transport for the SDK. Synchronous calls dispatched from EventDispatcher's
 * IO coroutine scope. Timeouts mirror iOS: 10s connect, 30s read.
 */
object NetworkClient {
    private const val TAG = "AlgorithmX"
    private val jsonMediaType = "application/json; charset=utf-8".toMediaTypeOrNull()

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    fun postJson(url: String, body: Any) {
        try {
            val req = Request.Builder().url(url)
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

    fun putJson(url: String, body: Any) {
        try {
            val req = Request.Builder().url(url)
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

    fun getJson(url: String): Any? {
        return try {
            val req = Request.Builder().url(url).get().build()
            client.newCall(req).execute().use { res ->
                val body = res.body?.string() ?: return null
                JsonUtil.fromJson(body)
            }
        } catch (e: Exception) {
            SdkLog.e(TAG, "GET $url threw", e); null
        }
    }
}
