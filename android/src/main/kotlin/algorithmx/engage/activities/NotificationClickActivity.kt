package algorithmx.engage.activities

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import algorithmx.engage.notifications.NotificationClickReceiver
import algorithmx.engage.receivers.NotificationActionReceiver
import algorithmx.engage.utils.SdkLog

/**
 * Transparent activity that bridges a notification tap to the SDK's
 * NotificationClickReceiver (body taps) or NotificationActionReceiver (action
 * buttons), then opens the app. Necessary because broadcasts sent from a killed
 * app can race the SDK's lifecycle observer, and because since Android 12 a
 * receiver started from a notification may not start activities.
 */
class NotificationClickActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val extras = intent.extras

        if (extras != null) {
            // Broadcast first so the SDK processes it regardless of app state.
            val broadcast = if (intent.action == NotificationActionReceiver.ACTION_BUTTON_CLICKED) {
                Intent(this, NotificationActionReceiver::class.java).apply {
                    action = NotificationActionReceiver.ACTION_BUTTON_CLICKED
                    putExtras(extras)
                }
            } else {
                Intent(this, NotificationClickReceiver::class.java).apply {
                    action = NotificationClickReceiver.ACTION_CLICK
                    putExtras(extras)
                }
            }
            sendBroadcast(broadcast)

            // Also open the partner's app, like iOS does on a tap. Launched the way
            // the home-screen icon does it (no package, NEW_TASK +
            // RESET_TASK_IF_NEEDED) so an existing task comes forward unchanged, a
            // killed app starts, and an app already in front stays as it is.
            // (A process-importance check can't be used here: this activity
            // itself is the foreground.)
            packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
                launch.setPackage(null)
                launch.putExtras(extras)
                // The broadcast already routed/tracked this tap. Keep the
                // original extras for the host app, but mark this launch so
                // SDK lifecycle callbacks do not route the same tap again.
                launch.putExtra(EXTRA_ALREADY_ROUTED, true)
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                startActivity(launch)
            }
        } else {
            SdkLog.w(TAG, "Notification click activity opened without extras")
        }
        finish()
    }

    companion object {
        const val EXTRA_ALREADY_ROUTED = "algorithmx_notification_already_routed"
        private const val TAG = "AlgorithmX"
    }
}
