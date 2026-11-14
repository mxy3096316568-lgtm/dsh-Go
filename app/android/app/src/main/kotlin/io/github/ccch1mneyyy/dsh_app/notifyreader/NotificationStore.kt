package io.github.ccch1mneyyy.dsh_app.notifyreader

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 通知中枢's storage: the last few hundred notifications, in memory and on disk.
 *
 * Only what a notification says is kept (app, title, text, time) — no icons, no actions, no
 * content intents — and it never leaves the app except through the tools the person's own
 * agent calls.
 */
object NotificationStore {
    private const val MAX = 300
    private const val FILE = "notifications.json"

    private val items = ArrayDeque<JSONObject>()
    private val labels = HashMap<String, String>()
    private var loaded = false
    private var lastSave = 0L

    @Synchronized
    fun record(context: Context, sbn: StatusBarNotification) {
        load(context)
        val note = sbn.notification ?: return
        val extras = note.extras ?: return
        val title = (extras.getCharSequence(Notification.EXTRA_TITLE) ?: note.tickerText)?.toString()?.trim().orEmpty()
        val text = (
            extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
                ?: extras.getCharSequence(Notification.EXTRA_TEXT)
                ?: extras.getCharSequence(Notification.EXTRA_SUMMARY_TEXT)
            )?.toString()?.trim().orEmpty()
        if (title.isEmpty() && text.isEmpty()) return
        val fresh = JSONObject()
            .put("package", sbn.packageName)
            .put("app", appLabel(context, sbn.packageName))
            .put("title", title.take(200))
            .put("text", text.take(600))
            .put("time", sbn.postTime)
            .put("ongoing", note.flags and Notification.FLAG_ONGOING_EVENT != 0)
        // The same notification is posted again for progress updates and group summaries.
        val newest = items.firstOrNull()
        if (newest != null &&
            newest.optString("package") == fresh.optString("package") &&
            newest.optString("title") == fresh.optString("title") &&
            newest.optString("text") == fresh.optString("text") &&
            sbn.postTime - newest.optLong("time") < 60_000
        ) {
            return
        }
        items.addFirst(fresh)
        while (items.size > MAX) items.removeLast()
        save(context, force = false)
        runCatching {
            NotificationRules.apply(
                context,
                fresh.optString("app"),
                fresh.optString("title"),
                fresh.optString("text"),
            )
        }
    }

    @Synchronized
    fun list(context: Context, limit: Int, app: String?): List<Map<String, Any?>> {
        load(context)
        val want = app?.trim()?.lowercase()
        return items.asSequence()
            .filter { want.isNullOrEmpty() || it.optString("app").lowercase().contains(want) || it.optString("package").lowercase() == want }
            .take(limit)
            .map { toMap(it) }
            .toList()
    }

    @Synchronized
    fun search(context: Context, query: String, limit: Int): List<Map<String, Any?>> {
        load(context)
        val needle = query.trim().lowercase()
        if (needle.isEmpty()) return emptyList()
        return items.asSequence()
            .filter {
                it.optString("title").lowercase().contains(needle) ||
                    it.optString("text").lowercase().contains(needle) ||
                    it.optString("app").lowercase().contains(needle)
            }
            .take(limit)
            .map { toMap(it) }
            .toList()
    }

    /** Per-app counts of the kept window, newest app first. */
    @Synchronized
    fun summary(context: Context): List<Map<String, Any?>> {
        load(context)
        val grouped = LinkedHashMap<String, MutableList<JSONObject>>()
        for (item in items) {
            val key = item.optString("app").ifEmpty { item.optString("package") }
            grouped.getOrPut(key) { ArrayList() }.add(item)
        }
        return grouped.map { (app, notes) ->
            mapOf(
                "app" to app,
                "count" to notes.size,
                "latest" to (notes.firstOrNull()?.optString("title") ?: ""),
                "lastTime" to (notes.firstOrNull()?.optLong("time") ?: 0L),
            )
        }
    }

    @Synchronized
    fun clear(context: Context) {
        items.clear()
        save(context, force = true)
    }

    @Synchronized
    fun count(context: Context): Int {
        load(context)
        return items.size
    }

    private fun toMap(item: JSONObject): Map<String, Any?> {
        val millis = item.optLong("time")
        return mapOf(
            "app" to item.optString("app"),
            "package" to item.optString("package"),
            "title" to item.optString("title"),
            "text" to item.optString("text"),
            "time" to millis,
            "timeText" to android.text.format.DateFormat.format("MM-dd HH:mm", millis).toString(),
            "ongoing" to item.optBoolean("ongoing"),
        )
    }

    private fun appLabel(context: Context, packageName: String): String {
        labels[packageName]?.let { return it }
        val label = try {
            val pm = context.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
        } catch (_: Exception) {
            packageName
        }
        labels[packageName] = label
        return label
    }

    private fun file(context: Context) = File(context.filesDir, FILE)

    private fun load(context: Context) {
        if (loaded) return
        loaded = true
        try {
            val text = file(context).takeIf { it.exists() }?.readText().orEmpty()
            if (text.isBlank()) return
            val array = JSONArray(text)
            for (index in 0 until array.length()) {
                array.optJSONObject(index)?.let { items.addLast(it) }
            }
        } catch (_: Exception) {
        }
    }

    private fun save(context: Context, force: Boolean) {
        val now = System.currentTimeMillis()
        if (!force && now - lastSave < 15_000) return
        lastSave = now
        try {
            val array = JSONArray()
            for (item in items) array.put(item)
            val target = file(context)
            val temp = File(context.filesDir, "$FILE.tmp")
            temp.writeText(array.toString())
            temp.renameTo(target)
        } catch (_: Exception) {
        }
    }
}

/** 通知读取: the listener the person grants in 设置 → 通知使用权. */
class NotificationReaderService : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        runCatching { NotificationStore.record(applicationContext, sbn) }
    }

    companion object {
        /** The component string this service is listed under in the system's enabled list. */
        fun component(context: Context): ComponentName = ComponentName(context, NotificationReaderService::class.java)
    }
}
