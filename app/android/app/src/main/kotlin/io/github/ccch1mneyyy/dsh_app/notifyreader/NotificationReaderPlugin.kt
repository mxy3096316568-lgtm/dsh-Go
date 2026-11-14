package io.github.ccch1mneyyy.dsh_app.notifyreader

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** 通知中枢: the person's recent notifications, read through the listener they granted. */
class NotificationReaderPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var app: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        app = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dsh/notifications").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        app = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = app ?: return result.success(null)
        when (call.method) {
            "status" -> result.success(
                mapOf(
                    "granted" to isGranted(context),
                    "count" to NotificationStore.count(context),
                ),
            )
            "openSettings" -> result.success(openSettings(context))
            "list" -> result.success(
                NotificationStore.list(
                    context,
                    (call.argument<Number>("limit")?.toInt() ?: 30).coerceIn(1, 200),
                    call.argument<String>("app"),
                ),
            )
            "search" -> result.success(
                NotificationStore.search(
                    context,
                    call.argument<String>("query") ?: "",
                    (call.argument<Number>("limit")?.toInt() ?: 30).coerceIn(1, 200),
                ),
            )
            "summary" -> result.success(NotificationStore.summary(context))
            "clear" -> {
                NotificationStore.clear(context)
                result.success(mapOf("ok" to true))
            }
            else -> result.notImplemented()
        }
    }

    private fun isGranted(context: Context): Boolean {
        val enabled = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners") ?: return false
        val mine = NotificationReaderService.component(context)
        return enabled.split(':').any { part ->
            val name = ComponentName.unflattenFromString(part) ?: return@any false
            name.packageName == mine.packageName && name.className == mine.className
        }
    }

    private fun openSettings(context: Context): Boolean {
        val intents = listOf(
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS),
            Intent(Settings.ACTION_SETTINGS),
        )
        for (intent in intents) {
            val started = runCatching {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }.isSuccess
            if (started) return true
        }
        return false
    }
}
