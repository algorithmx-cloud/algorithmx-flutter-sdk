package algorithmx.engage.lifecycle

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Bundle
import algorithmx.engage.activities.NotificationClickActivity
import algorithmx.engage.core.AlgorithmX
import algorithmx.engage.notifications.NotificationActionRouter
import algorithmx.engage.utils.SdkLog
import java.util.concurrent.ConcurrentHashMap

/**
 * Automatically picks up notification intents on activity create / resume so the
 * partner doesn't have to wire `handleIntent` themselves, and tracks foreground /
 * background so queued campaigns show on the next app open (like iOS
 * `didBecomeActive`) without the partner calling `onAppBecameActive`.
 */
class ActivityLifecycleManager private constructor() : Application.ActivityLifecycleCallbacks {

    companion object {
        @Volatile private var instance: ActivityLifecycleManager? = null
        fun getInstance(): ActivityLifecycleManager =
            instance ?: synchronized(this) { instance ?: ActivityLifecycleManager().also { instance = it } }
        private const val TAG = "AlgorithmX"
        private const val MAX_TRACKED_INTENTS = 100
    }

    private var registered = false
    private val processed: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private var startedActivities = 0

    fun register(application: Application) {
        if (!registered) {
            application.registerActivityLifecycleCallbacks(this)
            registered = true
        }
    }

    fun unregister(application: Application) {
        if (registered) {
            application.unregisterActivityLifecycleCallbacks(this)
            registered = false
            processed.clear()
        }
    }

    fun handleNewIntent(activity: Activity, intent: Intent) {
        process(activity, intent)
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
        // Slight delay to let the AlgorithmX init complete if this is the first activity.
        activity.runOnUiThread {
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                process(activity, activity.intent)
            }, 100)
        }
    }

    override fun onActivityResumed(activity: Activity) { process(activity, activity.intent) }

    // The transparent NotificationClickActivity is not the app coming to the
    // foreground; the host activity it launches is counted instead.
    override fun onActivityStarted(activity: Activity) {
        if (activity is NotificationClickActivity) return
        startedActivities++
        if (startedActivities == 1) AlgorithmX.onAppBecameActive(activity)
    }

    override fun onActivityStopped(activity: Activity) {
        if (activity is NotificationClickActivity || startedActivities == 0) return
        startedActivities--
        if (startedActivities == 0) AlgorithmX.onAppWentBackground()
    }

    override fun onActivityPaused(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) {}

    private fun process(activity: Activity, intent: Intent?) {
        // NotificationClickActivity routes its own tap through the broadcast
        // receiver; processing its intent here would route the tap twice.
        if (activity is NotificationClickActivity) return
        val extras = intent?.extras ?: return
        // NotificationClickActivity has already broadcast and processed this
        // tap before launching the host Activity with its original extras.
        if (extras.getBoolean(NotificationClickActivity.EXTRA_ALREADY_ROUTED, false)) return
        // Only AlgorithmX notification taps; the host's own intents are never touched.
        if (!NotificationActionRouter.isAlgorithmXExtras(extras)) return

        val key = "${intent.hashCode()}_${extras.hashCode()}"
        if (!processed.add(key)) return

        try {
            NotificationActionRouter.routeFromIntent(activity, extras)
            // Clear so re-resume doesn't re-process.
            intent.replaceExtras(Bundle())
        } catch (e: Exception) {
            SdkLog.e(TAG, "Failed to route lifecycle intent", e)
        }

        if (processed.size > MAX_TRACKED_INTENTS) {
            val iterator = processed.iterator()
            repeat(MAX_TRACKED_INTENTS / 2) {
                if (iterator.hasNext()) { iterator.next(); iterator.remove() }
            }
        }
    }
}
