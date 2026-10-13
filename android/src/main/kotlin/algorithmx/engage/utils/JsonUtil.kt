package algorithmx.engage.utils

import com.google.gson.Gson
import com.google.gson.reflect.TypeToken

object JsonUtil {
    private val gson = Gson()

    fun toJson(obj: Any): String = gson.toJson(obj)

    fun fromJsonArray(jsonString: String): List<Map<String, Any>> {
        val type = object : TypeToken<List<Map<String, Any>?>>() {}.type
        return gson.fromJson<List<Map<String, Any>?>>(jsonString, type)?.filterNotNull()
            ?: throw IllegalArgumentException("Expected an in-app views array")
    }

    fun fromJson(jsonString: String): Any? {
        return try {
            val mapType = object : TypeToken<Map<String, Any>>() {}.type
            gson.fromJson<Map<String, Any>>(jsonString, mapType)
        } catch (_: Exception) {
            try {
                val listType = object : TypeToken<List<Any>>() {}.type
                gson.fromJson<List<Any>>(jsonString, listType)
            } catch (_: Exception) {
                jsonString
            }
        }
    }
}
