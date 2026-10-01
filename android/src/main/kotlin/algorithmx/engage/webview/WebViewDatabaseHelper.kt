package algorithmx.engage.webview

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import algorithmx.engage.utils.SdkLog
import java.io.File

/**
 * SQLite-backed webview queue + display history. Schema matches the iOS
 * implementation so behaviour stays parallel between platforms.
 *
 * History uniqueness key: `(campaign_id, variation_id, user_id)`. Previous
 * versions used `(variation_id, user_id)` which collided when variation IDs
 * were reused across campaigns — fixed in DB version 3.
 *
 * The file lives in the partner app's `noBackupFilesDir` under an SDK-prefixed
 * name, so Auto Backup never restores a stale queue/history onto a new device.
 */
class WebViewDatabaseHelper(context: Context) : SQLiteOpenHelper(
    context, databasePath(context), null, DATABASE_VERSION
) {
    override fun onCreate(db: SQLiteDatabase) {
        try {
            db.execSQL("""
                CREATE TABLE $TABLE_QUEUE (
                    $COL_QUEUE_ID INTEGER PRIMARY KEY AUTOINCREMENT,
                    $COL_QUEUE_CAMPAIGN_ID TEXT NOT NULL,
                    $COL_QUEUE_VARIATION_ID TEXT NOT NULL,
                    $COL_QUEUE_WEBVIEW_URL TEXT NOT NULL,
                    $COL_QUEUE_DYNAMIC_CONTENT TEXT,
                    $COL_QUEUE_CONFIGS TEXT,
                    $COL_QUEUE_METADATA TEXT,
                    $COL_QUEUE_QUEUED_AT INTEGER NOT NULL,
                    $COL_QUEUE_PRIORITY INTEGER DEFAULT 0
                )
            """.trimIndent())

            db.execSQL("""
                CREATE TABLE $TABLE_HISTORY (
                    $COL_HIST_ID INTEGER PRIMARY KEY AUTOINCREMENT,
                    $COL_HIST_CAMPAIGN_ID TEXT NOT NULL,
                    $COL_HIST_VARIATION_ID TEXT NOT NULL,
                    $COL_HIST_USER_ID TEXT NOT NULL,
                    $COL_HIST_DISPLAY_COUNT INTEGER DEFAULT 0,
                    $COL_HIST_LAST_SHOWN_AT INTEGER DEFAULT 0,
                    $COL_HIST_LAST_RESET_AT INTEGER DEFAULT 0,
                    $COL_HIST_EXPIRES_AT INTEGER DEFAULT 0,
                    $COL_HIST_CREATED_AT INTEGER NOT NULL,
                    UNIQUE($COL_HIST_CAMPAIGN_ID, $COL_HIST_VARIATION_ID, $COL_HIST_USER_ID)
                )
            """.trimIndent())

            db.execSQL("CREATE INDEX idx_queue_priority_queued ON $TABLE_QUEUE ($COL_QUEUE_PRIORITY DESC, $COL_QUEUE_QUEUED_AT ASC)")
            db.execSQL("CREATE INDEX idx_history_campaign_user ON $TABLE_HISTORY ($COL_HIST_CAMPAIGN_ID, $COL_HIST_USER_ID)")
        } catch (e: Exception) {
            SdkLog.e(TAG, "Failed to create webview tables", e)
        }
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // Drop everything and recreate. The webview store is a cache, not source of truth.
        try {
            db.execSQL("DROP INDEX IF EXISTS idx_queue_priority_queued")
            db.execSQL("DROP INDEX IF EXISTS idx_queue_priority_created")
            db.execSQL("DROP INDEX IF EXISTS idx_history_variation_user")
            db.execSQL("DROP INDEX IF EXISTS idx_history_campaign_user")
            db.execSQL("DROP TABLE IF EXISTS $TABLE_QUEUE")
            db.execSQL("DROP TABLE IF EXISTS $TABLE_HISTORY")
            onCreate(db)
        } catch (e: Exception) {
            SdkLog.e(TAG, "Webview DB upgrade failed", e)
        }
    }

    // SQLiteOpenHelper throws on downgrade by default, which would break the host app
    // when a partner rolls back the SDK. The store is a cache, so rebuild it instead.
    override fun onDowngrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        onUpgrade(db, oldVersion, newVersion)
    }

    fun insertQueuedWebView(
        campaignId: String,
        variationId: String,
        webviewUrl: String,
        dynamicContent: String?,
        configs: String?,
        metadata: String?,
        priority: Int
    ): Long {
        val values = ContentValues().apply {
            put(COL_QUEUE_CAMPAIGN_ID, campaignId)
            put(COL_QUEUE_VARIATION_ID, variationId)
            put(COL_QUEUE_WEBVIEW_URL, webviewUrl)
            put(COL_QUEUE_DYNAMIC_CONTENT, dynamicContent)
            put(COL_QUEUE_CONFIGS, configs)
            put(COL_QUEUE_METADATA, metadata)
            put(COL_QUEUE_QUEUED_AT, System.currentTimeMillis())
            put(COL_QUEUE_PRIORITY, priority)
        }
        return try {
            writableDatabase.insert(TABLE_QUEUE, null, values)
        } catch (e: Exception) {
            SdkLog.e(TAG, "Failed to insert queued webview", e); -1
        }
    }

    fun getPendingWebViews(): List<QueuedWebView> {
        val result = mutableListOf<QueuedWebView>()
        val cursor = readableDatabase.query(
            TABLE_QUEUE, null, null, null, null, null,
            "$COL_QUEUE_PRIORITY DESC, $COL_QUEUE_QUEUED_AT ASC"
        )
        try {
            while (cursor.moveToNext()) {
                result.add(QueuedWebView(
                    id = cursor.getLong(cursor.getColumnIndexOrThrow(COL_QUEUE_ID)),
                    campaignId = cursor.getString(cursor.getColumnIndexOrThrow(COL_QUEUE_CAMPAIGN_ID)),
                    variationId = cursor.getString(cursor.getColumnIndexOrThrow(COL_QUEUE_VARIATION_ID)),
                    webviewUrl = cursor.getString(cursor.getColumnIndexOrThrow(COL_QUEUE_WEBVIEW_URL)),
                    dynamicContent = cursor.getString(cursor.getColumnIndexOrThrow(COL_QUEUE_DYNAMIC_CONTENT)),
                    configs = cursor.getString(cursor.getColumnIndexOrThrow(COL_QUEUE_CONFIGS)),
                    metadata = cursor.getString(cursor.getColumnIndexOrThrow(COL_QUEUE_METADATA)),
                    queuedAt = cursor.getLong(cursor.getColumnIndexOrThrow(COL_QUEUE_QUEUED_AT)),
                    priority = cursor.getInt(cursor.getColumnIndexOrThrow(COL_QUEUE_PRIORITY))
                ))
            }
        } catch (e: Exception) {
            SdkLog.e(TAG, "Failed to read pending webviews", e)
        } finally { cursor.close() }
        return result
    }

    fun removeFromQueue(id: Long): Boolean = try {
        writableDatabase.delete(TABLE_QUEUE, "$COL_QUEUE_ID = ?", arrayOf(id.toString())) > 0
    } catch (e: Exception) { SdkLog.e(TAG, "Remove from queue failed", e); false }

    fun getDisplayHistory(campaignId: String, variationId: String, userId: String): WebViewDisplayHistory {
        val cursor = readableDatabase.query(
            TABLE_HISTORY, null,
            "$COL_HIST_CAMPAIGN_ID = ? AND $COL_HIST_VARIATION_ID = ? AND $COL_HIST_USER_ID = ?",
            arrayOf(campaignId, variationId, userId), null, null, null
        )
        return try {
            if (cursor.moveToFirst()) {
                WebViewDisplayHistory(
                    id = cursor.getLong(cursor.getColumnIndexOrThrow(COL_HIST_ID)),
                    campaignId = cursor.getString(cursor.getColumnIndexOrThrow(COL_HIST_CAMPAIGN_ID)),
                    variationId = cursor.getString(cursor.getColumnIndexOrThrow(COL_HIST_VARIATION_ID)),
                    userId = cursor.getString(cursor.getColumnIndexOrThrow(COL_HIST_USER_ID)),
                    displayCount = cursor.getInt(cursor.getColumnIndexOrThrow(COL_HIST_DISPLAY_COUNT)),
                    lastShownAt = cursor.getLong(cursor.getColumnIndexOrThrow(COL_HIST_LAST_SHOWN_AT)),
                    lastResetAt = cursor.getLong(cursor.getColumnIndexOrThrow(COL_HIST_LAST_RESET_AT)),
                    expiresAt = cursor.getLong(cursor.getColumnIndexOrThrow(COL_HIST_EXPIRES_AT)),
                    createdAt = cursor.getLong(cursor.getColumnIndexOrThrow(COL_HIST_CREATED_AT))
                )
            } else {
                val now = System.currentTimeMillis()
                WebViewDisplayHistory(0, campaignId, variationId, userId, 0, 0, now, 0, now)
            }
        } finally { cursor.close() }
    }

    /** True when the user has already been shown a different variation of this campaign. */
    fun hasSeenOtherVariation(campaignId: String, variationId: String, userId: String): Boolean {
        val cursor = readableDatabase.query(
            TABLE_HISTORY, arrayOf(COL_HIST_ID),
            "$COL_HIST_CAMPAIGN_ID = ? AND $COL_HIST_VARIATION_ID != ? AND $COL_HIST_USER_ID = ? AND $COL_HIST_DISPLAY_COUNT > 0",
            arrayOf(campaignId, variationId, userId), null, null, null, "1"
        )
        return try { cursor.count > 0 } finally { cursor.close() }
    }

    fun hasSeenAnyCampaignVariation(campaignId: String, userId: String): Boolean {
        val cursor = readableDatabase.query(
            TABLE_HISTORY, arrayOf(COL_HIST_ID),
            "$COL_HIST_CAMPAIGN_ID = ? AND $COL_HIST_USER_ID = ? AND $COL_HIST_DISPLAY_COUNT > 0",
            arrayOf(campaignId, userId), null, null, null, "1"
        )
        return try { cursor.count > 0 } finally { cursor.close() }
    }

    fun upsertDisplayHistory(history: WebViewDisplayHistory): Boolean {
        val values = ContentValues().apply {
            put(COL_HIST_CAMPAIGN_ID, history.campaignId)
            put(COL_HIST_VARIATION_ID, history.variationId)
            put(COL_HIST_USER_ID, history.userId)
            put(COL_HIST_DISPLAY_COUNT, history.displayCount)
            put(COL_HIST_LAST_SHOWN_AT, history.lastShownAt)
            put(COL_HIST_LAST_RESET_AT, history.lastResetAt)
            put(COL_HIST_EXPIRES_AT, history.expiresAt)
            put(COL_HIST_CREATED_AT, history.createdAt)
        }
        return try {
            if (history.id > 0) {
                writableDatabase.update(TABLE_HISTORY, values, "$COL_HIST_ID = ?", arrayOf(history.id.toString())) > 0
            } else {
                writableDatabase.replaceOrThrow(TABLE_HISTORY, null, values) > 0
            }
        } catch (e: Exception) { SdkLog.e(TAG, "Upsert history failed", e); false }
    }

    fun cleanupExpiredWebViews(): Int {
        val now = System.currentTimeMillis()
        val cursor = readableDatabase.query(
            TABLE_QUEUE, arrayOf(COL_QUEUE_ID, COL_QUEUE_CONFIGS), null, null, null, null, null
        )
        val expiredIds = mutableListOf<Long>()
        try {
            while (cursor.moveToNext()) {
                val id = cursor.getLong(cursor.getColumnIndexOrThrow(COL_QUEUE_ID))
                val rule = WebViewDisplayRule.fromJson(cursor.getString(cursor.getColumnIndexOrThrow(COL_QUEUE_CONFIGS)))
                if (rule.isExpired()) expiredIds.add(id)
            }
        } finally { cursor.close() }
        var deleted = 0
        expiredIds.forEach { if (removeFromQueue(it)) deleted++ }
        return deleted
    }

    /**
     * Drops display history nobody has touched for [HISTORY_RETENTION_DAYS]; without this the
     * table grows by one row per campaign forever. A campaign idle that long loses its
     * "already shown" mark and could show once more if it is ever re-sent. Mirrors iOS.
     */
    fun pruneDisplayHistory(): Int = try {
        val cutoff = System.currentTimeMillis() - HISTORY_RETENTION_DAYS * 24 * 60 * 60 * 1000
        // Bound as a long on purpose: whereArgs would bind the cutoff as text, and SQLite
        // sorts every number before any text, so the comparison would match every row.
        writableDatabase.compileStatement(
            "DELETE FROM $TABLE_HISTORY WHERE MAX($COL_HIST_LAST_SHOWN_AT, $COL_HIST_LAST_RESET_AT, $COL_HIST_CREATED_AT) < ?"
        ).use { statement ->
            statement.bindLong(1, cutoff)
            statement.executeUpdateDelete()
        }
    } catch (e: Exception) { SdkLog.e(TAG, "Prune display history failed", e); 0 }

    fun getQueueSize(): Int {
        val cursor = readableDatabase.rawQuery("SELECT COUNT(*) FROM $TABLE_QUEUE", null)
        return try { if (cursor.moveToFirst()) cursor.getInt(0) else 0 } finally { cursor.close() }
    }

    fun clearAllData(): Boolean = try {
        writableDatabase.beginTransaction()
        try {
            writableDatabase.delete(TABLE_QUEUE, null, null)
            writableDatabase.delete(TABLE_HISTORY, null, null)
            writableDatabase.setTransactionSuccessful()
            true
        } finally { writableDatabase.endTransaction() }
    } catch (e: Exception) { SdkLog.e(TAG, "Clear all webview data failed", e); false }

    companion object {
        private const val TAG = "AlgorithmX"
        private const val DATABASE_NAME = "algorithmx_webview.db"
        private const val DATABASE_VERSION = 3
        private const val HISTORY_RETENTION_DAYS = 365L

        /** Absolute path, so SQLiteOpenHelper uses it instead of the backed-up databases/ dir. */
        private fun databasePath(context: Context): String =
            File(context.noBackupFilesDir, DATABASE_NAME).path

        const val TABLE_QUEUE = "webview_queue"
        const val COL_QUEUE_ID = "id"
        const val COL_QUEUE_CAMPAIGN_ID = "campaign_id"
        const val COL_QUEUE_VARIATION_ID = "variation_id"
        const val COL_QUEUE_WEBVIEW_URL = "webview_url"
        const val COL_QUEUE_DYNAMIC_CONTENT = "dynamic_content"
        const val COL_QUEUE_CONFIGS = "configs"
        const val COL_QUEUE_METADATA = "metadata"
        const val COL_QUEUE_QUEUED_AT = "queued_at"
        const val COL_QUEUE_PRIORITY = "priority"

        const val TABLE_HISTORY = "webview_display_history"
        const val COL_HIST_ID = "id"
        const val COL_HIST_CAMPAIGN_ID = "campaign_id"
        const val COL_HIST_VARIATION_ID = "variation_id"
        const val COL_HIST_USER_ID = "user_id"
        const val COL_HIST_DISPLAY_COUNT = "display_count"
        const val COL_HIST_LAST_SHOWN_AT = "last_shown_at"
        const val COL_HIST_LAST_RESET_AT = "last_reset_at"
        const val COL_HIST_EXPIRES_AT = "expires_at"
        const val COL_HIST_CREATED_AT = "created_at"
    }
}

data class QueuedWebView(
    val id: Long,
    val campaignId: String,
    val variationId: String,
    val webviewUrl: String,
    val dynamicContent: String?,
    val configs: String?,
    val metadata: String?,
    val queuedAt: Long,
    val priority: Int
)

data class WebViewDisplayHistory(
    val id: Long,
    val campaignId: String,
    val variationId: String,
    val userId: String,
    val displayCount: Int,
    val lastShownAt: Long,
    val lastResetAt: Long,
    val expiresAt: Long,
    val createdAt: Long
)
