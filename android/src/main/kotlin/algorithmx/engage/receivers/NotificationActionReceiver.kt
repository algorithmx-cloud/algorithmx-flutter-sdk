package algorithmx.engage.receivers

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import algorithmx.engage.core.AlgorithmX
import algorithmx.engage.notifications.NotificationActionRouter
import algorithmx.engage.utils.SdkLog
import algorithmx.engage.utils.SdkPayload

/**
 * Receives action-button taps (forwarded by NotificationClickActivity), tracks
 * the interaction, and forwards the click to the partner-supplied
 * ActionButtonHandler. If no handler handled it, the notification's own
 * `actionType` runs, like iOS.
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

        val rawNotificationData = mutableMapOf<String, Any>()
        intent.extras?.let { bundle ->
            for (key in bundle.keySet()) bundle.get(key)?.let { rawNotificationData[key] = it }
        }
        val notificationData = SdkPayload.notification(rawNotificationData)

        if (notificationId != -1) {
            try {
                (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .cancel(notificationId)
            } catch (e: Exception) {
                SdkLog.e(TAG, "Failed to dismiss notification", e)
            }
        }

        (notificationData["algoCampaignId"] as? String)?.let { campaignId ->
            val variationId = (notificationData["engageVariationId"] as? String) ?: "default"
            AlgorithmX.trackCampaignInteraction(
                campaignId,
                variationId,
                "click",
                mapOf(
                    "notificationType" to "push",
                    "interactionType" to "actionButton",
                    "buttonId" to buttonId,
                    "actionText" to actionText,
                    "buttonTitle" to buttonTitle
                )
            )
        }

        (notificationData["algoNotificationId"] as? String)?.toIntOrNull()?.let { id ->
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
