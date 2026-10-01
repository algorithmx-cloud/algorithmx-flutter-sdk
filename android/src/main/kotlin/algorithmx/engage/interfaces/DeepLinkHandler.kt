package algorithmx.engage.interfaces

import android.net.Uri

/**
 * Interface for handling deep link actions in client applications.
 * 
 * This interface allows advanced clients to intercept deep links before
 * the SDK automatically fires the intent. If no handler is set, the SDK
 * will fire the intent directly using Intent.ACTION_VIEW.
 */
interface DeepLinkHandler {
    
    /**
     * Called when a deep link is about to be processed.
     * 
     * @param uri The deep link URI to be processed
     * @return true if the deep link was handled by the client, false to let SDK handle it
     */
    fun onDeepLinkReceived(uri: Uri): Boolean
}