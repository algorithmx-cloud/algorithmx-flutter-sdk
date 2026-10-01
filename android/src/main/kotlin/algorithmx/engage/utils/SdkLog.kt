package algorithmx.engage.utils

import android.util.Log

/**
 * Centralized SDK logger. Single tag prefix, single switch to mute in release.
 */
object SdkLog {
    /** Debug/info logging, set with `AlgorithmX.setLoggingEnabled`. Warnings and errors are always logged. */
    var enabled: Boolean = false

    fun d(tag: String, message: String) {
        if (enabled) Log.d(tag, message)
    }

    fun i(tag: String, message: String) {
        if (enabled) Log.i(tag, message)
    }

    fun w(tag: String, message: String, throwable: Throwable? = null) {
        if (throwable != null) Log.w(tag, message, throwable) else Log.w(tag, message)
    }

    fun e(tag: String, message: String, throwable: Throwable? = null) {
        if (throwable != null) Log.e(tag, message, throwable) else Log.e(tag, message)
    }
}
