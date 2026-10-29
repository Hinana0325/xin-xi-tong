package dev.pocketvm.aiagent

import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * OpenAI 兼容的 Chat Completions 客户端（默认 DeepSeek，可改 base URL）。
 *
 * 安全约束（SPEC）：端点只允许 https；http 与其他 scheme 在联网前就拒绝。
 * 返回异常时展示错误原文（截断），绝不把错误文本当 JSON 解析执行——
 * 那是 AgentEngine 校验层的职责，本客户端只原样返回文本。
 */
object LlmClient {
    data class Config(val endpoint: String, val apiKey: String, val model: String)

    private const val MAX_RESPONSE_CHARS = 131_072

    fun chat(cfg: Config, system: String, history: List<Pair<String, String>>, user: String): String {
        val base = cfg.endpoint.trim().trimEnd('/')
        require(base.isNotBlank()) { "未配置 LLM 端点" }
        val urlText = if (base.endsWith("/chat/completions")) base else "$base/chat/completions"
        val url = URL(urlText)
        require(url.protocol.equals("https", ignoreCase = true)) {
            "仅允许 https 端点，拒绝：${url.protocol}"
        }
        require(url.host.isNotBlank()) { "端点缺少主机名" }

        val messages = JSONArray()
        messages.put(JSONObject().put("role", "system").put("content", system))
        for ((role, text) in history) {
            messages.put(JSONObject().put("role", role).put("content", text))
        }
        messages.put(JSONObject().put("role", "user").put("content", user))

        val body = JSONObject()
            .put("model", cfg.model)
            .put("messages", messages)
            .put("temperature", 0.2)

        val conn = url.openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.connectTimeout = 15000
        conn.readTimeout = 60000
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", "application/json")
        if (cfg.apiKey.isNotBlank()) {
            conn.setRequestProperty("Authorization", "Bearer ${cfg.apiKey}")
        }
        conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }

        val code = conn.responseCode
        val stream = if (code in 200..299) conn.inputStream else conn.errorStream
        val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
        if (code !in 200..299) return "LLM HTTP $code：${text.take(300)}"
        if (text.length > MAX_RESPONSE_CHARS) {
            return "LLM 返回过长（${text.length} 字符），已拒绝解析"
        }

        val json = JSONObject(text)
        val choices = json.optJSONArray("choices")
            ?: return "LLM 返回异常：缺少 choices"
        if (choices.length() == 0) return "LLM 返回异常：choices 为空"
        return choices.getJSONObject(0).getJSONObject("message").getString("content")
    }
}
