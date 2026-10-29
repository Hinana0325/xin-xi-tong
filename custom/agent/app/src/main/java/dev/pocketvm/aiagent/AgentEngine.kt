package dev.pocketvm.aiagent

import android.content.Context

/**
 * 结构化意图执行引擎（SPEC「执行模型」）。
 *
 * 流程：LLM 只返回结构化意图 JSON -> IntentValidator 白名单校验 ->
 * 只读/可逆直接执行，敏感操作先返回待确认，由机主在界面点确认才执行。
 * LLM 返回的自由文本、shell 命令、Markdown 代码块一律拒绝，不执行。
 * 提示词只描述允许的意图格式，不写“可以执行任意命令”之类的兜底表述。
 */
object AgentEngine {
    private const val SYSTEM = """你是 Android 手机上的系统操作员，代表机主执行操作。
只允许返回以下 JSON 之一（不要 Markdown 代码块、不要多余文字、不要解释）：
{"action":"reply","text":"<回复机主的话>"}
{"action":"launch","package":"<已安装包名>"}
{"action":"tap","target":"<界面元素的文本或描述>"}
{"action":"input_text","text":"<要输入的文本>"}
{"action":"setting","namespace":"system","key":"<白名单内的键，如 screen_brightness>","value":"<范围内的整数>"}
{"action":"query","template":"<白名单内的只读模板名，如 installed_packages、device_prop、battery_status>","params":{}}
{"action":"volume","stream":"music|ring|alarm|notification","level":0}
{"action":"open_settings","page":"wifi|bluetooth|accessibility|display|sound|apps|about"}
{"action":"uninstall","package":"<已安装包名>"}
禁止返回 shell 命令、禁止要求删除系统文件、格式化、改账号密码、发短信/邮件、支付相关操作。不知道或不确定时只返回 reply。"""

    const val MAX_HISTORY_MESSAGES = 20

    data class Outcome(
        val display: String,
        /** 非空表示敏感操作等待机主确认；界面确认后调用 executePending。 */
        val pending: AgentIntent? = null
    )

    /** 截断对话历史，避免无界增长（保留最近 MAX_HISTORY_MESSAGES 条）。 */
    fun trimHistory(history: List<Pair<String, String>>): List<Pair<String, String>> =
        if (history.size <= MAX_HISTORY_MESSAGES) history
        else history.takeLast(MAX_HISTORY_MESSAGES)

    fun handle(
        context: Context,
        cfg: LlmClient.Config,
        history: List<Pair<String, String>>,
        user: String
    ): Outcome {
        val raw = LlmClient.chat(cfg, SYSTEM, trimHistory(history), user)
        val validation = IntentValidator.parse(raw, IntentValidator.installedPackages(context))
        return when (validation) {
            is IntentValidation.Rejected -> {
                AgentLog.logRejected(context, validation.reason)
                Outcome("已拒绝执行：${validation.reason}\n模型原文（截断）：${raw.take(300)}")
            }
            is IntentValidation.Valid -> {
                val intent = validation.intent
                when (intent.tier()) {
                    ConfirmationTier.SENSITIVE -> {
                        AgentLog.logInfo(context, "待确认（敏感）：${intent.describe()}")
                        Outcome(
                            "敏感操作，需你确认后才执行：\n${intent.describe()}",
                            pending = intent
                        )
                    }
                    else -> {
                        val result = IntentExecutor.execute(context, intent)
                        AgentLog.logIntent(context, intent, result)
                        Outcome(result)
                    }
                }
            }
        }
    }

    /** 机主在确认对话框点确认后调用：只执行已校验过的意图。 */
    fun executePending(context: Context, intent: AgentIntent): String {
        val result = IntentExecutor.execute(context, intent)
        AgentLog.logIntent(context, intent, result)
        return result
    }

    /** 机主直接命令（以 / 开头）：同一套校验与确认，不绕过，不调 LLM。 */
    fun handleDirectIntent(context: Context, jsonText: String): Outcome {
        val validation = IntentValidator.parse(jsonText, IntentValidator.installedPackages(context))
        return when (validation) {
            is IntentValidation.Rejected -> {
                AgentLog.logRejected(context, validation.reason)
                Outcome("已拒绝执行：${validation.reason}")
            }
            is IntentValidation.Valid -> {
                val intent = validation.intent
                if (intent.tier() == ConfirmationTier.SENSITIVE) {
                    Outcome(
                        "敏感操作，需你确认后才执行：\n${intent.describe()}",
                        pending = intent
                    )
                } else {
                    val result = IntentExecutor.execute(context, intent)
                    AgentLog.logIntent(context, intent, result)
                    Outcome(result)
                }
            }
        }
    }
}
