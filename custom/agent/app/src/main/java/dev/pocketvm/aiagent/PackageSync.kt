package dev.pocketvm.aiagent

/** 机主（user 0）与 AI 用户之间的应用清单双向同步。 */
object PackageSync {
    private fun packages(user: Int): Set<String> =
        RootShell.run("pm list packages --user $user")
            .lineSequence()
            .map { it.trim().removePrefix("package:") }
            .filter { it.isNotEmpty() && !it.startsWith("执行失败") }
            .toSet()

    fun syncBoth(aiUser: Int): String {
        val owner = packages(0)
        val ai = packages(aiUser)
        if (owner.isEmpty() || ai.isEmpty()) {
            return "读取应用列表失败（owner=${owner.size}，ai=${ai.size}）；请确认 root 与用户 $aiUser 存在"
        }
        val toAi = owner - ai
        val toOwner = ai - owner
        val sb = StringBuilder()
        for (p in toAi) {
            val r = RootShell.run("pm install-existing --user $aiUser $p").trim()
            sb.append("→ AI   $p  ${r.take(60)}\n")
        }
        for (p in toOwner) {
            val r = RootShell.run("pm install-existing --user 0 $p").trim()
            sb.append("→ 机主 $p  ${r.take(60)}\n")
        }
        sb.append("完成：机主 ${owner.size} 个应用，AI ${ai.size} 个，补装 ${toAi.size + toOwner.size} 个")
        return sb.toString()
    }
}
