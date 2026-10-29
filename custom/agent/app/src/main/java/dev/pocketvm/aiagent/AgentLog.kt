package dev.pocketvm.aiagent

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 应用私有审计日志：每条意图、校验结果、执行结果、拒绝原因都写入这里，
 * 可在界面查看。日志里绝不记 API key 与完整请求体；字符串值一律截断。
 */
object AgentLog {
    private const val FILE_NAME = "agent_log.txt"
    private const val MAX_BYTES = 128 * 1024
    private const val KEEP_LINES = 200

    @Synchronized
    fun append(context: Context, line: String) {
        try {
            val file = File(context.filesDir, FILE_NAME)
            if (file.exists() && file.length() > MAX_BYTES) {
                val lines = file.readLines().takeLast(KEEP_LINES)
                file.writeText(lines.joinToString("\n") + "\n")
            }
            val ts = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US).format(Date())
            file.appendText("[$ts] $line\n")
        } catch (e: Exception) {
            // 日志失败不得影响主流程，也不向外暴露。
        }
    }

    fun logIntent(context: Context, intent: AgentIntent, result: String) {
        val safe = result.take(500).replace("\n", " ")
        append(context, "${intent.tier()} ${intent.describe().take(200)} -> $safe")
    }

    fun logRejected(context: Context, reason: String) {
        append(context, "REJECTED ${reason.take(300)}")
    }

    fun logInfo(context: Context, message: String) {
        append(context, message.take(300))
    }

    fun read(context: Context): String {
        return try {
            val file = File(context.filesDir, FILE_NAME)
            if (!file.exists()) "(暂无日志)" else file.readText().takeLast(8000)
        } catch (e: Exception) {
            "(读取日志失败：${e.message})"
        }
    }
}
