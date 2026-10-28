package dev.pocketvm.aiagent

import java.io.IOException

/** 以 root（su）执行 shell 命令；镜像需要 userdebug 的 su。 */
object RootShell {
    fun isRoot(): Boolean = run("id -u").trim() == "0"

    fun run(cmd: String, useSu: Boolean = true): String {
        return try {
            val pb = if (useSu) ProcessBuilder("su", "-c", cmd) else ProcessBuilder("sh", "-c", cmd)
            pb.redirectErrorStream(true)
            val p = pb.start()
            val out = p.inputStream.bufferedReader().use { it.readText() }
            p.waitFor()
            out.ifBlank { "(无输出)" }
        } catch (e: IOException) {
            "执行失败：${e.message}（镜像需要 userdebug 的 su）\n"
        }
    }
}
