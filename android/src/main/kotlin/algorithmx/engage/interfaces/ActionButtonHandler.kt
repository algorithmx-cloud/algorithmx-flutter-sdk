package algorithmx.engage.interfaces

/**
 * Interface for handling notification action button clicks in client applications.
 * 
 * This interface allows client apps to define custom behavior for notification action buttons
 * in a similar way to DeepLinkHandler. If no handler is set, the SDK will handle standard
 * actions automatically.
 * 
 * Example usage:
 * ```
 * class MyApplication : Application(), ActionButtonHandler {
 *     override fun onCreate() {
 *         super.onCreate()
 *         AlgorithmX.initialize(this, "https://api.example.com", "your-partner-id")
 *         AlgorithmX.setActionButtonHandler(this)
 *     }
 *     
 *     override fun onActionButtonClicked(buttonId: String, actionText: String, title: String, notificationData: Map<String, Any>): Boolean {
 *         // Handle button click
 *         when (actionText) {
 *             "showSpecialOffer" -> {
 *                 // Navigate to special offer screen
 *                 return true // Handled
 *             }
 *             else -> return false // Let SDK handle it
 *         }
 *     }
 * }
 * ```
 */
interface ActionButtonHandler {
    
    /**
     * Called when an action button on a notification is clicked.
     * 
     * @param buttonId The unique ID of the button that was clicked
     * @param actionText The action text/identifier (e.g., "showSpecialOffer", "dismiss", etc.)
     * @param title The button title/label shown to the user
     * @param notificationData Complete notification data including campaign info, etc.
     * @return true if the action was handled by the client, false to let SDK handle it
     */
    fun onActionButtonClicked(
        buttonId: String,
        actionText: String,
        title: String,
        notificationData: Map<String, Any>
    ): Boolean
}
