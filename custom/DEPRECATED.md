# 已废弃（DEPRECATED）

单用户特权 Agent 修订后，以下双用户设计不再采用。文件保留仅供查阅，
不得调用、不得按其内容建用户或同步应用；后续清理时可整个删除。
设计依据与废弃原因见 `SPEC.md` 末节“已废弃：双用户设计”。

| 项目 | 位置 | 状态 |
|---|---|---|
| 双用户模型（机主 user 0 + AI 次级用户） | SPEC 旧设计 | 已废弃，单用户 user 0 唯一用户 |
| 创建 AI 用户脚本 | `scripts/create-ai-user.sh` | 已废弃，文件头部已标注，不得执行 |
| 双向应用同步脚本 | `scripts/sync-packages.sh` | 已废弃，文件头部已标注，不得执行 |
| 应用清单同步代码 | `agent/.../PackageSync.kt` | 已废弃：`syncBoth` 不再执行任何命令，只返回废弃说明 |
| Agent 界面“同步应用”按钮 | 旧 `MainActivity` | 已废弃：已替换为“查看日志”按钮 |
| 跨用户执行（`am start --user`、跨用户 su）与 `INTERACT_ACROSS_USERS` | 旧代码/脚本 | 已废弃，全代码中不再出现跨用户调用 |
| “LLM 自由文本命令经 su 执行”旧流程 | 旧 `AgentEngine`/`RootShell.run` | 已废弃：`RootShell.run` 保留签名但一律拒绝；调试 su 仅走 `runDebug` 白名单 |

`scripts/install-agent.sh` 不在废弃之列，已改为仅安装到 user 0（去掉
AI 用户参数与跨用户安装命令）。
