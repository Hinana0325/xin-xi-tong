package dev.pocketvm.aiagent

import android.accessibilityservice.AccessibilityService
import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo

/**
 * 无障碍服务：tap / input_text 意图的唯一执行通道（SPEC：界面操作优先用
 * 无障碍服务按节点操作）。坐标只来自节点边界，本实现不接受 LLM 报告的坐标。
 *
 * 需机主在系统设置 > 无障碍中手动开启；未开启时执行器如实报告不可用，
 * 绝不静默绕过。服务本身不读取屏幕内容作他用，不联网。
 */
class AgentAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: AgentAccessibilityService? = null
            private set

        val isConnected: Boolean get() = instance != null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onInterrupt() = Unit

    override fun onAccessibilityEvent(event: android.view.accessibility.AccessibilityEvent?) = Unit

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        if (instance === this) instance = null
        return super.onUnbind(intent)
    }

    /** 按文本/描述查找节点并点击：先精确匹配，再包含匹配。 */
    fun performTap(target: String): String {
        val root = rootInActiveWindow ?: return "无障碍服务未就绪：没有当前窗口"
        val node = findNode(root, target)
            ?: return "未找到界面元素：$target"
        val clicked = clickUpwards(node)
        return if (clicked) "已点击：$target" else "元素不可点击：$target"
    }

    /** 向获得焦点的可编辑节点输入文本；没有焦点节点时找第一个可编辑节点。 */
    fun performInput(text: String): String {
        val root = rootInActiveWindow ?: return "无障碍服务未就绪：没有当前窗口"
        val editable = findEditable(root)
            ?: return "未找到可输入的文本框（请先点一下输入框）"
        val args = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                text
            )
        }
        val ok = editable.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        return if (ok) "已输入 ${text.length} 字" else "输入失败：目标节点拒绝写入"
    }

    private fun findNode(root: AccessibilityNodeInfo, target: String): AccessibilityNodeInfo? {
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        var containsMatch: AccessibilityNodeInfo? = null
        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            val label = node.text?.toString().orEmpty()
            val desc = node.contentDescription?.toString().orEmpty()
            if (label == target || desc == target) return node
            if (containsMatch == null && (label.contains(target) || desc.contains(target))) {
                containsMatch = node
            }
            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { queue.add(it) }
            }
        }
        return containsMatch
    }

    private fun findEditable(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            if (node.isEditable && node.isFocusable) return node
            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { queue.add(it) }
            }
        }
        return null
    }

    private fun clickUpwards(start: AccessibilityNodeInfo): Boolean {
        var node: AccessibilityNodeInfo? = start
        while (node != null) {
            if (node.isClickable && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                return true
            }
            node = node.parent
        }
        return false
    }
}
