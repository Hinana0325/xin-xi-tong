package dev.pocketvm.aiagent

import org.json.JSONObject

/** 把机主的自然语言变成受控的 root 操作。 */
object AgentEngine {
    private const val SYSTEM = """你是 Android 手机上的系统操作员，代表机主执行操作。
只允许返回两种 JSON（不要 Markdown 代码块、不要多余文字）：
1) {"action":"shell","command":"<root shell 命令>"}  —— 用于打开应用、点击、设置、查询等
2) {"action":"reply","text":"<回复机主的话>"}         —— 用于不需要执行命令的回复
执行命令时优先使用 am start / input tap / input text / settings / pm / dumpsys。
不要执行破坏性命令（格式化、删除系统文件），除非机主明确要求。"""

    data class Outcome(val display: String, val command: String?)

    fun handle(
        cfg: LlmClient.Config,
        history: List<Pair<String, String>>,
        user: String,
        allowRoot: Boolean
    ): Outcome {
        val raw = LlmClient.chat(cfg, SYSTEM, history, user)
        val jsonText = extractJson(raw) ?: return Outcome(raw, null)
        return try {
            val obj = JSONObject(jsonText)
            when (obj.optString("action")) {
                "shell" -> {
                    val cmd = obj.optString("command")
                    if (!allowRoot) {
                        Outcome("（设置里未开启 root 执行，已拒绝）\n$cmd", null)
                    } else {
                        Outcome("$ $cmd\n${RootShell.run(cmd)}", cmd)
                    }
                }
                else -> Outcome(obj.optString("text", raw), null)
            }
        } catch (e: Exception) {
            Outcome(raw, null)
        }
    }

    private fun extractJson(s: String): String? {
        val t = s.trim().removePrefix("```json").removePrefix("```").removeSuffix("```").trim()
        val start = t.indexOf('{')
        val end = t.lastIndexOf('}')
        return if (start >= 0 && end > start) t.substring(start, end + 1) else null
    }
}
