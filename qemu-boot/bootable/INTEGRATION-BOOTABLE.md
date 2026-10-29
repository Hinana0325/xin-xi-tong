# 可启动镜像集成流水线（xin-xi-tong / 新系统，仅 QEMU virt 测试）

> 范围：**仅 QEMU `virt` 测试**。不涉及真机固件、vendor blob、fastboot/刷机、
> 设备专属签名与设备 HAL。本流水线不启动 QEMU、不签名、不处理 vbmeta/AVB。
> 所有操作只针对输入 system.img 的**副本**；原始 GSI zip、内核、ramdisk、
> `~/workspace/system-apps`、`~/workspace/xin-xi-tong`、
> `~/workspace/qemu-system-integration/` 原件、`~/workspace/PocketVM` 一律只读，
> 绝不修改。本目录（`~/workspace/bootable-integration/`）是唯一写出目录。

## 0. 本流水线是什么、不是什么

本流水线把四类东西组装成一个 bundle 目录：

1. 集成后的 GSI `system.img` 副本（写入 13 个自研应用 APK，可选写入 Agent APK）；
2. 内核 / ramdisk / boot.img / vbmeta（只复制 + 记 SHA-256，不检验其内容）；
3. 新建的 `userdata.qcow2`（4G）与 `metadata.img`（16M ext4）；
4. `manifest.json`（每个文件的 SHA-256、来源、集成时间、启动缺口）与
   `verify-bootable.sh`（bundle 完整性校验脚本，随 bundle 一起交付）。

**它不是**一次真实集成，也**不证明系统可启动**：截至本文档，13 个应用与
Agent 均无真实 APK（WorkBuddy 编译在另一条线进行，与本流水线无关），本
目录下的测试全部使用假 APK（见 `TEST-RECORD-BOOTABLE.md`）。真实 APK 到达后
只需换 APK 目录重跑（见第 7 节交接清单），流水线本身不需改动。

## 1. 复用来源与出处

| 本目录文件 | 来源 | 改动 |
|---|---|---|
| `integrate.sh` | `~/workspace/qemu-system-integration/integrate.sh` 逐字节复制 | 无改动，SHA-256 `5e6be3da…32c6c`，与原件一致 |
| `replacement-mapping.csv` | `~/workspace/qemu-system-integration/replacement-mapping.csv` 复制 | 无改动，SHA-256 `a29c6838…aa8b` |
| `privapp-permissions-cn.xinxitong.xml` | `~/workspace/qemu-system-integration/privapp-permissions-cn.xinxitong.xml` 复制 | 无改动 |
| `privapp-permissions-aiagent.xml` | `~/workspace/xin-xi-tong/custom/privapp-permissions/privapp-permissions-aiagent.xml` 复制 | 无改动 |
| `integrate-bootable.sh` | 本任务新建（编排层） | — |
| `verify-bootable.sh` | 本任务新建（校验层） | — |

`integrate.sh` 的已知问题（见第 5 节）原样保留在本目录的副本中，不在此
悄悄修掉：上游修好后应重新复制并重新测试，重新核对哈希。

## 2. 输入与输出

### 输入

| 参数 | 必需 | 说明 |
|---|---|---|
| `--system-img-copy` | 二选一 | GSI `system.img` 的副本。拒绝 zip、拒绝 `~/workspace/gsi/` 下的原始文件。或用 `--src-zip` 从 GSI zip 现场解出副本（原始 zip 只读）。 |
| `--apk-dir` | 必需 | 13 个 APK，文件名必须是 `<包名>.apk`（见映射表）。缺任何一个直接失败并列出缺失包名，绝不伪造。每个 APK 必须为合法 zip 且含 `AndroidManifest.xml`。 |
| `--agent-apk` | 可选 | Agent APK（包名 `dev.pocketvm.aiagent`），文件名不限，校验规则与应用 APK 相同。未提供时 bundle 如实标注缺 Agent。 |
| `--kernel` / `--ramdisk` / `--boot-img` / `--vbmeta` | 可选 | 只复制进 bundle 并记 SHA-256。**不检验** ramdisk 内是否有 first-stage init/fstab，也不检验内核版本（见第 6 节缺口）。 |
| `--grow-mb N` | 可选 | 透传给 `integrate.sh`：空间不足时扩容。已实测（见测试记录）。 |
| `--remove-replaced` | **已禁用** | 见第 5 节：实测会损坏文件系统，流水线前置拒绝。 |
| `--label` | 可选 | 写入 manifest 的标签；假 APK 测试用 `dummy-test`。 |
| `--bundle-dir` | 必需 | 输出目录；已存在且非空时需加 `--force` 才清空重建。 |

### 输出（bundle 目录）

```
bundle/
├── system.img                     # 集成后镜像（raw ext4）
├── system-integration.json         # integrate.sh 的集成清单（集成前/后 SHA）
├── kernel-Image                    # 复制的内核 Image（若提供）
├── ramdisk.img                     # 复制的 ramdisk（若提供）
├── boot.img                        # 复制的 boot.img（若提供）
├── vbmeta.img / build.prop         # 复制的 GSI 配套文件（若在输入旁或显式提供）
├── userdata.qcow2                  # 新建 4G qcow2
├── metadata.img                    # 新建 16M ext4
├── replacement-mapping.csv         # 13 行替换映射表（复制件）
├── privapp-permissions-cn.xinxitong.xml
├── privapp-permissions-aiagent.xml
├── manifest.json                   # 全 bundle 清单（SHA-256、来源、缺口）
└── verify-bootable.sh              # 校验脚本（bundle 内副本）
```

## 3. 分步说明

```bash
cd ~/workspace/bootable-integration

# 1) 准备输入副本（示例：从 GSI zip 解出；也可以直接用已解出的副本路径）
#    原始 zip 只读，绝不修改。

# 2) 跑流水线（真 APK 到达后的标准命令，见第 7 节）
./integrate-bootable.sh \
  --system-img-copy <system.img 副本> \
  --apk-dir <13 个 <包名>.apk 的目录> \
  --agent-apk <Agent APK，可选> \
  --kernel <内核 Image> --ramdisk <ramdisk> --boot-img <boot.img> \
  --grow-mb 512 \
  --bundle-dir <输出 bundle 目录>

# 3) 校验 bundle
./verify-bootable.sh --bundle-dir <输出 bundle 目录>
# 或用 bundle 内的副本：
<输出 bundle 目录>/verify-bootable.sh --bundle-dir <输出 bundle 目录>
```

流水线内部顺序（每一步失败即中止，输入原件不受影响）：

1. 校验 13 个 APK 齐全且为合法 zip（含 `AndroidManifest.xml`）；校验 Agent
   APK（若提供）；拒绝 zip 输入与原始 GSI 目录。
2. 把输入 `system.img` 复制到 bundle 内工作区（`.staging/`），在工作区内写
   `.integration-copy-marker`（`integrate.sh` 的副本标记要求），原件不动。
3. 调用复用的 `integrate.sh integrate`：空间检查/扩容 → debugfs 写入 13 个
   APK（0644、`root:root`、`u:object_r:system_file:s0`）→ 写入 cn.xinxitong
   特权白名单草案 → `e2fsck -fn` 复查 → 生成集成清单。
4. 写入 Agent APK 到 `/system/system_ext/priv-app/AiAgent/AiAgent.apk`（同上
   权限/上下文，写入后 dump 回取 SHA-256 核对），写入 Agent 特权白名单草案。
5. 组装 bundle：移动集成后镜像、复制内核/ramdisk/boot/vbmeta、生成
   `userdata.qcow2` 与 `metadata.img`、复制映射表与白名单、复制校验脚本。
6. 生成 `manifest.json`，删除工作区。

幂等性（已实测，见测试记录）：流水线每次都从输入副本重新复制后集成，
重跑产出的镜像内 APK 内容 SHA-256 全部相同、校验同样通过；但整个
`system.img` 文件的 SHA-256 **会变化**（debugfs 写入带时间戳的元数据，
ext4 镜像不保证字节级可复现）。因此“幂等”指内容与校验结果一致，
不指镜像文件字节一致；不要用镜像 SHA-256 判断两次集成是否相同，
应以 `verify-bootable.sh` 的结果与镜像内 APK 的 SHA-256 为准。

## 4. AOSP 保留清单（删了会坏事）

默认策略：**只添加，不删除**。自研应用与 AOSP 应用包名不同，可以共存；
默认角色在首次启动后授予（第 6 节）。下表来自 GSI 镜像 107 个 APK 的
AXML 解析结果（见 `replacement-mapping.csv`，状态 VERIFIED / VERIFIED-ABSENT）
与 `qemu-system-integration/INTEGRATION.md`，流水线不做任何删除。

| 必须保留 | 原因 |
|---|---|
| AOSP Settings（`com.android.settings`） | 自研设置通过 intent 跳转的 Wi-Fi/蓝牙等面板由它提供；两者包名不同可共存 |
| DocumentsUI（`com.android.documentsui`） | 系统文件选择器 / SAF 实现，其他应用依赖；自研文件管理是独立应用，不替代它 |
| TeleService（`com.android.phone`）、TelecomShim（`com.android.server.telecom`） | 通话框架；Dialer 只是 UI，删 Dialer UI 也不得动框架 |
| ContactsProvider（`com.android.providers.contacts`）、CalendarProvider、TelephonyProvider、MmsService（`com.android.mms.service`） | 联系人/日历/电话/短信的数据层，自研应用读这些 provider |
| WebView 引擎（`com.android.webview`）与 `org.chromium.webview_shell`（`Browser2.apk`） | 自研浏览器是 WebView 外壳，依赖引擎；`Browser2.apk` 的包名就是 webview_shell，**不是**独立浏览器 |
| NotesRoleEnabled overlay（`/system/product/overlay/NotesRoleEnabled/`） | 仅启用笔记角色，镜像内无笔记应用；保留 overlay，但备忘录目前因缺 intent-filter 仍成不了角色持有者（见第 6 节） |
| GSI 自带 `gsi_overlay_framework` / `gsi_overlay_systemui` | 镜像已有 overlay；自研应用不需要新增 RRO overlay |

`REMOVE-OPTIONAL` 行（Launcher3QuickStep、Dialer、Contacts、Messaging、
Camera2、Gallery2、DeskClock、Calendar 这 8 个 UI 应用）原则上可删，但
**当前删除实现有 bug**（见第 5 节），在修好之前一律不删。删除后还须
首次启动核对 QuickStep 手势 / SystemUI 是否受影响（未验证）。

## 5. 已知问题：`--remove-replaced` 会损坏文件系统（已实测）

假 APK 测试中，`integrate.sh --remove-replaced` 删除 8 个 AOSP UI 应用目录后，
`e2fsck -fn` 未通过：`Block bitmap differences: +(85379--85385) +340187`，
即 debugfs `rm` 删了文件条目却未同步块位图。`integrate.sh` 自身的写后
复查正确地拒绝了该镜像，流水线随之中止，输入副本未受影响、未产出 bundle。

处置：`integrate-bootable.sh` **前置拒绝** `--remove-replaced`（在复制任何
文件之前失败并说明原因）。在上游修好删除实现（例如删除后用 `e2fsck -fy`
修复位图，或改用 `e2fsdroid` + `fs_config` 重建镜像——两种方案均未验证）
之前，不要绕过此限制去删除 AOSP 应用。

## 6. 默认角色首次启动授予清单（未验证，需启动后逐项核对）

镜像内**无**静态角色配置文件（已在 GSI 镜像 `etc/` 树中检索确认），角色
只能在首次启动进入系统后运行时授予。以下清单按 `qemu-system-integration`
的核实结论整理，流水线不授予任何角色：

| 角色 | 目标应用 | 授予方式（首选） | 状态 |
|---|---|---|---|
| HOME（启动器） | `cn.xinxitong.launcher` | 设置 → 应用 → 默认应用 → 主屏幕应用 | 未验证 |
| ROLE_DIALER（电话） | `cn.xinxitong.phone` | 设置 → 应用 → 默认应用 → 电话应用 | 未验证 |
| ROLE_SMS（短信） | `cn.xinxitong.messages` | 设置 → 应用 → 默认应用 → 短信应用（授予后才有完整短信行为） | 未验证 |
| ROLE_BROWSER（浏览器） | `cn.xinxitong.browser` | 设置 → 应用 → 默认应用 → 浏览器应用 | 未验证 |
| 相册 | `cn.xinxitong.gallery` | 无角色；intent 选择器/“默认打开方式”由用户选择 | — |
| 笔记角色 | `cn.xinxitong.notes` | **已知缺口**：overlay 已启用角色，但备忘录 Manifest 未声明笔记角色 intent（如 `ACTION_CREATE_NOTE`），目前无法成为持有者；需先补 intent-filter 再集成 | 缺口未修 |

另需在首次启动核对（均未验证）：无障碍服务手动开启（Agent 点按/输入才
可用）、`WRITE_SETTINGS` 在系统设置中授予（亮度等）、`MANAGE_EXTERNAL_STORAGE`
在“所有文件访问权限”中授予（文件管理）、写入文件的 SELinux 上下文在
`ls -Z` 下确为 `system_file`（debugfs `ea_set` 写入的上下文为 25 字节，
原镜像文件为 26 字节含结尾 NUL，`verify-bootable.sh` 会对此发警告）。

### 启动缺口（流水线不解决，manifest.json 的 boot_blockers 同样列出）

1. **first-stage ramdisk / vendor_boot**：已知 QEMU 启动尝试的结论是
   virtual-device initramfs 只有内核模块、所有 boot.img 均无 ramdisk，
   内核 panic 于 `VFS: Unable to mount root fs`。本流水线只复制 ramdisk
   文件并记哈希，**不检验**其中是否有 `/init` 与 fstab；组装出 bundle
   不等于系统能启动。
2. **vbmeta / AVB**：未重签、未处理；修改后的 `system.img` 在校验开启时
   可能无法启动，启动方须自行决定禁用校验等处理（本流水线不做）。
3. **HAL**：图形/音频/传感器等 vendor HAL 均不在本流水线范围内。
4. **SELinux 策略**：QEMU-only 构建的策略未验证。

## 7. priv-app 白名单（含未验证警告）

bundle 内含两份白名单草案，均写入镜像 `/system/etc/permissions/`：

- `privapp-permissions-cn.xinxitong.xml`：只列 `cn.xinxitong.clock` 的
  `android.permission.USE_EXACT_ALARM`。这是 13 个应用实际声明的权限中
  唯一可能属于 `signature|privileged` 的一项；其余权限均不属于该级别，
  故不列入。`MANAGE_EXTERNAL_STORAGE` 与 `SCHEDULE_EXACT_ALARM` 故意不列
  （前者 appop 门控、后者有降级路径）。
- `privapp-permissions-aiagent.xml`：只列 `dev.pocketvm.aiagent` 的
  `android.permission.DUMP`（只读查询用）。`INTERACT_ACROSS_USERS`、
  `WRITE_SECURE_SETTINGS` 明确不列（单用户设计、不申请）；
  `WRITE_SETTINGS` 为 appop 权限，不走白名单。

**警告（两份草案共用，未验证）：**

- 白名单即使放进镜像，对未用平台密钥签名的 APK **不授予任何权限**。
  GSI 为 `release-keys` 用户版构建，Google 不公开其私钥，平台签名无法
  获得；签名证书身份在本机未能核实（无 `apksigner`/Java）。
- `USE_EXACT_ALARM` 的 protectionLevel 未能从镜像核实（`platform.xml`
  未定义该权限级别）；在有 SDK 的机器上用 `aapt2`/`apksigner` 核实确为
  `signature|privileged` 之前，该条目可能无意义，应删除。
- 首次启动后须在 logcat 中核对 `privapp-permissions` 拒绝日志。

## 8. 交接清单：真 APK 到达后只需换 APK 目录重跑

1. 在有 JDK 17 + Android SDK 35 的机器上构建 13 个应用与 Agent，产物按
   `<包名>.apk` 命名放入一个目录（Agent APK 单独以 `--agent-apk` 传入；
   13 个应用的包名见映射表，Agent 包名 `dev.pocketvm.aiagent`）。
2. 恢复 `gradle-wrapper.jar` 问题与本流水线无关：构建方自行处理 wrapper；
   集成只认 APK 文件，不认构建方式。
3. 如 APK 需平台签名/测试密钥签名，在构建方完成并记录签名方式；本流水线
   不签名、不改签名，manifest 的 `real_apks_verified` 恒为 `false`，须由
   构建方在交接时书面确认 APK 真实性与签名。
4. **源码修复回推（必读，2026-10-29 更新）**：WorkBuddy 编译在其副本里做了
   6 个文件的最小源码修复（本机 `~/workspace/system-apps/` 仍是旧源码，
   仍含原始编译错误）。真 APK 集成前，必须先确认这 6 个修复已回推到
   GitHub 仓库（或确认要集成的 APK 就是用修复后源码构建的），否则在
   任何环境重编都会复现同样的编译错误。本流水线只认 APK 文件，不检查
   源码状态，无法替你发现这一问题。另：WorkBuddy 单元测试 68/72 通过，
   4 个失败（计算器×2、备忘录×1据报为错误测试期望，信息×1据报为真实
   过滤 bug）不阻塞集成流水线本身，但应在发布前处理——以上均为
   WorkBuddy 任务的转述结论，本机未核实，APK 也未下载到本机。
4. 重跑第 3 节标准命令（`--grow-mb` 建议先用 512，镜像剩余空间仅约
   67 MiB，真实 APK 几乎必然需要扩容；扩容路径已实测，见测试记录）。
5. 跑 `verify-bootable.sh`，确认 13/13 + Agent 在位且属性一致；再按第 6 节
   清单在首次启动中逐项授予角色并核对 logcat。
6. 不要删除 AOSP 应用，直到第 5 节的删除 bug 修好并重新测试。
7. 启动仍可能失败于 ramdisk / vbmeta / HAL（第 6 节缺口），那是启动方
   的工作，不属于本流水线。

## 9. 未验证事项汇总

- 真实 APK 的构建、签名、安装、角色授予：**全部未验证**（无真实 APK）。
- QEMU 启动：**未尝试**（本流水线不启动 QEMU；此前启动尝试的结论见
  `~/workspace/qemu-boot/BOOT.md`，内核 panic 于无 first-stage ramdisk）。
- `USE_EXACT_ALARM` protectionLevel、签名证书身份、fsverity/AVB 状态：
  **未验证**。
- `--remove-replaced` 删除路径：**已实测为损坏**，已禁用（见第 5 节）。
- `--default-permissions-file` 预授予路径：复用的 `integrate.sh` 支持，
  本流水线未透传、**未测试**；如需使用，须先单独测试。
- `integrate.sh` 的 `apk-map.csv` 文件名映射：本流水线不使用（只认
  `<包名>.apk`），**未测试**。
