package io.github.ccch1mneyyy.dsh_app.speech

import android.content.Context
import java.io.File

/**
 * 语音模型内置: copies the recognizer bundled in the APK (`assets/asr/`) into the
 * directory StreamingAsrModelStore expects, so a fresh install can speak without
 * downloading ~198 MB first.
 *
 * Runs on a background thread at launch. Files already present are left alone,
 * so a model the person downloaded earlier wins. Missing assets (a build without
 * the download step) are ignored: the in-app downloader still works.
 */
object BundledAsrSeeder {
    private const val ASSET_DIR = "asr"

    private val FILES = listOf(
        "encoder-epoch-99-avg-1.int8.onnx",
        "decoder-epoch-99-avg-1.int8.onnx",
        "joiner-epoch-99-avg-1.int8.onnx",
        "tokens.txt",
    )

    /** `getApplicationSupportDirectory()` on Android is `filesDir`, so this is the store's path. */
    fun targetDir(context: Context): File = File(context.filesDir, "speech/streaming-asr")

    fun seedIfNeeded(context: Context) {
        val target = targetDir(context)
        if (FILES.all { File(target, it).exists() }) return
        target.mkdirs()
        for (name in FILES) {
            val out = File(target, name)
            if (out.exists()) continue
            val partial = File(target, "$name.part")
            try {
                context.assets.open("$ASSET_DIR/$name").use { input ->
                    partial.outputStream().use { output -> input.copyTo(output, 1 shl 20) }
                }
                partial.renameTo(out)
            } catch (_: Exception) {
                partial.delete()
            }
        }
    }
}
