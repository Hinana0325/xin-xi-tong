package dev.pocketvm.aiagent

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import org.json.JSONObject

/**
 * 结构化意图模型与白名单校验（SPEC「执行模型」一节的硬约束）。
 *
 * LLM 只能返回这里列出的动作。任何不在白名单内的动作、字段、键、模板，
 * 以及 "shell" / "command" / 自由文本命令，一律拒绝，永远不执行。
 * 白名单是代码里的硬约束，不是提示词里的软约定。
 */
sealed class AgentIntent {
    data class Reply(val text: String) : AgentIntent()
    data class Launch(val packageName: String) : AgentIntent()
    data class Tap(val target: String) : AgentIntent()
    data class InputText(val text: String) : AgentIntent()
    data class Setting(val namespace: String, val key: String, val value: String) : AgentIntent()
    data class Query(val template: String, val params: Map<String, String>) : AgentIntent()
    data class Volume(val stream: String, val levelPercent: Int) : AgentIntent()
    data class OpenSettings(val page: String) : AgentIntent()
    data class Uninstall(val packageName: String) : AgentIntent()

    /** 给机主看的中文摘要（确认对话框用），不含敏感值以外的原文。 */
    fun describe(): String = when (this) {
        is Reply -> "回复：${text.take(120)}"
        is Launch -> "打开应用：$packageName"
        is Tap -> "点击界面元素：${target.take(80)}"
        is InputText -> "输入文本（${text.length} 字）"
        is Setting -> "修改设置：$namespace.$key = $value"
        is Query -> "只读查询：$template"
        is Volume -> "设置音量：$stream ${levelPercent}%"
        is OpenSettings -> "打开系统设置页：$page"
        is Uninstall -> "卸载应用：$packageName（将打开系统卸载确认）"
    }
}

enum class ConfirmationTier { READ_ONLY, REVERSIBLE, SENSITIVE }

fun AgentIntent.tier(): ConfirmationTier = when (this) {
    is AgentIntent.Reply,
    is AgentIntent.Launch,
    is AgentIntent.Query,
    is AgentIntent.OpenSettings -> ConfirmationTier.READ_ONLY
    is AgentIntent.Tap,
    is AgentIntent.InputText,
    is AgentIntent.Setting,
    is AgentIntent.Volume -> ConfirmationTier.REVERSIBLE
    is AgentIntent.Uninstall -> ConfirmationTier.SENSITIVE
}

sealed class IntentValidation {
    data class Valid(val intent: AgentIntent) : IntentValidation()
    data class Rejected(val reason: String) : IntentValidation()
}

object IntentValidator {
    private val PACKAGE_RE = Regex("^[a-z][a-z0-9_]*(\\.[a-z0-9_]+)+$")
    private val PARAM_VALUE_RE = Regex("^[A-Za-z0-9._\\-]+$")

    /** setting 白名单：逐项登记，键名、类型、范围都在这里。secure/global 目前没有任何登记的键。 */
    private data class SettingRule(val min: Int, val max: Int)

    private val SETTING_ALLOWLIST: Map<String, Map<String, SettingRule>> = mapOf(
        "system" to mapOf(
            "screen_brightness" to SettingRule(0, 255),
            "screen_brightness_mode" to SettingRule(0, 1),
            "screen_off_timeout" to SettingRule(5_000, 600_000)
        )
    )

    /** 只读查询模板：每个模板只对应一条本地拼装的固定命令，参数只取白名单值。 */
    val QUERY_TEMPLATES: Map<String, Set<String>> = mapOf(
        "installed_packages" to emptySet(),
        "device_prop" to setOf(
            "ro.build.version.release",
            "ro.product.model",
            "ro.product.manufacturer",
            "ro.build.version.sdk"
        ),
        "battery_status" to emptySet()
    )

    private val VOLUME_STREAMS = setOf("music", "ring", "alarm", "notification")

    /** open_settings 白名单：键名 -> 系统设置 Intent action。 */
    val SETTINGS_PAGES: Map<String, String> = mapOf(
        "wifi" to android.provider.Settings.ACTION_WIFI_SETTINGS,
        "bluetooth" to android.provider.Settings.ACTION_BLUETOOTH_SETTINGS,
        "accessibility" to android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS,
        "display" to android.provider.Settings.ACTION_DISPLAY_SETTINGS,
        "sound" to android.provider.Settings.ACTION_SOUND_SETTINGS,
        "apps" to android.provider.Settings.ACTION_MANAGE_APPLICATIONS_SETTINGS,
        "about" to android.provider.Settings.ACTION_DEVICE_INFO_SETTINGS
    )

    private val SHELL_META = setOf(';', '&', '|', '$', '`', '\n', '\r', '>', '<')

    /**
     * 校验 LLM 返回的原始文本。要求：整体就是一个 JSON 对象（不接受 Markdown
     * 代码块、不接受前后多余文字），动作、字段、参数全部在白名单内。
     * [installedPackages] 由调用方用 PackageManager 查出，供 launch/uninstall 校验。
     */
    fun parse(raw: String, installedPackages: Set<String>): IntentValidation {
        val text = raw.trim()
        if (text.isEmpty()) return IntentValidation.Rejected("模型返回为空")
        if (text.contains("```")) return IntentValidation.Rejected("不接受 Markdown 代码块包裹的意图")
        if (!text.startsWith("{") || !text.endsWith("}")) {
            return IntentValidation.Rejected("意图必须是单个 JSON 对象，不接受自由文本或多余文字")
        }
        val obj = try {
            JSONObject(text)
        } catch (e: Exception) {
            return IntentValidation.Rejected("意图 JSON 解析失败：${e.message}")
        }
        return validate(obj, installedPackages)
    }

    fun validate(obj: JSONObject, installedPackages: Set<String>): IntentValidation {
        val action = obj.optString("action")
        if (action.isBlank()) return IntentValidation.Rejected("意图缺少 action 字段")
        // 显式拒绝 shell 类动作：LLM 的自由文本永远不能变成 shell 命令。
        if (action in setOf("shell", "command", "exec", "run", "sh", "su")) {
            return IntentValidation.Rejected("已拒绝 shell 类动作：$action 不在白名单内")
        }
        val keys = obj.keys().asSequence().toSet()
        fun onlyAllowed(allowed: Set<String>): IntentValidation.Rejected? {
            val extra = keys - allowed - "action"
            return if (extra.isNotEmpty()) {
                IntentValidation.Rejected("意图含有未登记字段：${extra.joinToString(",")}")
            } else null
        }
        fun requiredString(field: String, maxLen: Int): String? {
            if (!obj.has(field) || obj.isNull(field)) return null
            val v = try { obj.getString(field) } catch (e: Exception) { return null }
            return if (v.length <= maxLen) v else null
        }

        return when (action) {
            "reply" -> {
                onlyAllowed(setOf("text"))?.let { return it }
                val t = requiredString("text", 2000)
                    ?: return IntentValidation.Rejected("reply 需要非空 text（不超过 2000 字）")
                if (t.isBlank()) return IntentValidation.Rejected("reply 文本不能为空")
                IntentValidation.Valid(AgentIntent.Reply(t))
            }
            "launch" -> {
                onlyAllowed(setOf("package"))?.let { return it }
                val pkg = requiredString("package", 200)
                    ?: return IntentValidation.Rejected("launch 需要 package 字段")
                if (!PACKAGE_RE.matches(pkg)) return IntentValidation.Rejected("包名格式不合法：$pkg")
                if (pkg !in installedPackages) return IntentValidation.Rejected("包名不在已安装列表里：$pkg")
                IntentValidation.Valid(AgentIntent.Launch(pkg))
            }
            "tap" -> {
                onlyAllowed(setOf("target"))?.let { return it }
                val target = requiredString("target", 200)
                    ?: return IntentValidation.Rejected("tap 需要 target 字段")
                if (target.isBlank()) return IntentValidation.Rejected("tap 的 target 不能为空")
                IntentValidation.Valid(AgentIntent.Tap(target))
            }
            "input_text" -> {
                onlyAllowed(setOf("text"))?.let { return it }
                val t = requiredString("text", 1000)
                    ?: return IntentValidation.Rejected("input_text 需要 text 字段（不超过 1000 字）")
                IntentValidation.Valid(AgentIntent.InputText(t))
            }
            "setting" -> {
                onlyAllowed(setOf("namespace", "key", "value"))?.let { return it }
                val ns = requiredString("namespace", 32)
                    ?: return IntentValidation.Rejected("setting 需要 namespace 字段")
                val key = requiredString("key", 100)
                    ?: return IntentValidation.Rejected("setting 需要 key 字段")
                val value = requiredString("value", 200)
                    ?: return IntentValidation.Rejected("setting 需要 value 字段")
                val rules = SETTING_ALLOWLIST[ns]
                    ?: return IntentValidation.Rejected("setting 的 namespace 不在白名单内：$ns")
                val rule = rules[key]
                    ?: return IntentValidation.Rejected("设置键不在白名单内：$ns.$key")
                val num = value.toIntOrNull()
                    ?: return IntentValidation.Rejected("设置值必须是整数：$value")
                if (num !in rule.min..rule.max) {
                    return IntentValidation.Rejected("设置值超出白名单范围：$num（允许 ${rule.min}..${rule.max}）")
                }
                IntentValidation.Valid(AgentIntent.Setting(ns, key, value))
            }
            "query" -> {
                onlyAllowed(setOf("template", "params"))?.let { return it }
                val template = requiredString("template", 64)
                    ?: return IntentValidation.Rejected("query 需要 template 字段")
                val allowedParams = QUERY_TEMPLATES[template]
                    ?: return IntentValidation.Rejected("查询模板不在白名单内：$template")
                val params = mutableMapOf<String, String>()
                if (obj.has("params") && !obj.isNull("params")) {
                    val p = try { obj.getJSONObject("params") } catch (e: Exception) {
                        return IntentValidation.Rejected("query 的 params 必须是 JSON 对象")
                    }
                    for (k in p.keys()) {
                        val v = try { p.getString(k) } catch (e: Exception) {
                            return IntentValidation.Rejected("query 参数值必须是字符串")
                        }
                        if (v.any { it in SHELL_META }) {
                            return IntentValidation.Rejected("查询参数含有 shell 元字符，已拒绝")
                        }
                        if (!PARAM_VALUE_RE.matches(v)) {
                            return IntentValidation.Rejected("查询参数字符不在白名单内：$k")
                        }
                        params[k] = v
                    }
                }
                when (template) {
                    "device_prop" -> {
                        val key = params["key"]
                            ?: return IntentValidation.Rejected("device_prop 需要 params.key")
                        if (key !in allowedParams) {
                            return IntentValidation.Rejected("getprop 键不在白名单内：$key")
                        }
                        if (params.keys != setOf("key")) {
                            return IntentValidation.Rejected("device_prop 只允许 params.key 一个参数")
                        }
                    }
                    else -> {
                        if (params.isNotEmpty()) {
                            return IntentValidation.Rejected("模板 $template 不接受参数")
                        }
                    }
                }
                IntentValidation.Valid(AgentIntent.Query(template, params))
            }
            "volume" -> {
                onlyAllowed(setOf("stream", "level"))?.let { return it }
                val stream = requiredString("stream", 32)
                    ?: return IntentValidation.Rejected("volume 需要 stream 字段")
                if (stream !in VOLUME_STREAMS) {
                    return IntentValidation.Rejected("音量流不在白名单内：$stream")
                }
                val level = intField(obj, "level")
                    ?: return IntentValidation.Rejected("volume 需要整数 level（0..100，百分比）")
                if (level !in 0..100) return IntentValidation.Rejected("音量超出范围：$level（允许 0..100）")
                IntentValidation.Valid(AgentIntent.Volume(stream, level))
            }
            "open_settings" -> {
                onlyAllowed(setOf("page"))?.let { return it }
                val page = requiredString("page", 32)
                    ?: return IntentValidation.Rejected("open_settings 需要 page 字段")
                if (page !in SETTINGS_PAGES) {
                    return IntentValidation.Rejected("设置页不在白名单内：$page")
                }
                IntentValidation.Valid(AgentIntent.OpenSettings(page))
            }
            "uninstall" -> {
                onlyAllowed(setOf("package"))?.let { return it }
                val pkg = requiredString("package", 200)
                    ?: return IntentValidation.Rejected("uninstall 需要 package 字段")
                if (!PACKAGE_RE.matches(pkg)) return IntentValidation.Rejected("包名格式不合法：$pkg")
                if (pkg !in installedPackages) return IntentValidation.Rejected("包名不在已安装列表里：$pkg")
                if (pkg == "dev.pocketvm.aiagent") {
                    return IntentValidation.Rejected("不允许卸载 Agent 自身")
                }
                IntentValidation.Valid(AgentIntent.Uninstall(pkg))
            }
            else -> IntentValidation.Rejected("未知 action，不在白名单内：$action")
        }
    }

    private fun intField(obj: JSONObject, field: String): Int? {
        if (!obj.has(field) || obj.isNull(field)) return null
        return try {
            when (val v = obj.get(field)) {
                is Number -> v.toInt()
                is String -> v.toIntOrNull()
                else -> null
            }
        } catch (e: Exception) {
            null
        }
    }

    /** 供 AgentEngine 使用：查出已安装包名集合（启动器可见应用 + 已安装应用）。 */
    fun installedPackages(context: Context): Set<String> {
        val pm: PackageManager = context.packageManager
        val out = mutableSetOf<String>()
        try {
            val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            for (info in pm.queryIntentActivities(launcher, 0)) {
                info.activityInfo?.packageName?.let { out.add(it) }
            }
        } catch (e: Exception) {
            // 查不到也不中断：launch 校验会按空集合拒绝，属安全失败。
        }
        try {
            for (app in pm.getInstalledApplications(0)) out.add(app.packageName)
        } catch (e: Exception) {
        }
        return out
    }
}
