package io.github.ccch1mneyyy.dsh_app.proxy

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executor

/**
 * 内置代理: mihomo as a local mixed-port proxy, for this app only.
 *
 * The kernel ships as `libmihomo.so` in `nativeLibraryDir` (the only place Android lets an app
 * execute from: `extractNativeLibs=true` in the manifest, `useLegacyPackaging` in Gradle), and
 * listens on 127.0.0.1. WebView is pointed at it through androidx.webkit's ProxyController, and
 * the app's own HTTP clients set `findProxy`. Nothing outside the app is routed, so no VPN and no
 * system-wide change: closing the switch puts everything back.
 *
 * The subscription is fetched and normalised on the Dart side (that is where the YAML parser
 * lives) and written here as a Clash config.
 */
class ProxyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var app: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        app = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dsh/proxy").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        app = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = app ?: return result.success(null)
        when (call.method) {
            "status" -> result.success(status(context))
            "writeConfig" -> {
                val content = call.argument<String>("content")
                if (content.isNullOrBlank()) {
                    result.success(mapOf("error" to "empty_config"))
                } else {
                    result.success(writeConfig(context, content))
                }
            }
            "start" -> result.success(start(context, call.argument<Number>("port")?.toInt() ?: DEFAULT_PORT))
            "stop" -> result.success(stop(context))
            "log" -> result.success(lastLines(logFile(context), 40))
            else -> result.notImplemented()
        }
    }

    private fun status(context: Context): Map<String, Any?> = mapOf(
        "running" to isRunning(),
        "port" to port,
        "webViewProxy" to webViewProxy,
        "kernel" to binary(context).exists(),
        "config" to configFile(context).exists(),
        "error" to lastError,
    )

    private fun writeConfig(context: Context, content: String): Map<String, Any?> = try {
        val dir = dataDir(context)
        val file = configFile(context)
        file.writeText(content)
        mapOf("ok" to true, "path" to file.absolutePath, "bytes" to file.length(), "dir" to dir.absolutePath)
    } catch (error: Exception) {
        mapOf("error" to "write_failed", "message" to "${error.message ?: error}")
    }

    private fun start(context: Context, requestedPort: Int): Map<String, Any?> {
        lastError = null
        if (isRunning()) return status(context)
        val binary = binary(context)
        if (!binary.exists()) {
            lastError = "内核没有打包进来"
            return status(context) + mapOf("error" to "kernel_missing")
        }
        val config = configFile(context)
        if (!config.exists() || config.length() == 0L) {
            lastError = "还没有订阅配置"
            return status(context) + mapOf("error" to "no_config")
        }
        port = requestedPort.coerceIn(1024, 65535)
        return try {
            val log = logFile(context)
            val started = MihomoProcess.start(binary, dataDir(context), config, log)
            process = started
            if (!waitForPort(port, 20000)) {
                started.destroy()
                process = null
                lastError = "内核启动超时（20 秒端口没起来）"
                return status(context) + mapOf("error" to "start_timeout", "log" to lastLines(log, 20))
            }
            setWebViewProxy(context, true)
            status(context)
        } catch (error: Exception) {
            process = null
            lastError = error.message ?: error.toString()
            status(context) + mapOf("error" to "start_failed", "message" to lastError)
        }
    }

    private fun stop(context: Context): Map<String, Any?> {
        setWebViewProxy(context, false)
        process?.let { running ->
            running.destroy()
            try {
                running.waitFor()
            } catch (_: InterruptedException) {
                running.destroyForcibly()
            }
        }
        process = null
        return status(context)
    }

    /** Points WebView at the local port (all WebViews of this app; nothing else). */
    private fun setWebViewProxy(context: Context, enabled: Boolean) {
        val executor = Executor { command -> command.run() }
        try {
            if (enabled) {
                val config = ProxyConfig.Builder()
                    .addProxyRule("127.0.0.1:$port")
                    .addDirect()
                    .build()
                ProxyController.getInstance().setProxyOverride(config, executor) { webViewProxy = true }
            } else {
                ProxyController.getInstance().clearProxyOverride(executor) { webViewProxy = false }
            }
        } catch (error: Exception) {
            // WebView without ProxyController support (very old system WebView): the kernel still
            // runs and the app's own downloads use it; pages just stay direct.
            webViewProxy = false
            lastError = "WebView 不支持代理设置：${error.message ?: error}"
        }
    }

    private fun waitForPort(port: Int, timeoutMs: Int): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (process?.isAlive != true) return false
            try {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress("127.0.0.1", port), 250)
                    return true
                }
            } catch (_: Exception) {
                Thread.sleep(150)
            }
        }
        return false
    }

    private fun dataDir(context: Context): File = File(context.filesDir, "mihomo").apply { mkdirs() }

    private fun configFile(context: Context) = File(dataDir(context), "config.yaml")

    private fun logFile(context: Context) = File(dataDir(context), "mihomo.log")

    /** The kernel itself, where the installer unpacked it (executable there). */
    private fun binary(context: Context) = File(context.applicationInfo.nativeLibraryDir, "libmihomo.so")

    private fun lastLines(file: File, count: Int): List<String> = try {
        if (!file.exists()) emptyList() else file.readLines().takeLast(count)
    } catch (_: Exception) {
        emptyList()
    }

    companion object {
        private const val DEFAULT_PORT = 7890

        private var process: Process? = null

        @Volatile
        private var port = DEFAULT_PORT

        @Volatile
        private var webViewProxy = false

        @Volatile
        private var lastError: String? = null

        private fun isRunning(): Boolean = process?.isAlive == true
    }
}
