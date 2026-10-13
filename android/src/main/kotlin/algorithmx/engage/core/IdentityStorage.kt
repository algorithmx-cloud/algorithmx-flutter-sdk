package algorithmx.engage.core

import java.util.UUID

internal object IdentityStorage {
    fun uuid(saved: String?): String {
        val valid = saved?.let { runCatching { UUID.fromString(it).toString() }.getOrNull() }
            ?.takeIf { it.equals(saved, ignoreCase = true) }
        return valid ?: UUID.randomUUID().toString()
    }
}
