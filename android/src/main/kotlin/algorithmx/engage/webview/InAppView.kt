package algorithmx.engage.webview

import algorithmx.engage.utils.JsonUtil

internal data class InAppView(val id: String, val campaignId: String, val language: String,
    val rule: WebViewDisplayRule, val delaySeconds: Double, val variations: List<InAppVariation>) {
    fun variation(userId: String): InAppVariation? {
        var hash = 14695981039346656037uL
        for (byte in "$campaignId:$id:$userId".toByteArray(Charsets.UTF_8)) {
            hash = (hash xor byte.toUByte().toULong()) * 1099511628211uL
        }
        val bucket = (hash % 10000uL).toDouble() / 100
        var end = 0.0
        return variations.sortedBy { it.id }.firstOrNull { variation ->
            end += variation.allocation
            bucket < end
        }
    }

    companion object {
        @Suppress("UNCHECKED_CAST")
        fun fromMap(data: Map<String, Any>): InAppView? {
            val id = (data["id"] as? String)?.takeIf { it.isNotBlank() } ?: return null
            val campaignId = (data["campaignId"] as? String)?.takeIf { it.isNotBlank() } ?: return null
            val language = (data["language"] as? String)?.takeIf { it.isNotBlank() } ?: return null
            val configs = (data["configs"] as? Map<String, Any> ?: emptyMap()).toMutableMap()
            configs["priority"] = (data["priority"] as? Number)?.toInt() ?: 0
            configs["maxShowTime"] = (data["frequency"] as? Number)?.toInt() ?: 1
            val rule = WebViewDisplayRule.fromConfigs(configs)
            val delay = (configs["delaySeconds"] as? Number)?.toDouble() ?: 0.0
            val variations = (data["variations"] as? List<*>)?.mapNotNull {
                (it as? Map<String, Any>)?.let(InAppVariation::fromMap)
            } ?: return null
            if (variations.isEmpty() || !delay.isFinite() || delay < 0 || rule.maxShowTime <= 0 ||
                rule.intervalMinutes < 0 || rule.showAgainAfterDays < 0 || rule.expiresAt < 0 ||
                variations.sumOf { it.allocation } > 100.01) return null
            return InAppView(id, campaignId, language, rule, delay, variations)
        }
    }
}

internal data class InAppVariation(val id: String, val allocation: Double,
    val parameters: Map<String, Any>, val template: InAppTemplate) {
    companion object {
        @Suppress("UNCHECKED_CAST")
        fun fromMap(data: Map<String, Any>): InAppVariation? {
            val id = (data["id"] as? String)?.takeIf { it.isNotBlank() } ?: return null
            val allocation = (data["allocation"] as? Number)?.toDouble() ?: return null
            if (!allocation.isFinite() || allocation < 0 || allocation > 100) return null
            val template = (data["template"] as? Map<String, Any>)?.let(InAppTemplate::fromMap) ?: return null
            return InAppVariation(id, allocation, data["parameters"] as? Map<String, Any> ?: emptyMap(), template)
        }
    }
}

internal data class InAppTemplate(val html: String, val css: String, val js: String,
    val translations: Map<String, Map<String, Map<String, String>>>) {
    val document: String get() {
        val bridge = """<script>(function(){if(window.EngageBridge){window.webkit=window.webkit||{};window.webkit.messageHandlers=window.webkit.messageHandlers||{};window.webkit.messageHandlers.EngageBridge={postMessage:function(value){window.EngageBridge.postMessage(JSON.stringify(value));}};}})();</script>"""
        val head = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\"><style>$css</style>$bridge"
        val script = "<script>$js</script>"
        if (Regex("<html(?:\\s|>)", RegexOption.IGNORE_CASE).containsMatchIn(html)) {
            var out = html
            val opening = Regex("<head[^>]*>", RegexOption.IGNORE_CASE).find(out)
            out = if (opening != null) out.substring(0, opening.range.last + 1) + head + out.substring(opening.range.last + 1) else head + out
            val closing = Regex("</body>", RegexOption.IGNORE_CASE).find(out)
            return if (closing != null) out.substring(0, closing.range.first) + script + out.substring(closing.range.first) else out + script
        }
        return "<!doctype html><html><head><meta charset=\"utf-8\">$head</head><body>$html$script</body></html>"
    }

    fun translationScript(language: String): String {
        val base = language.lowercase().replace('_', '-').substringBefore('-')
        val entries = translations[language] ?: translations[base] ?: translations["en"] ?: emptyMap()
        val payload = JsonUtil.toJson(mapOf("language" to language, "rtl" to (base in setOf("ar", "he", "fa", "ur")), "entries" to entries))
        return """(function(){var data=$payload;document.documentElement.lang=data.language;document.documentElement.dir=data.rtl?'rtl':'ltr';document.querySelectorAll('[data-t-key]').forEach(function(element){var entry=data.entries[element.getAttribute('data-t-key')];if(!entry||typeof entry.value!=='string')return;if(entry.type==='placeholder')element.setAttribute('placeholder',entry.value);else if(entry.type==='text')element.textContent=entry.value;});})();"""
    }

    companion object {
        @Suppress("UNCHECKED_CAST")
        fun fromMap(data: Map<String, Any>): InAppTemplate? {
            val html = (data["html"] as? String)?.takeIf { it.isNotBlank() } ?: return null
            val builder = data["builderState"] as? Map<String, Any> ?: emptyMap()
            return InAppTemplate(html, data["css"] as? String ?: "", data["js"] as? String ?: "",
                builder["translations"] as? Map<String, Map<String, Map<String, String>>> ?: emptyMap())
        }
    }
}

internal data class InAppDisplay(val token: String, val view: InAppView, val variation: InAppVariation,
    val baseUrl: String, val anonymousId: String, val customerId: String)
