package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import org.json.JSONObject

/**
 * 开机自启 / 自己爬起来: what the engine needs to come up without Flutter.
 *
 * The engine's environment comes from Dart (`RuntimePlugin.start`); it is kept here, in the
 * app's private preferences, so a foreground service started from a broadcast (boot, package
 * replaced) can bring the same engine up with no UI and no Flutter engine attached.
 *
 * The map holds the app's own settings (home paths, keys); it is app-private storage, never
 * shared storage, and it is only read back by this package.
 */
object BootStart {
    private const val PREFS = "dsh.keepalive"
    private const val KEY_ENABLED = "boot.enabled"
    private const val KEY_ENV = "boot.env"
    private const val KEY_PHONE = "boot.phoneStorage"

    /** Whether the person asked for the engine to come back after a reboot. */
    fun enabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)

    fun setEnabled(context: Context, value: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, value).apply()
    }

    /** Called on every start that came from Dart, so boot has something to replay. */
    fun remember(context: Context, env: Map<String, String>, phoneStorage: Boolean) {
        if (env.isEmpty()) return
        val json = JSONObject()
        for ((key, value) in env) json.put(key, value)
        prefs(context).edit()
            .putString(KEY_ENV, json.toString())
            .putBoolean(KEY_PHONE, phoneStorage)
            .apply()
    }

    /** The last environment Dart started with, or null when the engine never started here. */
    fun saved(context: Context): Pair<Map<String, String>, Boolean>? {
        val raw = prefs(context).getString(KEY_ENV, null) ?: return null
        val json = runCatching { JSONObject(raw) }.getOrNull() ?: return null
        val values = LinkedHashMap<String, String>()
        for (key in json.keys()) values[key] = json.optString(key)
        if (values.isEmpty()) return null
        return values to prefs(context).getBoolean(KEY_PHONE, false)
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
