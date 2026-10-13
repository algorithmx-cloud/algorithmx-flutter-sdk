package algorithmx.engage.events

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import algorithmx.engage.networking.NetworkClient
import algorithmx.engage.utils.SdkLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.channels.Channel

/**
 * Fire-and-forget HTTP dispatcher. Events sent while offline are dropped — there
 * is no persistent queue. (The name "EventQueue" was historical and misleading.)
 *
 * If real offline support is added later, replace this with a SQLite-backed queue
 * keeping the same `send(...)` signature so callers don't change.
 */
class EventDispatcher(private val context: Context) {
    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private data class PendingRequest(val endpoint: String, val method: String, val payload: Any, val headers: Map<String, String>, val arrayResult: ((Result<List<Map<String, Any>>>) -> Unit)? = null)
    private val requests = Channel<PendingRequest>(Channel.UNLIMITED)

    init {
        scope.launch {
            for (request in requests) {
                if (!isNetworkAvailable()) {
                    SdkLog.w(TAG, "Network unavailable; dropping request to ${request.endpoint}")
                    request.arrayResult?.invoke(Result.failure(java.io.IOException("Network unavailable")))
                    continue
                }
                when (request.method) {
                    "GET_ARRAY" -> request.arrayResult?.invoke(runCatching { NetworkClient.getJsonArray(request.endpoint, request.headers) })
                    "POST" -> NetworkClient.postJson(request.endpoint, request.payload, request.headers)
                    "PUT" -> NetworkClient.putJson(request.endpoint, request.payload, request.headers)
                    "GET" -> NetworkClient.getJson(request.endpoint)
                    else -> SdkLog.e(TAG, "Unsupported method: ${request.method}")
                }
            }
        }
    }

    fun send(
        endpoint: String, method: String = "POST", payload: Any? = null,
        headers: Map<String, String> = emptyMap()
    ) {
        if (!isNetworkAvailable()) {
            SdkLog.w(TAG, "Network unavailable; dropping request to $endpoint")
            return
        }
        requests.trySend(PendingRequest(endpoint, method, payload ?: emptyMap<String, Any>(),
            mapOf("x-partner-id" to NetworkClient.partnerId) + headers))
    }

    fun getJsonArray(endpoint: String, headers: Map<String, String>, callback: (Result<List<Map<String, Any>>>) -> Unit) {
        requests.trySend(PendingRequest(endpoint, "GET_ARRAY", emptyMap<String, Any>(),
            mapOf("x-partner-id" to NetworkClient.partnerId) + headers, callback))
    }

    fun destroy() { requests.close(); scope.cancel() }

    private fun isNetworkAvailable(): Boolean {
        return if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
            val active = connectivityManager.activeNetwork ?: return false
            val caps = connectivityManager.getNetworkCapabilities(active) ?: return false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        } else {
            @Suppress("DEPRECATION")
            connectivityManager.activeNetworkInfo?.isConnected == true
        }
    }

    companion object { private const val TAG = "AlgorithmX" }
}
