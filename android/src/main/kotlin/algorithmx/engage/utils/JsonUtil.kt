package algorithmx.engage.utils

import com.google.gson.Gson
import com.google.gson.reflect.TypeToken

object JsonUtil {
    private val gson = Gson()

    fun toJson(obj: Any): String = gson.toJson(obj)

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
