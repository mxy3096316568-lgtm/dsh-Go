package io.github.ccch1mneyyy.dsh_app.proxy

import java.io.File

/**
 * The one place 内置代理's kernel is launched (ProcessLaunchGuardTest: new launch sites use a
 * reviewed owner). Fixed binary, fixed arguments — nothing here comes from the model or a
 * subscription, so a bad config can only fail to bind its port, not run something else.
 */
object MihomoProcess {
    /**
     * Starts `libmihomo.so -d <dataDir> -f <config>` with its output appended to [log].
     * The caller owns the returned process (stop/destroy).
     */
    fun start(binary: File, dataDir: File, config: File, log: File): Process {
        require(binary.isFile) { "kernel missing: ${binary.absolutePath}" }
        require(config.isFile) { "config missing: ${config.absolutePath}" }
        if (dataDir.isDirectory.not()) dataDir.mkdirs()
        val builder = ProcessBuilder(
            binary.absolutePath,
            "-d", dataDir.absolutePath,
            "-f", config.absolutePath,
        )
            .directory(dataDir)
            .redirectErrorStream(true)
            .redirectOutput(ProcessBuilder.Redirect.appendTo(log))
        return builder.start()
    }
}
