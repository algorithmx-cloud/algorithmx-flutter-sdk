package algorithmx.engage.core

internal object IdentityPayload {
    private val identifierFields = mapOf("email" to "Email", "phone" to "Phone", "userName" to "UserName")
    private val textFields = setOf("firstName", "lastName", "gender", "dateOfBirth", "registeredAt")
    private val consentFields = setOf("emailOptIn", "smsOptIn", "pushOptIn", "gdprAccepted", "whatsAppOptIn")

    fun identifiers(userId: String, attributes: Map<String, Any>?): Map<String, String> {
        require(userId.isNotBlank()) { "userId must not be empty" }
        val result = mutableMapOf("ExternalId" to userId)
        identifierFields.forEach { (field, type) ->
            attributes?.get(field)?.let { value ->
                require(value is String && value.isNotBlank()) { "$field must be non-empty text" }
                result[type] = value
            }
        }
        return result
    }

    fun profile(attributes: Map<String, Any>?): Map<String, Any> {
        val result = mutableMapOf<String, Any>()
        attributes?.forEach { (field, value) ->
            when (field) {
                in textFields -> {
                    require(value is String) { "$field must be text (dates use ISO 8601)" }
                    result[field] = value
                }
                in consentFields -> {
                    require(value is Boolean) { "$field must be a boolean" }
                    result[field] = value
                }
                in identifierFields -> Unit
                else -> throw IllegalArgumentException("Unsupported profile field: $field. Use trackEvent for custom event data.")
            }
        }
        return result
    }
}
