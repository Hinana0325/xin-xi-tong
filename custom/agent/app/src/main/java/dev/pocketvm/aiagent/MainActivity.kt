package dev.pocketvm.aiagent

import android.app.Activity
import android.app.AlertDialog
import android.content.SharedPreferences
import android.os.Bundle
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.util.concurrent.Executors

class MainActivity : Activity() {
    private lateinit var chat: TextView
    private lateinit var input: EditText
    private lateinit var scroll: ScrollView
    private lateinit var prefs: SharedPreferences
    private val io = Executors.newSingleThreadExecutor()
    private val history = mutableListOf<Pair<String, String>>()
    private val log = StringBuilder()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        chat = findViewById(R.id.chat)
        input = findViewById(R.id.input)
        scroll = findViewById(R.id.scroll)
        prefs = getSharedPreferences("agent", MODE_PRIVATE)

        findViewById<Button>(R.id.send).setOnClickListener { send() }
        findViewById<Button>(R.id.settings).setOnClickListener { showSettings() }
        findViewById<Button>(R.id.sync).setOnClickListener { syncApps() }

        append("AI Agent 就绪（root=${RootShell.isRoot()}）")
        append("输入自然语言给 AI 下指令；以 / 开头则直接 root 执行。")
    }

    private fun cfg() = LlmClient.Config(
        prefs.getString("endpoint", "https://api.deepseek.com/v1")!!,
        prefs.getString("key", "")!!,
        prefs.getString("model", "deepseek-chat")!!
    )

    private fun send() {
        val text = input.text.toString().trim()
        if (text.isEmpty()) return
        input.setText("")
        append("你：$text")

        if (text.startsWith("/")) {
            val cmd = text.substring(1)
            io.execute {
                val out = RootShell.run(cmd)
                ui { append("$ $cmd\n$out") }
            }
            return
        }

        val allowRoot = prefs.getBoolean("allow_root", true)
        val snapshot = history.toList()
        history.add("user" to text)
        io.execute {
            val outcome = try {
                AgentEngine.handle(cfg(), snapshot, text, allowRoot)
            } catch (e: Exception) {
                AgentEngine.Outcome("请求失败：${e.message}", null)
            }
            history.add("assistant" to outcome.display)
            ui { append("AI：${outcome.display}") }
        }
    }

    private fun syncApps() {
        val aiUser = prefs.getInt("ai_user", 10)
        append("开始同步应用到用户 $aiUser ...")
        io.execute {
            val r = PackageSync.syncBoth(aiUser)
            ui { append(r) }
        }
    }

    private fun showSettings() {
        val view = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 16, 48, 0)
        }
        fun field(hint: String, key: String): EditText = EditText(this).apply {
            this.hint = hint
            setText(prefs.getString(key, ""))
            view.addView(this)
        }
        val endpoint = field("API Base（如 https://api.deepseek.com/v1）", "endpoint")
        val key = field("API Key", "key")
        val model = field("模型（如 deepseek-chat）", "model")
        val aiUser = EditText(this).apply {
            hint = "AI 用户 id"
            setText(prefs.getInt("ai_user", 10).toString())
            view.addView(this)
        }
        val allowRoot = CheckBox(this).apply {
            text = "允许 AI 以 root 执行命令"
            isChecked = prefs.getBoolean("allow_root", true)
            view.addView(this)
        }

        AlertDialog.Builder(this)
            .setTitle("设置")
            .setView(ScrollView(this).apply { addView(view) })
            .setPositiveButton("保存") { _, _ ->
                prefs.edit()
                    .putString("endpoint", endpoint.text.toString().trim().ifBlank { "https://api.deepseek.com/v1" })
                    .putString("key", key.text.toString().trim())
                    .putString("model", model.text.toString().trim().ifBlank { "deepseek-chat" })
                    .putInt("ai_user", aiUser.text.toString().trim().toIntOrNull() ?: 10)
                    .putBoolean("allow_root", allowRoot.isChecked)
                    .apply()
                append("设置已保存")
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
