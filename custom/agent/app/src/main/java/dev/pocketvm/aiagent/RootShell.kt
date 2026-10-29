package dev.pocketvm.aiagent

import android.os.Build
import java.io.IOException

/**
 * 调试兜底专用（SPEC：su 只在 userdebug/eng 的 VM 调试环境里作兜底）。
 *
 * 硬约束，缺一不可，缺一个就拒绝：
 * 1. 构建类型必须是 userdebug 或 eng；
 * 2. 机主在设置里显式打开了调试模式（默认关闭）；
 * 3. 命令必须是指令白名单里的固定诊断命令之一，不得带参数、不得拼接。
 *
 * 本对象与 LLM 输出没有任何连接：AgentEngine / IntentExecutor 均不调用它。
 * 正式路径（priv-app）不依赖 su；没有 su 时 Agent 降级为纯特权应用能力。
 */
object RootShell {
    /** 仅允许的固定诊断命令，全部无参数、无 shell 元字符。 */
    private val ALLOWED_DIAGNOSTIC_COMMANDS = setOf("id -u", "id")

    fun isUserdebugBuild(): Boolean =
        Build.TYPE == "userdebug" || Build.TYPE == "eng"

    fun isRoot(): Boolean {
        // 仅作状态展示：普通 sh 下的 id，不走 su。
        return try {
            val p = ProcessBuilder("sh", "-c", "id -u")
                .redirectErrorStream(true).start()
            val out = p.inputStream.bufferedReader().use { it.readText() }.trim()
            p.waitFor()
            out == "0"
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 调试诊断执行。调用方必须已确认机主打开了调试开关；
     * 任何不在白名单内的命令一律拒绝，不执行。
     */
    fun runDebug(command: String, debugEnabled: Boolean): String {
        if (!isUserdebugBuild()) {
            return "已拒绝：调试执行仅在 userdebug/eng 构建可用（当前：${Build.TYPE}）"
        }
        if (!debugEnabled) {
            return "已拒绝：调试模式未开启（设置里默认关闭）"
        }
        if (command !in ALLOWED_DIAGNOSTIC_COMMANDS) {
            return "已拒绝：调试命令不在白名单内：$command"
        }
        return try {
            val pb = ProcessBuilder("su", "-c", command).redirectErrorStream(true)
            val p = pb.start()
            val out = p.inputStream.bufferedReader().use { it.readText() }
            p.waitFor()
            out.ifBlank { "(无输出)" }
        } catch (e: IOException) {
            "执行失败：${e.message}（镜像需要 userdebug 的 su）"
        }
    }

    /**
     * 旧入口已废弃：为防止旧代码误调，保留签名但一律拒绝。
     * 不要用它执行任何命令；调试请用 runDebug，正式执行请走 IntentExecutor。
     */
    @Deprecated("LLM 到 su 的路径已废弃，调试请用 runDebug，正式执行请走 IntentExecutor")
    fun run(cmd: String, useSu: Boolean = true): String =
        "已拒绝：自由 shell 执行已废弃（SPEC 单用户设计）。请使用结构化意图。"
}
