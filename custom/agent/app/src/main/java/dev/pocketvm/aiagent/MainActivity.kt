package dev.pocketvm.aiagent

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import android.text.InputType
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.util.concurrent.Executors

/**
 * 单用户 Agent 聊天界面（user 0 唯一用户）。
 *
 * - 自然语言 -> LLM 结构化意图 -> 白名单校验 -> 只读/可逆直接执行，
 *   敏感操作弹出确认框，机主点确认才执行。
 * - 以 / 开头：直接输入结构化意图 JSON，走同一套校验与确认，不调 LLM，
 *   不执行 shell。其他 / 开头文本只显示格式提示。
 * - 设置里的 API key 经 SecurePrefs 加密存储；调试模式默认关闭，
 *   仅 userdebug/eng 构建可用，且只影响调试诊断，不连通 LLM 执行路径。
 */
class MainActivity : Activity() {
    private lateinit var chat: TextView
    private lateinit var input: EditText
    private lateinit var scroll: ScrollView
    private lateinit var securePrefs: SecurePrefs
    private val io = Executors.newSingleThreadExecutor()
    private val history = mutableListOf<Pair<String, String>>()
    private val log = StringBuilder()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        chat = findViewById(R.id.chat)
        input = findViewById(R.id.input)
        scroll = findViewById(R.id.scroll)
        securePrefs = SecurePrefs(this)

        try {
            SecurePrefs.migrateFromLegacy(this)
        } catch (e: Exception) {
            append("旧设置迁移失败：${e.message}（API key 需重新在设置里保存）")
        }

        findViewById<Button>(R.id.send).setOnClickListener { send() }
        findViewById<Button>(R.id.settings).setOnClickListener { showSettings() }
        findViewById<Button>(R.id.log).setOnClickListener { showLog() }

        val encrypted = try {
            SecurePrefs.isAvailable(this)
        } catch (e: Exception) {
            false
        }
        append("AI Agent 就绪（单用户 user 0；加密存储：${if (encrypted) "可用" else "不可用"}；无障碍服务：${if (AgentAccessibilityService.isConnected) "已连接" else "未开启"}）")
        append("输入自然语言给 AI 下指令；敏感操作需确认。以 / 开头 + 结构化意图 JSON 可直接执行（同样走校验与确认）。")
        if (!encrypted) {
            append("注意：加密存储不可用时无法保存 API key，请检查设备 Keystore 状态。")
        }
    }

    private fun cfg(): LlmClient.Config {
        val endpoint = securePrefs.getEndpoint().ifBlank { "https://api.deepseek.com/v1" }
        val model = securePrefs.getModel().ifBlank { "deepseek-chat" }
        return LlmClient.Config(endpoint, securePrefs.getApiKey(), model)
    }

    private fun send() {
        val text = input.text.toString().trim()
        if (text.isEmpty()) return
        input.setText("")
        append("你：$text")

        if (text.startsWith("/")) {
            val jsonText = text.substring(1).trim()
            if (!jsonText.startsWith("{")) {
                append("直接命令格式：/ + 结构化意图 JSON，例如 /{\"action\":\"launch\",\"package\":\"com.example.app\"}。其他文本请直接输入，不加 /。")
                return
            }
            io.execute {
                val outcome = try {
                    AgentEngine.handleDirectIntent(this, jsonText)
                } catch (e: Exception) {
                    AgentEngine.Outcome("处理失败：${e.message}")
                }
                ui { showOutcome(outcome) }
            }
            return
        }

        val snapshot = AgentEngine.trimHistory(history.toList())
        history.add("user" to text)
        io.execute {
            val outcome = try {
                AgentEngine.handle(this, cfg(), snapshot, text)
            } catch (e: Exception) {
                AgentEngine.Outcome("请求失败：${e.message}")
            }
            val display = outcome.display
            if (history.size > AgentEngine.MAX_HISTORY_MESSAGES) {
                history.subList(0, history.size - AgentEngine.MAX_HISTORY_MESSAGES).clear()
            }
            history.add("assistant" to display)
            ui { showOutcome(outcome) }
        }
    }

    /** 展示执行结果；待确认的敏感操作弹出确认框，机主点确认才执行。 */
    private fun showOutcome(outcome: AgentEngine.Outcome) {
        append("AI：${outcome.display}")
        val pending = outcome.pending ?: return
        AlertDialog.Builder(this)
            .setTitle("确认敏感操作")
            .setMessage("是否执行以下操作？\n\n${pending.describe()}\n\n等级：敏感。LLM 的回复不能代替你的确认。")
            .setPositiveButton("确认执行") { _, _ ->
                io.execute {
                    val result = try {
                        AgentEngine.executePending(this, pending)
                    } catch (e: Exception) {
                        "执行失败：${e.message}"
                    }
                    ui { append("已确认执行：$result") }
                }
            }
            .setNegativeButton("取消") { _, _ ->
                AgentLog.logInfo(this, "机主取消了敏感操作：${pending.describe()}")
                append("已取消，未执行。")
            }
            .show()
    }

    private fun showLog() {
        val text = AgentLog.read(this)
        AlertDialog.Builder(this)
            .setTitle("审计日志（不含 API key）")
            .setMessage(text)
            .setPositiveButton("关闭", null)
            .show()
    }

    private fun showSettings() {
        val savedEndpoint: String
        val savedHasKey: Boolean
        val savedModel: String
        val savedDebug: Boolean
        try {
            savedEndpoint = securePrefs.getEndpoint()
            savedHasKey = securePrefs.hasApiKey()
            savedModel = securePrefs.getModel()
            savedDebug = securePrefs.isDebugEnabled()
        } catch (e: Exception) {
            append("无法打开设置：加密存储不可用（${e.message}），请检查设备 Keystore 状态。")
            return
        }
        val view = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 16, 48, 0)
        }
        fun field(hint: String, initial: String, password: Boolean = false): EditText =
            EditText(this).apply {
                this.hint = hint
                setText(initial)
                if (password) inputType =
                    InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                view.addView(this)
            }
        val endpoint = field(
            "API Base（如 https://api.deepseek.com/v1，仅 https）",
            savedEndpoint
        )
        // API key 不回显明文：已保存时留空表示不改。
        val key = field(
            if (savedHasKey) "API Key（已保存，留空不改）" else "API Key",
            "",
            password = true
        )
        val model = field("模型（如 deepseek-chat）", savedModel)
        val debug = CheckBox(this).apply {
            text = "调试模式（仅 userdebug/eng 构建，默认关闭；只影响调试诊断）"
            isChecked = savedDebug
            view.addView(this)
        }

        AlertDialog.Builder(this)
            .setTitle("设置")
            .setView(ScrollView(this).apply { addView(view) })
            .setPositiveButton("保存") { _, _ ->
                try {
                    val endpointText = endpoint.text.toString().trim()
                    securePrefs.setEndpoint(
                        endpointText.ifBlank { "https://api.deepseek.com/v1" }
                    )
                    val keyText = key.text.toString().trim()
                    if (keyText.isNotEmpty()) securePrefs.setApiKey(keyText)
                    securePrefs.setModel(
                        model.text.toString().trim().ifBlank { "deepseek-chat" }
                    )
                    securePrefs.setDebugEnabled(debug.isChecked)
                    append("设置已保存（API key 已加密存储）")
                } catch (e: Exception) {
                    append("保存设置失败：${e.message}（加密存储不可用时无法保存 API key）")
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun ui(block: () -> Unit) = runOnUiThread(block)

    private fun append(line: String) {
        log.append(line).append("\n\n")
        chat.text = log.toString()
        scroll.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }
}
