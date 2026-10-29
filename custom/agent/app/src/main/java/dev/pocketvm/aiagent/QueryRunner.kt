package dev.pocketvm.aiagent

import java.util.concurrent.TimeUnit

/**
 * 只读查询的执行器。命令字符串由代码按白名单模板在本地拼装，
 * 参数只取白名单值并已在 IntentValidator 里校验过字符集；
 * LLM 返回的任何字符串都不会拼进命令。运行时不走 su。
 * DUMP 权限由 priv-app 白名单授予（见 privapp-permissions 文件）。
 */
object QueryRunner {
    private const val TIMEOUT_SECONDS = 10L
    private const val MAX_OUTPUT = 2000

    fun run(template: String, params: Map<String, String>): String {
        val command = when (template) {
            "installed_packages" -> "pm list packages"
            "device_prop" -> "getprop ${params["key"]}"
            "battery_status" -> "dumpsys battery"
            else -> return "执行失败：查询模板不在白名单内：$template"
        }
        return try {
            val process = ProcessBuilder("sh", "-c", command)
                .redirectErrorStream(true)
                .start()
            val finished = process.waitFor(TIMEOUT_SECONDS, TimeUnit.SECONDS)
            if (!finished) {
                process.destroyForcibly()
                return "执行超时（${TIMEOUT_SECONDS}s）：$template"
            }
            val out = process.inputStream.bufferedReader().use { it.readText() }
            val trimmed = out.trim()
            if (trimmed.isEmpty()) "(无输出)" else trimmed.take(MAX_OUTPUT)
        } catch (e: Exception) {
            "执行失败：${e.message}"
        }
    }
}
