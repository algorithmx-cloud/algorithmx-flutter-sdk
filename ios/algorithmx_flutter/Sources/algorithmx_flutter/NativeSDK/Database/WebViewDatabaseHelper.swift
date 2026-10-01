//
//  WebViewDatabaseHelper.swift
//  AlgorithmXSDK
//
//  SQLite database helper for WebView queue and display history
//

import Foundation
import SQLite3

/// Tells SQLite to copy bound text. `nil` (SQLITE_STATIC) makes it read the Swift string's
/// temporary C buffer at step time, after that buffer may already be freed.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct QueuedWebView {
    let id: Int64
    let campaignId: String
    let variationId: String
    let webviewUrl: String
    let dynamicContent: String?
    let configs: String?
    let metadata: String?
    let priority: Int
    let queuedAt: Date
}

struct WebViewDisplayHistory {
    var id: Int64
    let campaignId: String
    let variationId: String
    let userId: String
    var displayCount: Int
    var lastShownAt: Date
    var lastResetAt: Date
    var expiresAt: Date
    let createdAt: Date
}

class WebViewDatabaseHelper {

    /// Bump when the schema changes. Mirrors Android `DATABASE_VERSION`.
    static let schemaVersion: Int32 = 3
    static let databaseName = "algorithmx_webview.db"
    static let historyRetentionDays: Int64 = 365

    private var db: OpaquePointer?
    private let dbPath: String

    init() {
        dbPath = WebViewDatabaseHelper.databaseURL().path

        openDatabase()
        migrateIfNeeded()
    }

    /// `Library/Application Support/AlgorithmX/algorithmx_webview.db`, excluded from backup.
    /// Documents belongs to the host app's user (visible in Files when file sharing is on)
    /// and is backed up; this store is an SDK cache.
    static func databaseURL() -> URL {
        let fileManager = FileManager.default
        var directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AlgorithmX", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory.appendingPathComponent(databaseName)
    }

    deinit {
        closeDatabase()
    }

    // MARK: - Database Operations
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            SdkLog.error("Error opening database")
        }
    }

    private func closeDatabase() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    /// Same policy as Android `onUpgrade`/`onDowngrade`: the store is a cache, so any
    /// version mismatch (including a fresh file at 0) drops and recreates the tables.
    private func migrateIfNeeded() {
        guard userVersion() != WebViewDatabaseHelper.schemaVersion else { return }
        executeSQL("DROP TABLE IF EXISTS webview_queue;")
        executeSQL("DROP TABLE IF EXISTS webview_display_history;")
        createTables()
        executeSQL("PRAGMA user_version = \(WebViewDatabaseHelper.schemaVersion);")
    }

    private func userVersion() -> Int32 {
        var statement: OpaquePointer?
        var version: Int32 = 0
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_ROW
        {
            version = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        return version
    }

    private func createTables() {
        let createQueueTable = """
            CREATE TABLE IF NOT EXISTS webview_queue (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                campaign_id TEXT NOT NULL,
                variation_id TEXT NOT NULL,
                webview_url TEXT NOT NULL,
                dynamic_content TEXT,
                configs TEXT,
                metadata TEXT,
                priority INTEGER DEFAULT 0,
                queued_at INTEGER NOT NULL
            );
            """

        let createHistoryTable = """
            CREATE TABLE IF NOT EXISTS webview_display_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                campaign_id TEXT NOT NULL,
                variation_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                display_count INTEGER DEFAULT 0,
                last_shown_at INTEGER DEFAULT 0,
                last_reset_at INTEGER NOT NULL,
                expires_at INTEGER DEFAULT 0,
                created_at INTEGER NOT NULL,
                UNIQUE(campaign_id, variation_id, user_id)
            );
            """

        executeSQL(createQueueTable)
        executeSQL(createHistoryTable)
    }

    private func executeSQL(_ sql: String) {
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) != SQLITE_DONE {
                SdkLog.error("Error executing SQL")
            }
        }

        sqlite3_finalize(statement)
    }

    // MARK: - Queue Operations
    func insertQueuedWebView(
        campaignId: String,
        variationId: String,
        webviewUrl: String,
        dynamicContent: [String: Any]?,
        displayRule: WebViewDisplayRule,
        metadata: [String: Any]? = nil
    ) -> Int64 {
        let dynamicContentJson = dynamicContent?.toJsonString()
        let configsJson = displayRule.toJson()
        let metadataJson = metadata?.toJsonString()
        let queuedAt = Int64(Date().timeIntervalSince1970 * 1000)

        let insertSQL = """
            INSERT INTO webview_queue (campaign_id, variation_id, webview_url, dynamic_content, configs, metadata, priority, queued_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        var id: Int64 = -1

        if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (campaignId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (variationId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, (webviewUrl as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, (dynamicContentJson as NSString?)?.utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 5, (configsJson as NSString?)?.utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 6, (metadataJson as NSString?)?.utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 7, Int32(displayRule.priority))
            sqlite3_bind_int64(statement, 8, queuedAt)

            if sqlite3_step(statement) == SQLITE_DONE {
                id = sqlite3_last_insert_rowid(db)
            }
        }

        sqlite3_finalize(statement)
        return id
    }

    func getPendingWebViews() -> [QueuedWebView] {
        let querySQL = "SELECT * FROM webview_queue ORDER BY priority DESC, queued_at ASC;"
        var statement: OpaquePointer?
        var webviews: [QueuedWebView] = []

        if sqlite3_prepare_v2(db, querySQL, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let campaignId = String(cString: sqlite3_column_text(statement, 1))
                let variationId = String(cString: sqlite3_column_text(statement, 2))
                let webviewUrl = String(cString: sqlite3_column_text(statement, 3))
                let dynamicContent = sqlite3_column_text(statement, 4).map { String(cString: $0) }
                let configs = sqlite3_column_text(statement, 5).map { String(cString: $0) }
                let metadata = sqlite3_column_text(statement, 6).map { String(cString: $0) }
                let priority = Int(sqlite3_column_int(statement, 7))
                let queuedAt = Date(
                    timeIntervalSince1970: Double(sqlite3_column_int64(statement, 8)) / 1000)

                webviews.append(
                    QueuedWebView(
                        id: id,
                        campaignId: campaignId,
                        variationId: variationId,
                        webviewUrl: webviewUrl,
                        dynamicContent: dynamicContent,
                        configs: configs,
                        metadata: metadata,
                        priority: priority,
                        queuedAt: queuedAt
                    ))
            }
        }

        sqlite3_finalize(statement)
        return webviews
    }

    func removeFromQueue(id: Int64) -> Bool {
        let deleteSQL = "DELETE FROM webview_queue WHERE id = ?;"
        var statement: OpaquePointer?
        var success = false

        if sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, id)
            success = sqlite3_step(statement) == SQLITE_DONE
        }

        sqlite3_finalize(statement)
        return success
    }

    func getQueueSize() -> Int {
        let querySQL = "SELECT COUNT(*) FROM webview_queue;"
        var statement: OpaquePointer?
        var count = 0

        if sqlite3_prepare_v2(db, querySQL, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
        }

        sqlite3_finalize(statement)
        return count
    }

    func cleanupExpiredWebViews() -> Int {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let deleteSQL =
            "DELETE FROM webview_queue WHERE json_extract(configs, '$.expiresAt') > 0 AND json_extract(configs, '$.expiresAt') < ?;"
        var statement: OpaquePointer?
        var deleted = 0

        if sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, now)
            if sqlite3_step(statement) == SQLITE_DONE {
                deleted = Int(sqlite3_changes(db))
            }
        }

        sqlite3_finalize(statement)
        return deleted
    }

    /// Drops display history nobody has touched for `historyRetentionDays`; without this the
    /// table grows by one row per campaign forever. A campaign idle that long loses its
    /// "already shown" mark and could show once more if it is ever re-sent. Mirrors Android.
    func pruneDisplayHistory() -> Int {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000)
            - WebViewDatabaseHelper.historyRetentionDays * 24 * 60 * 60 * 1000
        let deleteSQL =
            "DELETE FROM webview_display_history WHERE MAX(last_shown_at, last_reset_at, created_at) < ?;"
        var statement: OpaquePointer?
        var deleted = 0

        if sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, cutoff)
            if sqlite3_step(statement) == SQLITE_DONE {
                deleted = Int(sqlite3_changes(db))
            }
        }

        sqlite3_finalize(statement)
        return deleted
    }

    // MARK: - Display History Operations
    func getDisplayHistory(campaignId: String, variationId: String, userId: String)
        -> WebViewDisplayHistory
    {
        let querySQL =
            "SELECT * FROM webview_display_history WHERE campaign_id = ? AND variation_id = ? AND user_id = ?;"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, querySQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (campaignId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (variationId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, (userId as NSString).utf8String, -1, SQLITE_TRANSIENT)

            if sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let displayCount = Int(sqlite3_column_int(statement, 4))
                let lastShownAt = Date(
                    timeIntervalSince1970: Double(sqlite3_column_int64(statement, 5)) / 1000)
                let lastResetAt = Date(
                    timeIntervalSince1970: Double(sqlite3_column_int64(statement, 6)) / 1000)
                let expiresAt = Date(
                    timeIntervalSince1970: Double(sqlite3_column_int64(statement, 7)) / 1000)
                let createdAt = Date(
                    timeIntervalSince1970: Double(sqlite3_column_int64(statement, 8)) / 1000)

                sqlite3_finalize(statement)

                return WebViewDisplayHistory(
                    id: id,
                    campaignId: campaignId,
                    variationId: variationId,
                    userId: userId,
                    displayCount: displayCount,
                    lastShownAt: lastShownAt,
                    lastResetAt: lastResetAt,
                    expiresAt: expiresAt,
                    createdAt: createdAt
                )
            }
        }

        sqlite3_finalize(statement)

        // Return default history if not found
        let now = Date()
        return WebViewDisplayHistory(
            id: 0,
            campaignId: campaignId,
            variationId: variationId,
            userId: userId,
            displayCount: 0,
            lastShownAt: Date(timeIntervalSince1970: 0),
            lastResetAt: now,
            expiresAt: Date(timeIntervalSince1970: 0),
            createdAt: now
        )
    }

    func upsertDisplayHistory(_ history: WebViewDisplayHistory) -> Bool {
        let upsertSQL = """
            INSERT INTO webview_display_history (campaign_id, variation_id, user_id, display_count, last_shown_at, last_reset_at, expires_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(campaign_id, variation_id, user_id) DO UPDATE SET
                display_count = excluded.display_count,
                last_shown_at = excluded.last_shown_at,
                last_reset_at = excluded.last_reset_at,
                expires_at = excluded.expires_at;
            """

        var statement: OpaquePointer?
        var success = false

        if sqlite3_prepare_v2(db, upsertSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (history.campaignId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (history.variationId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, (history.userId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 4, Int32(history.displayCount))
            sqlite3_bind_int64(
                statement, 5, Int64(history.lastShownAt.timeIntervalSince1970 * 1000))
            sqlite3_bind_int64(
                statement, 6, Int64(history.lastResetAt.timeIntervalSince1970 * 1000))
            sqlite3_bind_int64(statement, 7, Int64(history.expiresAt.timeIntervalSince1970 * 1000))
            sqlite3_bind_int64(statement, 8, Int64(history.createdAt.timeIntervalSince1970 * 1000))

            success = sqlite3_step(statement) == SQLITE_DONE
        }

        sqlite3_finalize(statement)
        return success
    }

    /// True when the user has already been shown a different variation of this campaign.
    func hasSeenOtherVariation(campaignId: String, variationId: String, userId: String) -> Bool {
        let querySQL =
            "SELECT COUNT(*) FROM webview_display_history WHERE campaign_id = ? AND variation_id != ? AND user_id = ? AND display_count > 0;"
        var statement: OpaquePointer?
        var hasSeen = false

        if sqlite3_prepare_v2(db, querySQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (campaignId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (variationId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, (userId as NSString).utf8String, -1, SQLITE_TRANSIENT)

            if sqlite3_step(statement) == SQLITE_ROW {
                hasSeen = sqlite3_column_int(statement, 0) > 0
            }
        }

        sqlite3_finalize(statement)
        return hasSeen
    }

    func hasSeenAnyCampaignVariation(campaignId: String, userId: String) -> Bool {
        let querySQL =
            "SELECT COUNT(*) FROM webview_display_history WHERE campaign_id = ? AND user_id = ? AND display_count > 0;"
        var statement: OpaquePointer?
        var hasSeen = false

        if sqlite3_prepare_v2(db, querySQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (campaignId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (userId as NSString).utf8String, -1, SQLITE_TRANSIENT)

            if sqlite3_step(statement) == SQLITE_ROW {
                hasSeen = sqlite3_column_int(statement, 0) > 0
            }
        }

        sqlite3_finalize(statement)
        return hasSeen
    }

    func clearAllData() -> Bool {
        let deleteQueue = "DELETE FROM webview_queue;"
        let deleteHistory = "DELETE FROM webview_display_history;"

        executeSQL(deleteQueue)
        executeSQL(deleteHistory)

        return true
    }
}

// MARK: - Dictionary Extension
extension Dictionary where Key == String, Value == Any {
    func toJsonString() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: self),
            let jsonString = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return jsonString
    }
}
