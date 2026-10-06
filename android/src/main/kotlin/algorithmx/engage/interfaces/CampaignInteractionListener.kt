package algorithmx.engage.interfaces

/**
 * Observe campaign interactions (impression / click / submit / copy / close /
 * closeDismiss) as they are tracked by the SDK.
 */
interface CampaignInteractionListener {
    fun onCampaignInteraction(
        campaignId: String,
        variationId: String,
        interactionType: String,
        payload: Map<String, Any>
    )
}
