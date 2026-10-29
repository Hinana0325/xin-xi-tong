package dev.pocketvm.aiagent

/**
 * 已废弃：双用户应用同步（SPEC「已废弃：双用户设计」）。
 *
 * 单用户设计下机主与 Agent 用同一套应用、同一份数据，不需要跨用户同步，
 * 也不需要 INTERACT_ACROSS_USERS 与跨用户 su 调用。本文件仅保留以便查阅，
 * 不得调用：syncBoth 不再执行任何命令，只返回废弃说明。
 * 后续清理时可整个删除本文件（SPEC 亦已注明）。
 */
@Deprecated("双用户同步已废弃：单用户设计不需要跨用户应用同步")
object PackageSync {
    fun syncBoth(aiUser: Int): String =
        "已废弃：双用户应用同步不再使用（单用户设计，user 0 唯一用户）。未执行任何操作。"
}
