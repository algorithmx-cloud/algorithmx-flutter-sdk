package algorithmx.engage.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import algorithmx.engage.utils.SdkLog

/**
 * Broadcast receiver for notification taps. Marshals the intent extras into a
 * map and delegates everything to NotificationActionRouter, so click handling
 * lives in exactly one place.
 */
class NotificationClickReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_CLICK) {
            SdkLog.w(TAG, "Unexpected action: ${intent.action}")
            return
        }
        intent.extras?.let { NotificationActionRouter.routeFromIntent(context, it) }
    }

    companion object {
        const val ACTION_CLICK = "com.engage.NOTIFICATION_CLICK"
        private const val TAG = "AlgorithmX"
    }
}
