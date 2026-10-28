package dev.pocketvm.aiagent

import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** OpenAI 兼容的 Chat Completions 客户端（默认 DeepSeek，可改 base URL）。 */
object LlmClient {
    data class Config(val endpoint: String, val apiKey: String, val model: String)

    fun chat(cfg: Config, system: String, history: List<Pair<String, String>>, user: String): String {
        val base = cfg.endpoint.trimEnd('/')
        val url = if (base.endsWith("/chat/completions")) base else "$base/chat/completions"

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

        val conn = URL(url).openConnection() as HttpURLConnection
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

        val json = JSONObject(text)
        return json.getJSONArray("choices").getJSONObject(0).getJSONObject("message").getString("content")
    }
}
