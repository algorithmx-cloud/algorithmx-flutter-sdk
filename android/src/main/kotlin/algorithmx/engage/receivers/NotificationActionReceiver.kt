package algorithmx.engage.receivers

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import algorithmx.engage.core.AlgorithmX
import algorithmx.engage.notifications.NotificationActionRouter
import algorithmx.engage.utils.SdkLog

/**
 * Receives action-button taps (forwarded by NotificationClickActivity), tracks
 * the interaction, and forwards the click to the partner-supplied
 * ActionButtonHandler. If no handler handled it, the notification's own
 * `action_type` runs, like iOS.
 */
class NotificationActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_BUTTON_CLICKED) {
            SdkLog.w(TAG, "Unexpected action: ${intent.action}")
            return
        }

        val buttonId = intent.getStringExtra(EXTRA_BUTTON_ID) ?: ""
        val actionText = intent.getStringExtra(EXTRA_ACTION_TEXT) ?: ""
        val buttonTitle = intent.getStringExtra(EXTRA_BUTTON_TITLE) ?: ""
        val notificationId = intent.getIntExtra(EXTRA_NOTIFICATION_ID, -1)

        val notificationData = mutableMapOf<String, Any>()
        intent.extras?.let { bundle ->
            for (key in bundle.keySet()) bundle.get(key)?.let { notificationData[key] = it }
        }

        if (notificationId != -1) {
            try {
                (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .cancel(notificationId)
            } catch (e: Exception) {
                SdkLog.e(TAG, "Failed to dismiss notification", e)
            }
        }

        (notificationData["algo_campaign_id"] as? String)?.let { campaignId ->
            val variationId = (notificationData["engage_variation_id"] as? String) ?: "default"
            AlgorithmX.trackCampaignInteraction(
                campaignId,
                variationId,
                "click",
                mapOf(
                    "notification_type" to "push",
                    "interaction_type" to "action_button",
                    "button_id" to buttonId,
                    "action_text" to actionText,
                    "button_title" to buttonTitle
                )
            )
        }

        (notificationData["algo_notification_id"] as? String)?.toIntOrNull()?.let { id ->
            AlgorithmX.updateNotificationStatus(id, AlgorithmX.NotificationEventStatus.OPENED)
        }

        val handled = AlgorithmX.handleActionButtonClick(context, buttonId, actionText, buttonTitle, notificationData)
        if (!handled) NotificationActionRouter.route(context, notificationData, trackOpen = false)
    }

    companion object {
        const val ACTION_BUTTON_CLICKED = "algorithmx.engage.ACTION_BUTTON_CLICKED"
        const val EXTRA_BUTTON_ID = "button_id"
        const val EXTRA_ACTION_TEXT = "action_text"
        const val EXTRA_BUTTON_TITLE = "button_title"
        const val EXTRA_NOTIFICATION_ID = "notification_id"
        private const val TAG = "AlgorithmX"
    }
}
