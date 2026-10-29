package dev.pocketvm.aiagent

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.provider.Settings

/**
 * 已校验意图的执行器。只接受 IntentValidator.Valid 的意图；
 * 执行走 Android API / Intent，tap 与 input 走无障碍服务，
 * 只读查询走本地拼装的白名单命令（QueryRunner，不走 su）。
 * 这里没有任何 LLM 字符串拼 shell 的路径，也没有任何 su 调用。
 */
object IntentExecutor {

    fun execute(context: Context, intent: AgentIntent): String {
        return try {
            when (intent) {
                is AgentIntent.Reply -> intent.text
                is AgentIntent.Launch -> launch(context, intent.packageName)
                is AgentIntent.Tap -> tap(intent.target)
                is AgentIntent.InputText -> input(intent.text)
                is AgentIntent.Setting -> setting(context, intent)
                is AgentIntent.Query -> QueryRunner.run(intent.template, intent.params)
                is AgentIntent.Volume -> volume(context, intent)
                is AgentIntent.OpenSettings -> openSettings(context, intent.page)
                is AgentIntent.Uninstall -> uninstall(context, intent.packageName)
            }
        } catch (e: SecurityException) {
            "执行失败：缺少权限（${e.message}）。请在系统设置里按提示授予，或确认 priv-app 白名单已生效。"
        } catch (e: Exception) {
            "执行失败：${e.message}"
        }
    }

    private fun launch(context: Context, packageName: String): String {
        val pm = context.packageManager
        val launchIntent = pm.getLaunchIntentForPackage(packageName)
            ?: return "打开失败：找不到该应用的启动入口：$packageName"
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(launchIntent)
        return "已打开：$packageName"
    }

    private fun tap(target: String): String {
        val service = AgentAccessibilityService.instance
            ?: return "无法点击：无障碍服务未开启。请在系统设置 > 无障碍中开启 AI Agent，然后重试。"
        return service.performTap(target)
    }

    private fun input(text: String): String {
        val service = AgentAccessibilityService.instance
            ?: return "无法输入：无障碍服务未开启。请在系统设置 > 无障碍中开启 AI Agent，然后重试。"
        return service.performInput(text)
    }

    private fun setting(context: Context, intent: AgentIntent.Setting): String {
        if (intent.namespace != "system") {
            return "执行失败：当前构建只登记了 system 命名空间的设置键"
        }
        if (!Settings.System.canWrite(context)) {
            return "无法修改设置：未授予“修改系统设置”权限。请在系统设置中允许本应用修改系统设置后重试。"
        }
        val ok = Settings.System.putString(
            context.contentResolver,
            intent.key,
            intent.value
        )
        return if (ok) "已设置 ${intent.key} = ${intent.value}" else "设置失败：系统拒绝写入 ${intent.key}"
    }

    private fun volume(context: Context, intent: AgentIntent.Volume): String {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val stream = when (intent.stream) {
            "music" -> AudioManager.STREAM_MUSIC
            "ring" -> AudioManager.STREAM_RING
            "alarm" -> AudioManager.STREAM_ALARM
            "notification" -> AudioManager.STREAM_NOTIFICATION
            else -> return "执行失败：未知音量流"
        }
        val max = audio.getStreamMaxVolume(stream)
        val level = (max * intent.levelPercent / 100).coerceIn(0, max)
        audio.setStreamVolume(stream, level, 0)
        return "已设置 ${intent.stream} 音量为 ${intent.levelPercent}%"
    }

    private fun openSettings(context: Context, page: String): String {
        val action = IntentValidator.SETTINGS_PAGES[page]
            ?: return "执行失败：设置页不在白名单内：$page"
        val intent = Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        return "已打开系统设置页：$page"
    }

    private fun uninstall(context: Context, packageName: String): String {
        val appInfo = try {
            context.packageManager.getApplicationInfo(packageName, 0)
        } catch (e: Exception) {
            return "卸载失败：应用未安装：$packageName"
        }
        if (appInfo.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM != 0) {
            return "已拒绝：不卸载系统应用：$packageName"
        }
        val intent = Intent(Intent.ACTION_DELETE, Uri.parse("package:$packageName"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        return "已打开系统卸载确认：$packageName（请在系统界面确认）"
    }
}
