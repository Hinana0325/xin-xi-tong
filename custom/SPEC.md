# 定制 Android 系统（PocketVM 专用）

目标：在 PocketVM 虚拟机里运行一个**厂商式定制 Android**：

- 保留 **root**
- 两个用户：**机主**（owner）与 **AI**
- 机主通过 AI 控制手机
- 两个用户**共用全部已安装应用**
- 当前主要适配 PocketVM 的 arm64 虚拟机

镜像在你的构建平台编译；本目录只放**与镜像解耦的定制逻辑**：AI 控制 Agent（APK）、双用户/应用共享脚本、以及给镜像构建用的集成说明。

## 目录

```
custom/
├── SPEC.md                 # 设计规格（用户模型/权限/共享/集成点）
├── agent/                  # AI 控制 Agent（独立 Gradle 工程，可单独编 APK）
└── scripts/                # 双用户与应用共享的 root 脚本
```

## 角色与模型

| 角色 | Android 用户 | 职责 |
|---|---|---|
| 机主 | user 0 | 日常使用；通过聊天界面给 AI 下指令 |
| AI | 次级用户（建议 id 10） | 承载 AI 的身份与数据；以 root/系统权限执行机主指令 |

- AI 不是“另一个桌面用户”，而是一个**有独立用户空间的执行身份**；机主不需要切换到 AI 用户。
- 机主侧的聊天 UI 运行在 user 0；Agent 通过 `su` 跨用户执行（`am start --user 0`、`input`、`settings` 等）。
- 两用户共用应用：系统服务/脚本把 user 0 的应用 `pm install-existing --user <ai>`，反向也同步，保证应用清单一致；应用数据仍按 Android 原生隔离（除非后续做共享数据扩展）。

## Root

- 镜像需为 **userdebug/eng** 构建并带 `su`（或后续集成 Magisk）；`ro.debuggable=1`。
- Agent 只在“允许 root 执行”开启时调用 `su -c`；命令与输出在聊天界面留痕。
- SELinux 建议 permissive（仅 VM 用途），或在镜像里为 Agent 加域。

## AI 控制流程

1. 机主在 Agent 聊天框输入自然语言（或 `/命令` 直接执行）。
2. Agent 把对话与“系统操作员”提示词发给 OpenAI 兼容端点（可配置 base URL / key / model，默认国内可用服务）。
3. 模型只允许返回两种 JSON：
   - `{"action":"shell","command":"..."}`：在 user 0 上以 root 执行；
   - `{"action":"reply","text":"..."}`：纯文本回复。
4. Agent 执行后把结果回灌给模型或直接展示；所有命令与输出写入聊天记录。

## 镜像集成点（你编译时合并）

1. **多用户**：`frameworks/base/core/res/res/values/config.xml` 中 `config_multiuserMaximumUsers` ≥ 2，`config_enableMultiUserUI=true`；首次开机创建 AI 用户（或首启脚本调用 `pm create-user`）。
2. **预装 Agent**：把 `custom/agent` 编出的 APK 放到 `system/priv-app/AiAgent/`（或 product），加 `privapp-permissions` 白名单（INTERNET；如需系统级操作再加 `android.permission.INTERACT_ACROSS_USERS` 等）。
3. **root**：userdebug 构建保留 `su`；或在 product 里加 su 包。
4. **应用共享**：在 `init.rc`/首启服务里运行 `custom/scripts/sync-packages.sh`（需 root），或把逻辑做成系统服务定时同步。
5. **镜像**：PocketVM 侧按现有 Android（ARM64）磁盘导入路径使用；显示链路是当前已知硬阻塞（goldfish/gfxstream HAL），需在镜像侧换 DRM/软件 GL 方案后才能出画面。

## 里程碑

1. Agent APK 可编、可装（普通应用 + su 原型） ✅ 本目录代码
2. 在 root 环境验证：创建 AI 用户、双向同步应用、跨用户启动应用
3. 镜像侧集成：预装、权限、首启脚本、root
4. PocketVM 显示链路（独立平台工程）
