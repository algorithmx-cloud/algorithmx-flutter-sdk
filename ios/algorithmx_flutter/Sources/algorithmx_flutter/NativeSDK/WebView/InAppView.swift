import Foundation

/// The API response uses string IDs, inline templates, and object-valued parameters.
struct InAppView {
    let id: String
    let campaignId: String
    let language: String
    let rule: WebViewDisplayRule
    let delaySeconds: Double
    let variations: [InAppVariation]

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String, !id.isEmpty,
              let campaignId = dict["campaignId"] as? String, !campaignId.isEmpty,
              let language = dict["language"] as? String, !language.isEmpty,
              let rawVariations = dict["variations"] as? [[String: Any]] else { return nil }
        self.id = id
        self.campaignId = campaignId
        self.language = language
        var configs = dict["configs"] as? [String: Any] ?? [:]
        delaySeconds = (configs["delaySeconds"] as? NSNumber)?.doubleValue ?? 0
        configs["priority"] = dict["priority"] as? Int ?? 0
        configs["maxShowTime"] = dict["frequency"] as? Int ?? 1
        rule = WebViewDisplayRule.fromDict(configs)
        variations = rawVariations.compactMap(InAppVariation.init)
        guard !variations.isEmpty, delaySeconds >= 0, delaySeconds.isFinite, rule.maxShowTime > 0,
              rule.intervalMinutes >= 0, rule.showAgainAfterDays >= 0,
              rule.expiresAt >= 0,
              variations.reduce(0, { $0 + $1.allocation }) <= 100.01 else { return nil }
    }

    /// Stable allocation across launches; unlike Swift's hashValue this is not randomized.
    func variation(for userId: String) -> InAppVariation? {
        var hash: UInt64 = 14695981039346656037
        for byte in "\(campaignId):\(id):\(userId)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        let bucket = Double(hash % 10000) / 100
        var end: Double = 0
        for variation in variations.sorted(by: { $0.id < $1.id }) {
            end += variation.allocation
            if bucket < end { return variation }
        }
        return nil
    }
}

struct InAppVariation {
    let id: String
    let allocation: Double
    let parameters: [String: Any]
    let template: InAppTemplate

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String, !id.isEmpty,
              let allocation = (dict["allocation"] as? NSNumber)?.doubleValue, allocation.isFinite, (0...100).contains(allocation),
              let rawTemplate = dict["template"] as? [String: Any],
              let template = InAppTemplate(rawTemplate) else { return nil }
        self.id = id
        self.allocation = allocation
        self.parameters = dict["parameters"] as? [String: Any] ?? [:]
        self.template = template
    }
}

struct InAppTemplate {
    let html: String
    let css: String
    let js: String
    let translations: [String: [String: [String: String]]]

    init?(_ dict: [String: Any]) {
        guard let html = dict["html"] as? String, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.html = html
        css = dict["css"] as? String ?? ""
        js = dict["js"] as? String ?? ""
        let builderState = dict["builderState"] as? [String: Any] ?? [:]
        translations = builderState["translations"] as? [String: [String: [String: String]]] ?? [:]
    }

    var document: String {
        let head = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\"><style>\(css)</style>"
        let script = "<script>\(js)</script>"
        if html.range(of: "<html(?:\\s|>)", options: [.regularExpression, .caseInsensitive]) != nil {
            var out = html
            if let range = out.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                out.insert(contentsOf: head, at: range.upperBound)
            } else {
                out = head + out
            }
            if let range = out.range(of: "</body>", options: .caseInsensitive) {
                out.insert(contentsOf: script, at: range.lowerBound)
            } else {
                out += script
            }
            return out
        }
        return "<!doctype html><html><head><meta charset=\"utf-8\">\(head)</head><body>\(html)\(script)</body></html>"
    }

    /// A WKUserScript keeps translation values out of executable HTML markup.
    func translationScript(language: String) -> String {
        let base = language.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? "en"
        let entries = translations[language] ?? translations[base] ?? translations["en"] ?? [:]
        let payload: [String: Any] = ["language": language, "rtl": ["ar", "he", "fa", "ur"].contains(base), "entries": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return """
        (function () {
            var data = \(json);
            document.documentElement.lang = data.language;
            document.documentElement.dir = data.rtl ? 'rtl' : 'ltr';
            document.querySelectorAll('[data-t-key]').forEach(function (element) {
                var entry = data.entries[element.getAttribute('data-t-key')];
                if (!entry || typeof entry.value !== 'string') return;
                if (entry.type === 'placeholder') element.setAttribute('placeholder', entry.value);
                else if (entry.type === 'text') element.textContent = entry.value;
            });
        })();
        """
    }
}
