//
//  WebViewQueueManager.swift
//  AlgorithmXSDK
//
//  Mirrors Android `WebViewQueueManager`:
//   - A user only ever sees one variation of a campaign (`hasSeenOtherVariation`);
//     maxShowTime / intervalMinutes / showAgainAfterDays apply to that variation.
//   - Provides `willBeAbleToDisplayLater` so silent-push processing can avoid
//     queueing webviews that will never become eligible.
//   - Records the display only after CampaignViewController confirms a
//     successful HTML load — failed loads do not consume the max-show counter.
//

import Foundation

final class WebViewQueueManager {

    private let databaseHelper = WebViewDatabaseHelper()
    private var hasProcessedQueueThisSession = false

    // MARK: - Queue management

    func enqueueWebView(
        campaignId: String,
        variationId: String,
        webviewUrl: String,
        dynamicContent: [String: Any]?,
        displayRule: WebViewDisplayRule,
        metadata: [String: Any]? = nil
    ) -> Int64 {
        let existing = databaseHelper.getPendingWebViews()
        // Same campaign + variation already waiting → keep the queued one.
        if let dup = existing.first(where: { $0.campaignId == campaignId && $0.variationId == variationId }) {
            return dup.id
        }
        return databaseHelper.insertQueuedWebView(
            campaignId: campaignId, variationId: variationId,
            webviewUrl: webviewUrl, dynamicContent: dynamicContent,
            displayRule: displayRule, metadata: metadata
        )
    }

    // MARK: - Display rule checking

    func canDisplayWebView(
        campaignId: String, variationId: String, userId: String, rule: WebViewDisplayRule
    ) -> Bool {
        if databaseHelper.hasSeenOtherVariation(campaignId: campaignId, variationId: variationId, userId: userId) {
            return false
        }
        if rule.isExpired() { return false }

        let history = databaseHelper.getDisplayHistory(
            campaignId: campaignId, variationId: variationId, userId: userId
        )
        if history.displayCount >= rule.maxShowTime {
            if rule.showAgainAfterDays > 0 {
                let days = Date().timeIntervalSince(history.lastResetAt) / 86_400
                if days >= Double(rule.showAgainAfterDays) {
                    resetDisplayHistory(
                        campaignId: campaignId, variationId: variationId,
                        userId: userId, rule: rule
                    )
                    return true
                }
            }
            return false
        }

        if history.lastShownAt.timeIntervalSince1970 > 0 && rule.intervalMinutes > 0 {
            let sinceLast = Date().timeIntervalSince(history.lastShownAt)
            if sinceLast < Double(rule.intervalMinutes * 60) { return false }
        }
        return true
    }

    func willBeAbleToDisplayLater(
        campaignId: String, variationId: String, userId: String, rule: WebViewDisplayRule
    ) -> Bool {
        if databaseHelper.hasSeenOtherVariation(campaignId: campaignId, variationId: variationId, userId: userId) {
            return false
        }
        if rule.isExpired() { return false }

        let history = databaseHelper.getDisplayHistory(
            campaignId: campaignId, variationId: variationId, userId: userId
        )
        if history.displayCount >= rule.maxShowTime {
            if rule.showAgainAfterDays > 0 {
                let days = Date().timeIntervalSince(history.lastResetAt) / 86_400
                return days >= Double(rule.showAgainAfterDays)
            }
            return false
        }
        return true
    }

    // MARK: - Display history

    private func resetDisplayHistory(
        campaignId: String, variationId: String, userId: String, rule: WebViewDisplayRule
    ) {
        let now = Date()
        let fresh = WebViewDisplayHistory(
            id: 0, campaignId: campaignId, variationId: variationId, userId: userId,
            displayCount: 0,
            lastShownAt: Date(timeIntervalSince1970: 0),
            lastResetAt: now,
            expiresAt: Date(timeIntervalSince1970: Double(rule.expiresAt) / 1000),
            createdAt: now
        )
        _ = databaseHelper.upsertDisplayHistory(fresh)
    }

    func recordWebViewDisplay(
        campaignId: String, variationId: String, userId: String, expiresAt: Int64 = 0
    ) {
        var history = databaseHelper.getDisplayHistory(
            campaignId: campaignId, variationId: variationId, userId: userId
        )
        history.displayCount += 1
        history.lastShownAt = Date()
        if expiresAt > 0 {
            history.expiresAt = Date(timeIntervalSince1970: Double(expiresAt) / 1000)
        }
        _ = databaseHelper.upsertDisplayHistory(history)
    }

    // MARK: - Process queue

    func processQueuedWebViews(userId: String) -> Bool {
        if hasProcessedQueueThisSession { return false }
        _ = databaseHelper.cleanupExpiredWebViews()
        _ = databaseHelper.pruneDisplayHistory()
        let queued = databaseHelper.getPendingWebViews()
        if queued.isEmpty { return false }

        for entry in queued {
            let rule = WebViewDisplayRule.fromJson(entry.configs)
            if rule.isExpired() {
                _ = databaseHelper.removeFromQueue(id: entry.id)
                continue
            }
            if canDisplayWebView(
                campaignId: entry.campaignId, variationId: entry.variationId,
                userId: userId, rule: rule
            ) {
                var dynamicContent: [String: Any]?
                if let str = entry.dynamicContent,
                   let data = str.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    dynamicContent = json
                }
                AlgorithmX.shared.showWebView(
                    campaignId: entry.campaignId, variationId: entry.variationId,
                    url: entry.webviewUrl, dynamicContent: dynamicContent,
                    expiresAt: rule.expiresAt
                )
                _ = databaseHelper.removeFromQueue(id: entry.id)
                hasProcessedQueueThisSession = true
                return true
            }
            // Drop entries that can never show (e.g. campaign already seen);
            // left queued they never leave and block their variation id.
            if !willBeAbleToDisplayLater(
                campaignId: entry.campaignId, variationId: entry.variationId,
                userId: userId, rule: rule
            ) {
                _ = databaseHelper.removeFromQueue(id: entry.id)
            }
        }
        return false
    }

    // MARK: - Utility

    func getQueueSize() -> Int { databaseHelper.getQueueSize() }

    func clearQueue() -> Int {
        var cleared = 0
        for entry in databaseHelper.getPendingWebViews() {
            if databaseHelper.removeFromQueue(id: entry.id) { cleared += 1 }
        }
        return cleared
    }

    func clearAllData() -> Bool { databaseHelper.clearAllData() }

    func resetSessionFlag() { hasProcessedQueueThisSession = false }

    func getDisplayStats(campaignId: String, variationId: String, userId: String) -> String {
        let h = databaseHelper.getDisplayHistory(
            campaignId: campaignId, variationId: variationId, userId: userId
        )
        return """
            Campaign ID: \(campaignId)
            Variation ID: \(variationId)
            User: \(userId)
            Display Count: \(h.displayCount)
            Last Shown: \(h.lastShownAt)
            Last Reset: \(h.lastResetAt)
            Expires At: \(h.expiresAt)
            Created At: \(h.createdAt)
            """
    }
}
