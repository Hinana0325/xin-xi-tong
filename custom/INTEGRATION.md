# AI Agent 镜像集成说明（单用户特权 Agent，QEMU virt 专用）

> 适用范围：仅 QEMU `virt` 虚拟机。不涉及真机固件、刷机或机型相关代码。
> 设计依据：`custom/SPEC.md`（单用户 user 0、priv-app、白名单 + 确认分级）。
> 本文件只讲“怎么装进镜像”，Agent 自身行为见代码注释与 SPEC。

## 1. 这是什么

AI 控制 Agent 是一个预装特权应用（priv-app），在同一个用户（user 0，唯一用户）
内执行机主指令。它不代表机主持有另一套账号和数据，操作的都是机主自己的应用。
单用户设计的代价：Agent 出问题的影响范围就是机主本人的用户空间，没有第二道
用户隔离墙，所以执行必须靠白名单 + 确认分级兜底。

## 2. 预装位置与白名单

1. 把 `custom/agent` 编出的 APK 放到镜像的
   `system/priv-app/AiAgent/`（或 product 分区对应位置），APK 文件名建议
   `AiAgent.apk`，包名 `dev.pocketvm.aiagent`。
2. 把 `custom/privapp-permissions/privapp-permissions-aiagent.xml`
   复制到镜像的 `etc/permissions/`（随 APK 所在分区：system 分区放
   `system/etc/permissions/`，product 分区放 `product/etc/permissions/`）。
   目前白名单里只有一项特权权限，并写清了理由：
   - `android.permission.DUMP`：只读查询（`dumpsys battery` 等白名单模板）
     的执行需要；查询命令由代码按模板本地拼装，不走 su。
3. 明确不给的权限：
   - 不申请 `INTERACT_ACROSS_USERS` 及任何跨用户权限；
   - 不申请 `WRITE_SECURE_SETTINGS`（secure/global 设置键目前没有任何登记项）；
   - `WRITE_SETTINGS`（亮度等白名单键）是 appop 权限，不走 priv-app 白名单，
     需机主在系统设置中授予；未授予时执行器如实报告，不静默绕过。

## 3. 首次使用（机主手动完成，Agent 不得静默自授）

1. 打开 Agent，在“设置”里填 LLM 端点（只允许 `https`，`http` 会被拒绝）、
   API key、模型。API key 用 AndroidKeyStore  backing 的 AES-256-GCM 加密
   存储（`SecurePrefs`，零第三方依赖）；旧版明文 SharedPreferences 里如有
   残留 key，首次启动会迁移到加密存储并删除旧值。
2. 如需界面点击/输入操作，在系统设置 > 无障碍中手动开启
   “AI Agent 界面操作”服务。未开启时 tap/input 意图如实报告不可用。
3. 如需修改亮度等设置，在系统设置中允许本应用“修改系统设置”。

## 4. 执行模型（代码硬约束，摘要）

- LLM 只能返回结构化意图 JSON（`reply` / `launch` / `tap` / `input_text` /
  `setting` / `query` / `volume` / `open_settings` / `uninstall`），全部在
  `IntentValidator` 的白名单里校验：未知动作、多余字段、包名未安装、
  设置键未登记、值超范围、查询参数含 shell 元字符，一律拒绝。
- `shell` / 自由文本命令永远不执行；`AgentEngine` 与 `IntentExecutor` 中
  没有任何 su 调用。执行走 Android API / Intent / 无障碍服务；只读查询
  走本地拼装的白名单命令（`QueryRunner`，不走 su）。
- 确认分级：只读与可逆操作直接执行并记日志；敏感操作（目前仅 `uninstall`，
  且系统应用、Agent 自身均拒绝）必须由机主在确认框点确认才执行，
  LLM 的回复不能代替确认。
- `su` 只在 userdebug/eng 构建的调试诊断里作兜底（`RootShell.runDebug`），
  需同时满足：userdebug/eng 构建 + 机主在设置里打开调试模式（默认关闭）+
  命令是固定诊断白名单。正式路径不依赖 su。
- 每条意图、校验结果、执行结果、拒绝原因写入应用私有审计日志
  （`agent_log.txt`），界面“查看日志”可看；日志里不记 API key 与完整请求体。
- 对话历史上限 20 条；LLM 超时/异常展示截断后的错误原文，不当 JSON 解析执行。

## 5. 不做的事情（单用户修订后）

- 不建 AI 用户，不改多用户配置，不做 `pm create-user`，不做首启建用户脚本。
- 不做双用户应用同步：`scripts/create-ai-user.sh`、`scripts/sync-packages.sh`、
  `PackageSync` 已废弃（见 `custom/DEPRECATED.md`），保留文件仅供查阅，
  不得调用；`scripts/install-agent.sh` 已改为仅安装到 user 0。
- 不做真机适配：不含设备固件、刷机、机型驱动或 Verified Boot 相关内容。

## 6. 构建与验证（本机未构建）

构建（需 JDK 17 + Android SDK 35，本 VM 无 SDK，未运行；本工程目前没有
Gradle wrapper，需用已安装的 Gradle 8.7+，或自行生成 wrapper 后再编）：

```sh
cd custom/agent
gradle :app:assembleDebug
gradle :app:testDebugUnitTest
```

产物：`agent/app/build/outputs/apk/debug/app-debug.apk`。

在 QEMU virt 镜像里验证时至少覆盖：意图校验与拒绝（shell/越界/未登记键）、
白名单查询、敏感操作确认分级、无障碍界面操作、审计日志留痕、https-only
拒绝 http 端点、API key 加密存储（检查 SharedPreferences 文件中无明文 key）。

## 7. 已知阻塞（镜像侧，与本目录无关）

显示链路是当前已知硬阻塞（goldfish/gfxstream HAL），需在镜像侧换
DRM/软件 GL 方案后才能出画面；与 Agent 代码无关，见 SPEC 末节。
