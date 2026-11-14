package io.github.ccch1mneyyy.dsh_app.web

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 网页截图: draws the app's own WebView into a bitmap and saves a JPEG where the engine can
 * read it.
 *
 * Flutter's RepaintBoundary cannot capture a platform view (the WebView is rendered by
 * Android, not by Flutter's layer tree), so the capture happens here: `WebView.draw()`
 * paints the visible viewport onto a software canvas. A hardware-accelerated WebView may
 * draw nothing that way; when the first attempt comes out blank it is retried once with a
 * software layer, then the layer type is put back.
 *
 * Writes to the shared 下载 folder (`下载/DSH-Go/screenshots`) rather than app-private
 * storage, because the agent runs in the same uid and has to read the file back. Old shots
 * are cleaned up after 7 days.
 */
class BrowserShotPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capture" -> capture(call, result)
            else -> result.notImplemented()
        }
    }

    private fun capture(call: MethodCall, result: MethodChannel.Result) {
        val host = activity
        val wanted = call.argument<String>("url")?.takeIf { it.isNotBlank() }
        val web = host?.let { findWebView(it.window.decorView, wanted) }
        if (web == null || web.width <= 0 || web.height <= 0) {
            result.success(mapOf<String, Any?>("error" to "browser_closed"))
            return
        }
        val maxSide = (call.argument<Number>("maxSide")?.toInt() ?: 1600).coerceIn(320, 4096)
        val quality = (call.argument<Number>("quality")?.toInt() ?: 80).coerceIn(30, 95)
        val dir = File(call.argument<String>("dir")?.takeIf { it.isNotBlank() } ?: DEFAULT_DIR)
        val bitmap = try {
            draw(web, maxSide)
        } catch (error: Throwable) {
            result.success(mapOf<String, Any?>("error" to "capture_failed", "message" to "${error.message ?: error}"))
            return
        }
        if (bitmap == null) {
            result.success(mapOf<String, Any?>("error" to "capture_failed", "message" to "页面画不出图"))
            return
        }
        // Compression is the slow part; keep it off the platform thread.
        Thread {
            val saved = try {
                save(bitmap, dir, quality)
            } catch (error: Throwable) {
                null
            } finally {
                bitmap.recycle()
            }
            val answer = if (saved == null) {
                mapOf<String, Any?>("error" to "capture_failed", "message" to "截图保存失败")
            } else {
                mapOf<String, Any?>(
                    "path" to saved.file.absolutePath,
                    "width" to saved.width,
                    "height" to saved.height,
                    "bytes" to saved.file.length(),
                )
            }
            result.success(answer)
        }.start()
    }

    private class Shot(val file: File, val width: Int, val height: Int)

    /**
     * The WebView the browser page paints into, wherever it sits in the activity's view tree.
     *
     * The app can have more than one WebView (the embedded DSH Web UI has its own), so the
     * one whose address matches [wanted] wins; otherwise the biggest one does.
     */
    private fun findWebView(view: View?, wanted: String?): WebView? {
        val found = ArrayList<WebView>()
        collect(view, found)
        if (found.isEmpty()) return null
        if (wanted != null) {
            found.firstOrNull { it.url == wanted }?.let { return it }
        }
        return found.maxByOrNull { it.width.toLong() * it.height }
    }

    private fun collect(view: View?, into: MutableList<WebView>) {
        if (view == null) return
        if (view is WebView && view.width > 0 && view.height > 0) {
            into.add(view)
            return
        }
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) collect(view.getChildAt(index), into)
        }
    }

    private fun draw(web: WebView, maxSide: Int): Bitmap? {
        val width = web.width
        val height = web.height
        if (width <= 0 || height <= 0) return null
        val scale = minOf(1f, maxSide.toFloat() / maxOf(width, height))
        val targetWidth = (width * scale).toInt().coerceAtLeast(1)
        val targetHeight = (height * scale).toInt().coerceAtLeast(1)
        fun paint(): Bitmap {
            val bitmap = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            canvas.scale(targetWidth / width.toFloat(), targetHeight / height.toFloat())
            canvas.translate(-web.scrollX.toFloat(), -web.scrollY.toFloat())
            web.draw(canvas)
            return bitmap
        }
        val hardware = paint()
        if (!looksBlank(hardware)) return hardware
        // Drawn into a software canvas a hardware-accelerated WebView can come out empty.
        hardware.recycle()
        val before = web.layerType
        return try {
            web.setLayerType(View.LAYER_TYPE_SOFTWARE, null)
            val software = paint()
            web.setLayerType(before, null)
            software
        } catch (error: Throwable) {
            runCatching { web.setLayerType(before, null) }
            throw error
        }
    }

    /** A capture that never painted is one colour; real pages are not. */
    private fun looksBlank(bitmap: Bitmap): Boolean {
        val thumb = Bitmap.createScaledBitmap(bitmap, 24, 24, false)
        val pixels = IntArray(24 * 24)
        thumb.getPixels(pixels, 0, 24, 0, 0, 24, 24)
        thumb.recycle()
        // JPEG draws white; a failed draw is fully transparent.
        var transparent = 0
        for (pixel in pixels) if (pixel ushr 24 == 0) transparent++
        return transparent >= pixels.size * 9 / 10
    }

    private fun save(bitmap: Bitmap, dir: File, quality: Int): Shot? {
        if (!dir.exists() && !dir.mkdirs()) return null
        prune(dir)
        val name = "shot-" + SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()) + ".jpg"
        var file = File(dir, name)
        var index = 1
        while (file.exists()) {
            file = File(dir, name.replace(".jpg", "-$index.jpg"))
            index++
        }
        var source = bitmap
        var q = quality
        var attempt = 0
        while (true) {
            FileOutputStream(file).use { out -> source.compress(Bitmap.CompressFormat.JPEG, q, out) }
            if (file.length() > 0 && file.length() <= MAX_BYTES || attempt >= 3) break
            if (q > 45) {
                q -= 10
            } else {
                attempt++
                val smaller = Bitmap.createScaledBitmap(source, (source.width * 3) / 4, (source.height * 3) / 4, true)
                if (smaller !== source) source.recycle()
                source = smaller
            }
        }
        val width = source.width
        val height = source.height
        if (source !== bitmap) source.recycle()
        return if (file.length() > 0) Shot(file, width, height) else null
    }

    /** Seven days of shots; the folder is in shared storage, so it does not grow forever. */
    private fun prune(dir: File) {
        val cutoff = System.currentTimeMillis() - PRUNE_MS
        dir.listFiles()?.forEach { file ->
            if (file.isFile && file.lastModified() < cutoff) runCatching { file.delete() }
        }
    }

    companion object {
        private const val CHANNEL = "dsh/browser-shot"
        private const val DEFAULT_DIR = "/sdcard/Download/DSH-Go/screenshots"
        private const val MAX_BYTES = 500 * 1024
        private const val PRUNE_MS = 7L * 24 * 60 * 60 * 1000
    }
}
