package io.github.ccch1mneyyy.dsh_app.notifyreader

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 通知规则: "this word showed up → do this".
 *
 * Two actions for now, both local: `record` keeps the hit in a list the person (and the
 * agent) can read, `remind` also posts one notification of the app's own. Starting a
 * conversation from a rule needs the engine's own API and is left for later.
 *
 * A rule is a plain substring test on app name + title + text, case-insensitive.
 */
object NotificationRules {
    private const val PREFS = "dsh.notify.rules"
    private const val RULES = "rules"
    private const val HITS_FILE = "notify-hits.json"
    private const val MAX_HITS = 200
    const val ACTION_RECORD = "record"
    const val ACTION_REMIND = "remind"

    data class Rule(val keyword: String, val action: String)

    private val hits = ArrayDeque<JSONObject>()

    fun rules(context: Context): List<Rule> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(RULES, null) ?: return emptyList()
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        return (0 until array.length()).mapNotNull { index ->
            val item = array.optJSONObject(index) ?: return@mapNotNull null
            val keyword = item.optString("keyword").trim()
            if (keyword.isEmpty()) null else Rule(keyword, item.optString("action", ACTION_RECORD))
        }
    }

    fun add(context: Context, keyword: String, action: String): List<Rule> {
        val word = keyword.trim()
        if (word.isEmpty()) return rules(context)
        val mode = if (action == ACTION_REMIND) ACTION_REMIND else ACTION_RECORD
        val next = (rules(context).filterNot { it.keyword.equals(word, ignoreCase = true) } + Rule(word, mode)).take(50)
        save(context, next)
        return next
    }

    fun remove(context: Context, keyword: String): List<Rule> {
        val next = rules(context).filterNot { it.keyword.equals(keyword.trim(), ignoreCase = true) }
        save(context, next)
        return next
    }

    private fun save(context: Context, list: List<Rule>) {
        val array = JSONArray()
        for (rule in list) array.put(JSONObject().put("keyword", rule.keyword).put("action", rule.action))
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(RULES, array.toString()).apply()
    }

    /** Called for every recorded notification; returns the rules that matched. */
    @Synchronized
    fun apply(context: Context, app: String, title: String, text: String) {
        val list = rules(context)
        if (list.isEmpty()) return
        val haystack = "$app\n$title\n$text".lowercase()
        for (rule in list) {
            if (!haystack.contains(rule.keyword.lowercase())) continue
            val hit = JSONObject()
                .put("keyword", rule.keyword)
                .put("action", rule.action)
                .put("app", app)
                .put("title", title)
                .put("text", text.take(300))
                .put("time", System.currentTimeMillis())
            hits.addFirst(hit)
            while (hits.size > MAX_HITS) hits.removeLast()
            persistHits(context)
            if (rule.action == ACTION_REMIND) remind(context, rule.keyword, app, title)
        }
    }

    @Synchronized
    fun hits(context: Context, limit: Int): List<Map<String, Any?>> {
        loadHits(context)
        return hits.take(limit).map {
            mapOf(
                "keyword" to it.optString("keyword"),
                "action" to it.optString("action"),
                "app" to it.optString("app"),
                "title" to it.optString("title"),
                "text" to it.optString("text"),
                "time" to it.optLong("time"),
            )
        }
    }

    @Synchronized
    fun clearHits(context: Context) {
        hits.clear()
        persistHits(context)
    }

    private fun remind(context: Context, keyword: String, app: String, title: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel("dsh-rules", "通知规则", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "通知里出现关键词时提醒你"
                },
            )
        }
        val notification = NotificationCompat.Builder(context, "dsh-rules")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("你盯着「$keyword」")
            .setContentText(if (title.isEmpty()) app else "$app：$title")
            .setAutoCancel(true)
            .build()
        runCatching { manager.notify(keyword.hashCode(), notification) }
    }

    private fun file(context: Context) = File(context.filesDir, HITS_FILE)

    private fun loadHits(context: Context) {
        if (hits.isNotEmpty()) return
        val raw = runCatching { file(context).readText() }.getOrNull() ?: return
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return
        for (index in 0 until array.length()) array.optJSONObject(index)?.let { hits.addLast(it) }
    }

    private fun persistHits(context: Context) {
        runCatching {
            val array = JSONArray()
            for (hit in hits) array.put(hit)
            file(context).writeText(array.toString())
        }
    }
}
