package algorithmx.engage.interfaces

interface AlgoWebViewListener {
    fun onWebViewTrigger(campaignId: String, webviewUrl: String, dynamicContent: Map<String, Any>? = null)
}