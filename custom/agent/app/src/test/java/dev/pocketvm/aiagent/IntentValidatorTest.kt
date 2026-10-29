package dev.pocketvm.aiagent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** 白名单校验的纯逻辑测试（不依赖 Android 框架）。 */
class IntentValidatorTest {

    private val installed = setOf("com.example.app", "com.example.other")

    @Test
    fun shellActionIsRejected() {
        val r = IntentValidator.parse(
            """{"action":"shell","command":"am start -a android.intent.action.VIEW"}""",
            installed
        )
        assertTrue(r is IntentValidation.Rejected)
    }

    @Test
    fun freeTextIsRejected() {
        val r = IntentValidator.parse("打开浏览器", installed)
        assertTrue(r is IntentValidation.Rejected)
    }

    @Test
    fun markdownFenceIsRejected() {
        val r = IntentValidator.parse(
            "```json\n{\"action\":\"reply\",\"text\":\"hi\"}\n```",
            installed
        )
        assertTrue(r is IntentValidation.Rejected)
    }

    @Test
    fun unknownActionIsRejected() {
        val r = IntentValidator.parse(
            """{"action":"format","target":"/"}""",
            installed
        )
        assertTrue(r is IntentValidation.Rejected)
    }

    @Test
    fun extraFieldIsRejected() {
        val r = IntentValidator.parse(
            """{"action":"reply","text":"hi","command":"id"}""",
            installed
        )
        assertTrue(r is IntentValidation.Rejected)
    }

    @Test
    fun replyIsAccepted() {
        val r = IntentValidator.parse(
            """{"action":"reply","text":"你好"}""",
            installed
        )
        assertTrue(r is IntentValidation.Valid)
        assertEquals(
            AgentIntent.Reply("你好"),
            (r as IntentValidation.Valid).intent
        )
    }

    @Test
    fun launchRequiresInstalledPackage() {
        val missing = IntentValidator.parse(
            """{"action":"launch","package":"com.not.installed"}""",
            installed
        )
        assertTrue(missing is IntentValidation.Rejected)
        val ok = IntentValidator.parse(
            """{"action":"launch","package":"com.example.app"}""",
            installed
        )
        assertTrue(ok is IntentValidation.Valid)
    }

    @Test
    fun brightnessOutOfRangeIsRejected() {
        val r = IntentValidator.parse(
            """{"action":"setting","namespace":"system","key":"screen_brightness","value":"999"}""",
            installed
        )
        assertTrue(r is IntentValidation.Rejected)
    }

    @Test
    fun nonAllowlistedSettingKeyIsRejected() {
        val r = IntentValidator.parse(
            """{"action":"setting","namespace":"secure","key":"android_id","value":"1"}""",
            installed
        )
        assertTrue(r is IntentValidation.Rejected)
    }

    @Test
    fun brightnessInRangeIsAccepted() {
        val r = IntentValidator.parse(
            """{"action":"setting","namespace":"system","key":"screen_brightness","value":"128"}""",
            installed
        )
        assertTrue(r is IntentValidation.Valid)
    }

    @Test
    fun queryShellMetaCharsAreRejected() {
        val r = IntentValidator.parse(
            """{"action":"query","template":"device_prop","params":{"key":"ro.build.version.release;id"}}""",
            installed
        )
        assertTrue(r is IntentValidation.Rejected)
    }

    @Test
    fun queryNonAllowlistedPropIsRejected() {
        val r = IntentValidator.parse(
            """{"action":"query","template":"device_prop","params":{"key":"ro.serialno"}}""",
            installed
        )
        assertTrue(r is IntentValidation.Rejected)
    }

    @Test
    fun uninstallIsSensitiveTier() {
        val r = IntentValidator.parse(
            """{"action":"uninstall","package":"com.example.app"}""",
            installed
        )
        assertTrue(r is IntentValidation.Valid)
        assertEquals(
            ConfirmationTier.SENSITIVE,
            (r as IntentValidation.Valid).intent.tier()
        )
    }

    @Test
    fun uninstallSelfIsRejected() {
        val r = IntentValidator.parse(
            """{"action":"uninstall","package":"dev.pocketvm.aiagent"}""",
            setOf("dev.pocketvm.aiagent")
        )
        assertTrue(r is IntentValidation.Rejected)
    }

    @Test
    fun volumeOutOfRangeIsRejected() {
        val r = IntentValidator.parse(
            """{"action":"volume","stream":"music","level":150}""",
            installed
        )
        assertTrue(r is IntentValidation.Rejected)
    }
}
