package io.github.ccch1mneyyy.dsh_app.keepalive

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.ccch1mneyyy.dsh_app.runtime.BootStart
import io.github.ccch1mneyyy.dsh_app.runtime.DshService

/**
 * 常驻: what 设置 → 能力控制 → 常驻 reads and sets.
 *
 * Only the one piece that needs storage lives here (开机自启: the flag BootReceiver checks,
 * plus whether the engine is up and exempt from battery optimization). The guides that send
 * the person to the system's own pages stay on `dsh/runtime` (batteryExempt /
 * requestBatteryExempt / openVendorSettings), so there is one implementation of them.
 */
class KeepAlivePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dsh/keepalive").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val app = context ?: return result.success(null)
        when (call.method) {
            "status" -> result.success(status(app))
            "setBoot" -> {
                BootStart.setEnabled(app, call.argument<Boolean>("enabled") == true)
                result.success(status(app))
            }
            "ensureService" -> {
                if (!DshService.isRunning) {
                    runCatching {
                        val intent = Intent(app, DshService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            app.startForegroundService(intent)
                        } else {
                            app.startService(intent)
                        }
                    }
                }
                result.success(status(app))
            }
            else -> result.notImplemented()
        }
    }

    private fun status(app: Context): Map<String, Any?> {
        val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "boot" to BootStart.enabled(app),
            "service" to DshService.isRunning,
            "batteryExempt" to power.isIgnoringBatteryOptimizations(app.packageName),
            "replayable" to (BootStart.saved(app) != null),
        )
    }
}
