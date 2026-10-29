package dev.pocketvm.aiagent

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Keystore-backed encrypted storage for the LLM API key and endpoint settings.
 *
 * SPEC 要求：API key 不得明文存 SharedPreferences，用 AndroidKeyStore backing
 * 的加密存储。本实现只用平台 API，不引入第三方依赖：AES-256-GCM 密钥保存在
 * AndroidKeyStore 中，每条值用随机 IV 加密后以 Base64 存入 SharedPreferences。
 * 明文 key 只在内存中短暂出现，永远不写入日志（见 AgentLog）。
 *
 * Keystore 不可用时抛异常，由调用方如实提示，绝不静默回退到明文存储。
 */
class SecurePrefs(context: Context) {
    private val appContext: Context = context.applicationContext
    private val prefs: SharedPreferences =
        appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    companion object {
        private const val PREFS_NAME = "agent_secure"
        private const val KEY_ALIAS = "aiagent_key"
        private const val KEY_ENDPOINT = "endpoint"
        private const val KEY_API_KEY = "api_key"
        private const val KEY_MODEL = "model"
        private const val KEY_DEBUG = "debug_enabled"
        private const val LEGACY_PREFS_NAME = "agent"
        private const val GCM_TAG_BITS = 128
        private const val IV_BYTES = 12

        fun isAvailable(context: Context): Boolean = try {
            SecurePrefs(context).ensureKey()
            true
        } catch (e: Exception) {
            false
        }

        /**
         * 一次性迁移：把旧版明文 SharedPreferences("agent") 里的 key/endpoint/model
         * 读出、加密存入新存储后删除旧值。值不写入日志。
         */
        fun migrateFromLegacy(context: Context) {
            val legacy = context.getSharedPreferences(LEGACY_PREFS_NAME, Context.MODE_PRIVATE)
            val oldKey = legacy.getString(KEY_API_KEY, null)
            val oldEndpoint = legacy.getString(KEY_ENDPOINT, null)
            val oldModel = legacy.getString(KEY_MODEL, null)
            if (oldKey.isNullOrBlank() && oldEndpoint.isNullOrBlank() && oldModel.isNullOrBlank()) return
            val secure = SecurePrefs(context)
            if (!oldKey.isNullOrBlank()) secure.setApiKey(oldKey)
            if (!oldEndpoint.isNullOrBlank()) secure.setEndpoint(oldEndpoint)
            if (!oldModel.isNullOrBlank()) secure.setModel(oldModel)
            legacy.edit()
                .remove(KEY_API_KEY)
                .remove(KEY_ENDPOINT)
                .remove(KEY_MODEL)
                .apply()
        }
    }

    private fun ensureKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .build()
        gen.init(spec)
        return gen.generateKey()
    }

    private fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, ensureKey())
        val iv = cipher.iv
        require(iv.size == IV_BYTES) { "unexpected GCM IV length" }
        val cipherText = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        val combined = ByteArray(iv.size + cipherText.size)
        iv.copyInto(combined)
        cipherText.copyInto(combined, iv.size)
        return Base64.encodeToString(combined, Base64.NO_WRAP)
    }

    private fun decrypt(encoded: String?): String? {
        if (encoded.isNullOrBlank()) return null
        val combined = Base64.decode(encoded, Base64.NO_WRAP)
        if (combined.size <= IV_BYTES) return null
        val iv = combined.copyOfRange(0, IV_BYTES)
        val cipherText = combined.copyOfRange(IV_BYTES, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            ensureKey(),
            GCMParameterSpec(GCM_TAG_BITS, iv)
        )
        return String(cipher.doFinal(cipherText), Charsets.UTF_8)
    }

    private fun putEncrypted(key: String, value: String) {
        prefs.edit().putString(key, encrypt(value)).apply()
    }

    private fun getDecrypted(key: String): String? = decrypt(prefs.getString(key, null))

    fun getEndpoint(): String = getDecrypted(KEY_ENDPOINT) ?: ""
    fun setEndpoint(v: String) = putEncrypted(KEY_ENDPOINT, v)

    fun getApiKey(): String = getDecrypted(KEY_API_KEY) ?: ""
    fun setApiKey(v: String) = putEncrypted(KEY_API_KEY, v)
    fun hasApiKey(): Boolean = getApiKey().isNotBlank()
    fun clearApiKey() {
        prefs.edit().remove(KEY_API_KEY).apply()
    }

    fun getModel(): String = getDecrypted(KEY_MODEL) ?: ""
    fun setModel(v: String) = putEncrypted(KEY_MODEL, v)

    fun isDebugEnabled(): Boolean = getDecrypted(KEY_DEBUG) == "1"
    fun setDebugEnabled(v: Boolean) = putEncrypted(KEY_DEBUG, if (v) "1" else "0")
}
