package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import io.github.ccch1mneyyy.dsh_app.MainActivity

/**
 * 开机自启: after a reboot, or after the app was updated, bring the engine back up in the
 * background — only when the person turned 开机自启 on and a start environment was saved.
 *
 * The service starts as a foreground service with its usual notification; the app itself is
 * not opened (Android does not allow an app to put a screen up from this broadcast).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (MainActivity.inForeground) return
        if (!BootStart.enabled(context) || BootStart.saved(context) == null) return
        runCatching {
            val service = Intent(context, DshService::class.java).setAction(DshService.ACTION_BOOT)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }
        }
    }
}
