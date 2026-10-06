package algorithmx.engage.utils

import com.google.gson.JsonParser

/** Compatibility aliases for SDK-owned fields only; custom payloads are never changed. */
internal object SdkPayload {
    private val notificationKeyAliases = mapOf(
        "engage_action" to "engageAction",
        "algo_campaign_id" to "algoCampaignId",
        "algo_notification_id" to "algoNotificationId",
        "engage_variation_id" to "engageVariationId",
        "engage_webview_url" to "engageWebviewUrl",
        "engage_user_id" to "engageUserId",
        "engage_dynamic_content" to "engageDynamicContent",
        "engage_meta_image_url" to "engageMetaImageUrl",
        "action_type" to "actionType",
        "action_buttons" to "actionButtons",
        "action_text" to "actionText",
        "image_url" to "imageUrl",
        "notification_type" to "notificationType",
        "interaction_type" to "interactionType",
        "button_id" to "buttonId",
        "button_title" to "buttonTitle",
        "notification_id" to "notificationId",
        "has_image" to "hasImage"
    )

    private val actionAliases = mapOf(
        "algo_trigger_webview" to "algoTriggerWebview",
        "algo_show_notification" to "algoShowNotification",
        "open_web_page" to "openWebPage",
        "open_webview" to "openWebview",
        "open_screen" to "openScreen",
        "custom_action" to "customAction"
    )

    private val eventAliases = mapOf(
        "campaign_close" to "campaignClose",
        "campaign_click" to "campaignClick",
        "campaign_submit" to "campaignSubmit",
        "campaign_coupon_copy" to "campaignCouponCopy",
        "copy_coupon" to "copyCoupon"
    )

    /** Canonical fields win over aliases. Nested custom data and action text stay intact. */
    fun <T> notification(data: Map<String, T>): Map<String, T> {
        val result = data.toMutableMap()
        notificationKeyAliases.forEach { (legacy, canonical) ->
            if (data.containsKey(legacy) && !data.containsKey(canonical)) {
                result[canonical] = data.getValue(legacy)
            }
            result.remove(legacy)
        }
        listOf("engageAction", "actionType").forEach { key ->
            val value = result[key] as? String
            actionAliases[value]?.let { canonical ->
                @Suppress("UNCHECKED_CAST")
                result[key] = canonical as T
            }
        }
        if (result.containsKey("actionButtons")) {
            @Suppress("UNCHECKED_CAST")
            result["actionButtons"] = actionButtons(result["actionButtons"]) as T
        }
        return result
    }

    /** Only actionText belongs to the SDK inside a button; its value remains custom. */
    private fun actionButtons(value: Any?): Any? = when (value) {
        is String -> try {
            val parsed = JsonParser.parseString(value)
            if (!parsed.isJsonArray) value else {
                var changed = false
                parsed.asJsonArray.forEach { element ->
                    if (element.isJsonObject) {
                        val button = element.asJsonObject
                        if (button.has("action_text")) {
                            if (!button.has("actionText")) button.add("actionText", button.get("action_text"))
                            button.remove("action_text")
                            changed = true
                        }
                    }
                }
                if (changed) parsed.toString() else value
            }
        } catch (_: Exception) { value }
        is List<*> -> value.map { button ->
            if (button is Map<*, *> && button.containsKey("action_text")) {
                button.toMutableMap().apply {
                    if (!button.containsKey("actionText")) put("actionText", button["action_text"])
                    remove("action_text")
                }
            } else button
        }
        else -> value
    }

    /** Used only to route the built-in WebView bridge events. */
    fun builtInEvent(event: String): String = eventAliases[event] ?: event
}
