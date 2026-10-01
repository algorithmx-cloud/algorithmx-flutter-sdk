package algorithmx.engage.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import androidx.core.app.NotificationCompat
import algorithmx.engage.activities.NotificationClickActivity
import algorithmx.engage.core.AlgorithmX
import algorithmx.engage.receivers.NotificationActionReceiver
import algorithmx.engage.utils.SdkLog
import java.net.URL
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray

/**
 * Builds and displays the visual notification for `processNormalNotification`.
 * Handles BigPicture image attachment and dynamic action buttons parsed from
 * the `action_buttons` JSON array in the FCM payload.
 */
class EngageNotificationManager {

    fun handleNormalNotification(
        context: Context,
        data: Map<String, String>,
        title: String? = null,
        body: String? = null
    ) {
        val nTitle = title ?: data["title"] ?: "Notification"
        val nBody = body ?: data["body"] ?: ""
        // Same image keys as the iOS Notification Service Extension.
        val imageUrl = data["image"] ?: data["imageUrl"] ?: data["image_url"] ?: data["engage_meta_image_url"]
        // One Android notification per AlgorithmX notification id (no accidental overwrites).
        val notificationId = data["algo_notification_id"]?.toIntOrNull()?.let { NOTIFICATION_ID_BASE + it }
            ?: (NOTIFICATION_ID_BASE + System.currentTimeMillis().toInt() % 10000)

        if (!imageUrl.isNullOrEmpty()) {
            CoroutineScope(Dispatchers.IO).launch {
                val bitmap = try { loadImageFromUrl(imageUrl) } catch (e: Exception) { null }
                withContext(Dispatchers.Main) {
                    showNotification(context, data, nTitle, nBody, bitmap, notificationId)
                }
            }
        } else {
            showNotification(context, data, nTitle, nBody, null, notificationId)
        }
    }

    private fun showNotification(
        context: Context,
        data: Map<String, String>,
        title: String,
        body: String,
        bitmap: Bitmap?,
        notificationId: Int
    ) {
        createChannel(context)

        val click = Intent(context, NotificationClickActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            data.forEach { (k, v) -> putExtra(k, v) }
        }
        val pi = PendingIntent.getActivity(
            context, System.currentTimeMillis().toInt(), click,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(AlgorithmX.getSmallIconResId())
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)

        bitmap?.let {
            builder.setLargeIcon(it).setStyle(
                NotificationCompat.BigPictureStyle().bigPicture(it).bigLargeIcon(null as Bitmap?)
            )
        }

        addActionButtons(context, builder, data, notificationId)

        val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        mgr.notify(notificationId, builder.build())

        data["algo_campaign_id"]?.let { campaignId ->
            val variationId = data["engage_variation_id"] ?: "default"
            AlgorithmX.trackCampaignInteraction(
                campaignId, variationId, "impression",
                mapOf(
                    "notification_type" to "push",
                    "title" to title,
                    "body" to body,
                    "has_image" to (bitmap != null)
                )
            )
        }
    }

    private suspend fun loadImageFromUrl(urlString: String): Bitmap? = withContext(Dispatchers.IO) {
        try {
            val conn = URL(urlString).openConnection().apply { doInput = true; connect() }
            BitmapFactory.decodeStream(conn.getInputStream())
        } catch (e: Exception) { SdkLog.e(TAG, "Image download failed", e); null }
    }

    private fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "AlgorithmX in-app SDK notifications"
                enableLights(true); enableVibration(true)
            }
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
    }

    private fun addActionButtons(
        context: Context,
        builder: NotificationCompat.Builder,
        data: Map<String, String>,
        notificationId: Int
    ) {
        val buttonsJson = data["action_buttons"] ?: return
        if (buttonsJson.isBlank() || buttonsJson == "[]") return

        try {
            // Same rules as iOS: at most 3 buttons (all Android shows), `title` and
            // `action_text` required, `id` defaults to action_<index>.
            val arr = JSONArray(buttonsJson)
            for (i in 0 until minOf(arr.length(), MAX_ACTION_BUTTONS)) {
                val obj = arr.optJSONObject(i) ?: continue
                val actionText = obj.optString("action_text").takeIf { it.isNotEmpty() } ?: continue
                val title = obj.optString("title").takeIf { it.isNotEmpty() } ?: continue
                val buttonId = obj.optString("id").takeIf { it.isNotEmpty() } ?: "action_$i"

                // Buttons open NotificationClickActivity, which forwards to
                // NotificationActionReceiver and opens the app. A broadcast
                // PendingIntent can't: since Android 12 a receiver started from a
                // notification may not start activities ("trampoline").
                val intent = Intent(context, NotificationClickActivity::class.java).apply {
                    action = NotificationActionReceiver.ACTION_BUTTON_CLICKED
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    putExtra(NotificationActionReceiver.EXTRA_BUTTON_ID, buttonId)
                    putExtra(NotificationActionReceiver.EXTRA_ACTION_TEXT, actionText)
                    putExtra(NotificationActionReceiver.EXTRA_BUTTON_TITLE, title)
                    putExtra(NotificationActionReceiver.EXTRA_NOTIFICATION_ID, notificationId)
                    data.forEach { (k, v) -> putExtra(k, v) }
                }
                val pi = PendingIntent.getActivity(
                    context, notificationId + i, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                builder.addAction(0, title, pi)
            }
        } catch (e: Exception) {
            SdkLog.e(TAG, "Failed to parse action buttons", e)
        }
    }

    companion object {
        private const val TAG = "AlgorithmX"
        private const val CHANNEL_ID = "algorithmx_notifications"
        private const val CHANNEL_NAME = "AlgorithmX Notifications"
        private const val NOTIFICATION_ID_BASE = 10000
        private const val MAX_ACTION_BUTTONS = 3
    }
}
