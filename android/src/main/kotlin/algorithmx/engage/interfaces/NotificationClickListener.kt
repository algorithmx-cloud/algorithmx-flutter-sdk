package algorithmx.engage.interfaces

/**
 * Handle notification clicks. Matches iOS protocol shape.
 *
 * Implementation order:
 * 1. SDK pre-processes the notification (status update, campaign click tracking).
 * 2. `onNotificationClick` is called. Return `true` if you handled the action;
 *    `false` to let the SDK fall through to its default action router.
 * 3. For `customAction` notifications, `onCustomAction` is called with the
 *    parsed action key from `actionData`.
 */
interface NotificationClickListener {

    fun onNotificationClick(data: Map<String, Any>): Boolean

    fun onCustomAction(action: String?, data: Map<String, Any>): Boolean = false

    fun onActionHandled(action: String, data: Map<String, Any>) {}
}
