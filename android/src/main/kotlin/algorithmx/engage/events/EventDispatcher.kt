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

    fun send(endpoint: String, method: String = "POST", payload: Map<String, Any>? = null) {
        if (!isNetworkAvailable()) {
            SdkLog.w(TAG, "Network unavailable; dropping request to $endpoint")
            return
        }
        scope.launch {
            try {
                val body = payload ?: emptyMap()
                when (method) {
                    "POST" -> NetworkClient.postJson(endpoint, body)
                    "PUT" -> NetworkClient.putJson(endpoint, body)
                    "GET" -> NetworkClient.getJson(endpoint)
                    else -> SdkLog.e(TAG, "Unsupported method: $method")
                }
            } catch (e: Exception) {
                SdkLog.e(TAG, "Request to $endpoint failed", e)
            }
        }
    }

    fun destroy() { scope.cancel() }

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
