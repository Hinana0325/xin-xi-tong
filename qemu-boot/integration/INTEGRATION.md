# 系统镜像集成方案：把自研应用放进 GSI system.img（仅 QEMU virt 测试）

> 范围：**仅 QEMU `virt` 测试**。不涉及真机固件、vendor blob、fastboot/刷机、
> 设备专属签名与设备 HAL。本方案不启动 QEMU（启动由另一位 agent 负责），
> 不修改 `~/workspace/system-apps`、`~/workspace/kernel-android17-6.18`、
> `~/workspace/gsi/*.zip`、`~/workspace/xin-xi-tong`、`~/workspace/PocketVM`。
> 所有操作只针对**副本**；原始 GSI zip 及其 SHA-256 保持不变。

## 0. 已核实的事实（本机实测，不是推测）

| 项目 | 核实结果 | 核实方式 |
|---|---|---|
| GSI | Android 17 QPR3 Beta，`DP11.261002.005`，build `16594701`，`user/release-keys`，SDK 37 | 解出 zip 内 `build.prop` 全文 |
| GSI zip SHA-256 | `a359a50b6eb8e9f63168e928bd14167603225e92cd8605ec86a4bda6591fc13b` | `sha256sum`（与 Google 公布值一致） |
| `system.img` | **原始 ext4**（非 sparse、无需 `simg2img`），2,114,777,088 字节，块大小 4096，共 508,136 块 | `file` / `dumpe2fs -h`；首部无 sparse 魔数 |
| `system.img` SHA-256（副本） | `e771161b08b7d62614bc067b17861587532ae94de79b85a0e9a0afa381b07b85` | `sha256sum`（副本，见 `work/gsi-copy/`） |
| 镜像内布局 | 应用在 `/system/app`、`/system/priv-app`、`/system/system_ext/{app,priv-app}`、`/system/product/{app,priv-app}`；`build.prop` 在 `/system/build.prop`；权限文件在 `/system/etc/permissions/` | `debugfs` 列目录（本机无 loop 设备，无法 mount，见第 2 节） |
| AOSP 应用清单 | 全部 107 个 APK 的包名均已提取（见 `work/aosp-packages.csv`） | 自写 AXML 字符串池解析器解析各 APK 的 `AndroidManifest.xml` |
| 镜像剩余空间 | **仅约 67 MiB**（16,406 空闲块 × 4096） | `dumpe2fs`；13 个 APK 大概率超此空间，**必须先扩容**（第 6 节） |
| 签名形式 | 抽查 Settings/Dialer/Calendar 共 3 个 APK：`META-INF/` 内**无** `.SF/.RSA/.DSA/.EC`（无 v1 签名），即仅 v2/v3 签名块 | `unzip -l` |
| 签名证书身份 | **未能核实**（本机无 `apksigner`/Java，无法读签名块证书） | 见第 5 节：必须在有 SDK 的机器上核实 |
| 特权白名单现状 | `/system/etc/permissions/privapp-permissions-platform.xml` 已存在（80 个 `<privapp-permissions>` 条目）；`default-permissions/` 仅有 bips 与打印服务两个示例 | 从镜像 `debugfs rdump` 提取后阅读 |
| 默认角色配置 | 镜像内**无**静态角色配置文件；角色在首次启动后运行时授予（第 7 节） | 检索镜像 `etc/` 树（`role`/`preferred` 均无相关静态配置） |
| 自研应用 | 13 个模块，包名 `cn.xinxitong.*`，版本 Kotlin 2.1.0 / AGP 8.7.3 / Compose BOM 2024.10.01 / compileSdk 35；**尚无 APK**（本机无 JDK/SDK，未构建） | 逐一阅读各模块 `build.gradle.kts` 与 `AndroidManifest.xml` |
| 可用工具 | `debugfs/e2fsck/resize2fs/dumpe2fs/openssl/zip/unzip/python3` 存在；`simg2img/avbtool/apksigner/zipalign/q
emu-system-aarch64/java` **不存在** | `which` |

## 1. 总体流程（只在副本上操作）

```
GSI zip（只读，永不修改）
  └─ integrate.sh prepare ──> work/gsi-copy/（system.img + vbmeta.img + build.prop + .integration-copy-marker）
        │  记录 pristine sha256（回滚基准）
        └─ integrate.sh integrate --apk-dir <APK 目录> --system-img-copy work/gsi-copy/system.img [--grow-mb N]
              │  扩容 → debugfs 写入 APK → 写特权白名单草案 → e2fsck 复查 → 生成 .integration.json 清单
              └─ 产物：修改后的 system.img 副本（交 QEMU 启动方；vbmeta 处理见第 8 节）
```

回滚：删除修改后的副本，重新 `prepare`（或从 `work/gsi-copy/` 的 pristine
副本重新复制）。`integrate.sh` 每次运行都记录集成前/后 sha256，清单文件为
`<镜像路径>.integration.json`。

## 2. 解包 system.img 副本

system.img 是原始 ext4，**不需要** `simg2img`。两种打开方式：

**A. 有 loop 设备的机器（推荐，常规做法）**

```bash
sudo mount -o loop,ro system.img /mnt/system   # 只读查看
sudo mount -o loop,rw system.img /mnt/system   # 写入（需先扩容，见第 6 节）
```

本机实测：`/dev/loop*` 不存在，mount 失败，因此下面用 B 方式核实。

**B. 无 loop 设备的机器（本机实测可用）：`debugfs` 只读查看**

```bash
debugfs -R "ls -l /system/app" system.img
debugfs -R "ls -l /system/priv-app" system.img
dumpe2fs -h system.img            # 看块大小、空闲块
e2fsck -fn system.img             # 只读检查，写入前必须通过
```

`integrate.sh` 的写入同样走 `debugfs -w`（`write`/`mkdir`/`sif`/`ea_set`），
并在写入后用 `e2fsck -fn` 复查。注意 `debugfs` 写入不经过 SELinux/verity，
文件上下文需手动设（第 4 节末）。

**没有这些工具的机器**：需安装 `e2fsprogs`（提供 debugfs/e2fsck/resize2fs/
dumpe2fs）与 Android SDK `build-tools`（提供 `apksigner`/`zipalign`/`aapt2`）；
`simg2img` 属于 `android-sdk-libsparse`，本镜像不需要，但装上无害。

## 3. 每个应用放哪里（与 replacement-mapping.csv 一致）

原则：**镜像 AOSP 同类应用放在哪个分区目录，自研应用就放在对应的同级目录**，
这样 PackageManager 的扫描分区与特权判定行为与 AOSP 一致。`core-ui` 是库，
无 APK，不参与集成。

| 自研应用（包名） | 镜像内目标路径 | 分区 | 原因 |
|---|---|---|---|
| 启动器 `cn.xinxitong.launcher` | `/system/system_ext/priv-app/XinXiTongLauncher/` | system_ext priv-app | 与 Launcher3QuickStep 同级 |
| 设置 `cn.xinxitong.settings` | `/system/system_ext/priv-app/XinXiTongSettings/` | system_ext priv-app | 与 AOSP Settings 同级 |
| 文件管理 `cn.xinxitong.files` | `/system/priv-app/XinXiTongFiles/` | system priv-app | 与 DocumentsUI 同级 |
| 电话 `cn.xinxitong.phone` | `/system/product/priv-app/XinXiTongPhone/` | product priv-app | 与 Dialer 同级，拨号角色候选 |
| 联系人 `cn.xinxitong.contacts` | `/system/product/priv-app/XinXiTongContacts/` | product priv-app | 与 Contacts 同级 |
| 信息 `cn.xinxitong.messages` | `/system/product/priv-app/XinXiTongMessages/` | product priv-app | 短信角色候选 |
| 相机 `cn.xinxitong.camera` | `/system/product/app/XinXiTongCamera/` | product app | 与 Camera2 同级 |
| 相册 `cn.xinxitong.gallery` | `/system/product/app/XinXiTongGallery/` | product app | 与 Gallery2 同级 |
| 浏览器 `cn.xinxitong.browser` | `/system/product/app/XinXiTongBrowser/` | product app | 新增；WebView 引擎保留（见下） |
| 时钟 `cn.xinxitong.clock` | `/system/product/app/XinXiTongClock/` | product app | 与 DeskClock 同级 |
| 计算器 `cn.xinxitong.calculator` | `/system/product/app/XinXiTongCalculator/` | product app | 新增，无对应物 |
| 日历 `cn.xinxitong.calendar` | `/system/product/app/XinXiTongCalendar/` | product app | 与 Calendar 同级 |
| 备忘录 `cn.xinxitong.notes` | `/system/product/app/XinXiTongNotes/` | product app | 新增，无对应物 |

目录内约定（AOSP 惯例）：目录名与 APK 文件名相同，如
`XinXiTongLauncher/XinXiTongLauncher.apk`，权限 `0644`，属主 `root:root`，
SELinux 上下文 `u:object_r:system_file:s0`（与镜像内 `build.prop` 的上下文一致，
由 `integrate.sh` 用 `ea_set` 设置）。

> 已知细节：`debugfs ea_set` 写入的 `security.selinux` 值为 25 字节（无结尾
> NUL），而镜像原有文件为 26 字节（含 NUL）。首次启动后必须用 `ls -Z` 核对
> 写入文件是否被正确标记为 `system_file`；如标记失败，改用 Android 构建工具
> 的 `e2fsdroid` + `fs_config` 方式重建镜像（未验证）。

## 4. 删除 / 保留哪些 AOSP 应用

**默认策略：只添加，不删除。** 自研应用与 AOSP 应用包名不同，可以共存；
默认角色在首次启动后选择（第 7 节）。`integrate.sh` 默认不删任何东西，
只有显式加 `--remove-replaced` 才删除下表 `REMOVE-OPTIONAL` 的 UI 应用。

完整映射见 `replacement-mapping.csv`（每行均已用本 GSI 镜像的 AXML 解析结果核实，
状态为 VERIFIED / VERIFIED-ABSENT）。关键保留项（删了会坏事）：

| 必须保留 | 原因 |
|---|---|
| AOSP Settings（`com.android.settings`） | 自研设置通过 intent 跳转的 Wi-Fi/蓝牙等面板由它提供 |
| DocumentsUI（`com.android.documentsui`） | 系统文件选择器/SAF 实现，其他应用依赖 |
| TeleService（`com.android.phone`）、TelecomShim（`com.android.server.telecom`） | 通话框架；Dialer 只是 UI |
| ContactsProvider、CalendarProvider、TelephonyProvider、MmsService | 联系人/日历/电话/短信的数据层 |
| WebView 引擎（`com.android.webview`）与 `org.chromium.webview_shell` | 自研浏览器是 WebView 外壳，依赖引擎；核实发现 `Browser2.apk` 的包名就是 webview_shell，**不是**独立浏览器 |
| NotesRoleEnabled overlay | 仅启用笔记角色，无笔记应用；保留 |

可选项（仅 `--remove-replaced`）：Launcher3QuickStep、Dialer、Contacts、
messaging、Camera2、Gallery2、DeskClock、Calendar 的 UI 目录。删除是可逆的
（清单记录删除项，重新 `prepare` 即可恢复），但删除 Launcher3QuickStep 后需
验证 QuickStep 手势/SystemUI 是否受影响——**未验证**，首次启动必查。

## 5. 签名：平台密钥 / 测试密钥

### 5.1 现状（已核实 + 未核实，分开说）

- 已核实：`build.prop` 指纹为 `release-keys`、构建类型 `user`、
  `ro.secure=1`、`ro.debuggable=0`。抽查的 3 个 AOSP APK 只有 v2/v3
  签名块，无 v1 签名文件。
- **未能核实**：签名证书的身份与指纹。本机无 `apksigner`/Java，无法解析
  签名块。在有 SDK 的机器上核实：

```bash
apksigner verify --print-certs --verbose /path/to/Settings.apk
apksigner verify --print-certs --verbose /path/to/<自研>.apk
# 对比证书 SHA-256 指纹：AOSP 各应用应共享同一平台证书
```

### 5.2 对集成的实际影响

1. **新包名 + 不同签名 = 可以安装。** 13 个自研应用包名全新，不存在
   “同包名不同签名无法更新”（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`）的问题。
   以普通/危险权限为主的应用，即使 debug 签名，放在 `priv-app`/`app` 也能
   被 PackageManager 扫描安装。
2. **signature|privileged 权限拿不到。** 白名单文件（第 4 节的草案）只有在
   APK 与平台同密钥签名时才生效。Google **不公开** GSI release-keys 的私钥，
   因此仅靠重签 APK 无法获得平台签名；要真正获得平台签名，需要从 AOSP
   源码用自己的平台密钥重建整个 system 镜像（超出本任务范围，QEMU 测试
   不必走这条路）。
3. **后果已在应用内规避**：13 个应用的 Manifest 均未声明必须平台签名的
   权限；时钟的精确闹钟已有 `SCHEDULE_EXACT_ALARM` 降级路径；文件管理的
   `MANAGE_EXTERNAL_STORAGE` 走用户在设置里的“所有文件访问权限”授予，
   不依赖白名单。

### 5.3 自研 APK 的签名做法（构建机上）

13 个 APK 用**同一把**密钥签名（便于日后统一更新），先 `zipalign` 再签名，
同时启用 v2 + v3：

```bash
# 1. 生成一把测试密钥（仅 QEMU 测试用，妥善保管，不要用于发布）
keytool -genkeypair -keystore xinxitong-test.jks -alias xinxitong \
  -keyalg RSA -keysize 2048 -validity 3650
# 2. 对每个 APK：对齐 → 签名 → 校验
zipalign -f 4 app-launcher-debug.apk app-launcher-aligned.apk
apksigner sign --ks xinxitong-test.jks --out cn.xinxitong.launcher.apk app-launcher-aligned.apk
apksigner verify --print-certs cn.xinxitong.launcher.apk
```

APK 文件名规范：`integrate.sh` 默认按 `<包名>.apk` 识别（如
`cn.xinxitong.launcher.apk`）；如文件名不同，在 APK 目录中放 `apk-map.csv`
（`package,filename` 两列，见脚本内说明）。**脚本不伪造 APK**：APK 目录
为空时直接失败并列出缺失的 13 个包名。

签名不匹配时会发生什么（首次启动核对清单）：logcat 出现
`privapp-permissions` 拒绝记录；同包名更新失败；`sharedUserId` 不一致
导致安装失败——本批应用均未使用 `sharedUserId`，无此问题。

## 6. 重建、扩容与特权白名单

### 6.1 扩容（必须）

镜像剩余空间仅约 67 MiB，13 个 Compose APK 几乎必然超出。`integrate.sh`
会在写入前计算所需空间（APK 总和 + 20% + 16 MiB 余量），不足时：

```bash
# 手动等价命令（脚本自动做，加 --grow-mb N 时）：
truncate -s +512M system.img
e2fsck -fy system.img
resize2fs system.img
```

建议一次加 512 MiB。扩容后镜像文件变大，QEMU 侧按新文件大小使用即可
（启动参数由 QEMU 启动方决定；system.img 为原始 ext4，直接作 virtio 磁盘）。

### 6.2 特权白名单草案

文件：`privapp-permissions-cn.xinxitong.xml`（本目录），目标路径
`/system/etc/permissions/privapp-permissions-cn.xinxitong.xml`，由
`integrate.sh` 默认写入（`--no-privapp-allowlist` 可跳过）。

内容**只有一条**（其余 12 个应用声明的权限均不属于 signature|privileged，
故意不列）：

```xml
<privapp-permissions package="cn.xinxitong.clock">
    <permission name="android.permission.USE_EXACT_ALARM"/>
</privapp-permissions>
```

限制（见文件头注释）：`USE_EXACT_ALARM` 的 protectionLevel 未能从本镜像
核实，须先用 `aapt2` 核实确为 signature|privileged；且未用平台密钥签名
时本条目不授予任何权限，仅作未来平台签名构建的草案。

### 6.3 默认权限预授予（可选，默认不做）

`/system/etc/default-permissions/default-permissions-*.xml` 可在首次启动前
预授予运行时权限（格式示例见 `work/default-permissions-example.xml`，为镜像
内 bips 的原文件）。本方案**默认不预授予危险权限**（用户应在首次启动后在
设置里逐项授予，符合测试真实行为）；仅 QEMU 冒烟测试需要时，用
`--default-permissions-file <文件>` 显式传入自写文件，内容自拟、责任自负。

## 7. Overlay 与默认角色配置

### 7.1 Overlay：不需要新增

镜像已有 `gsi_overlay_framework` / `gsi_overlay_systemui` 两个 overlay
（`/system/system_ext/overlay/`）。自研应用的默认角色与主题**不需要**新增
RRO overlay APK；新增 overlay 需要 overlay 清单与 `config_overlays` 配置，
未验证，不在本方案内。灰白主题由各应用自身的 `core-ui` 主题实现，与
SystemUI overlay 无关。

### 7.2 默认角色：首次启动后运行时授予（未验证，需启动后核对）

角色不在镜像静态文件中配置。首次启动进入系统后，按以下顺序处理：

| 角色 | 目标应用 | 授予方式（首选 → 备选） |
|---|---|---|
| HOME（启动器） | `cn.xinxitong.launcher` | 按 Home 键 → 系统选择器选“启动器”并选“始终”；或设置 → 应用 → 默认应用 → 主屏幕应用 |
| ROLE_DIALER（电话） | `cn.xinxitong.phone` | 设置 → 应用 → 默认应用 → 电话应用 |
| ROLE_SMS（短信） | `cn.xinxitong.messages` | 设置 → 应用 → 默认应用 → 短信应用（授予后才有完整短信行为） |
| ROLE_BROWSER（浏览器） | `cn.xinxitong.browser` | 设置 → 应用 → 默认应用 → 浏览器应用 |
| 相册 | `cn.xinxitong.gallery` | 无角色；通过 intent 选择器/“默认打开方式”由用户选择 |
| 笔记角色 | `cn.xinxitong.notes` | **已知缺口**：overlay 已启用笔记角色，但备忘录 Manifest 未声明笔记角色 intent（如 `ACTION_CREATE_NOTE`），目前无法成为笔记角色持有者；如需该角色，需先给备忘录加 intent-filter 再集成 |

`adb shell cmd role add-role-holder ...` 命令在 `user/release-keys` 构建上
是否可用**未验证**（`ro.secure=1`、`ro.debuggable=0`，adb shell 非 root），
因此不作为首选；以系统设置 UI 为准，启动后逐项核对。

## 8. vbmeta / AVB 处理（QEMU 启动方负责，本方案不做）

修改后的 system.img 与原始哈希不一致，AVB 校验必然失败，除非启动路径
禁用校验或重签 vbmeta。本方案**不生成、不修改 vbmeta.img**（副本中的
`vbmeta.img` 保持原样，仅作参照），原因：

- `avbtool` 本机不存在，无法重签；
- vbmeta 策略（空 vbmeta、禁用校验、重签）与内核命令行、boot.img 组装
  强相关，属于 QEMU 启动方的职责范围；
- 错误的 vbmeta 处理会导致启动失败，与集成脚本无关，需在启动侧验证。

启动前，QEMU 启动方须确认：vbmeta 已禁用或已按修改后镜像重签，且
fsverity（如对 system 分区启用）不会因镜像修改而拒绝挂载——镜像内存在
`etc/security/fsverity/BuildManifest.apk`，fsverity 的实际启用状态**未验证**，
首次启动是唯一的验证手段。如启动失败且日志指向 verity/AVB，先排查此处，
再排查集成内容。

## 9. 完整操作命令（APK 就绪后）

```bash
cd ~/workspace/qemu-system-integration

# 1. 解出副本（只做一次；重复执行会覆盖副本，集成需重做）
./integrate.sh prepare \
  --src-zip ~/workspace/gsi/aosp_arm64-exp-DP11.261002.005-16594701-a359a50b.zip \
  --out-dir work/gsi-copy

# 2. 集成（APK 按 <包名>.apk 命名，见第 5.3 节；空间不足时加 --grow-mb 512）
./integrate.sh integrate \
  --apk-dir /path/to/apks \
  --system-img-copy work/gsi-copy/system.img \
  --grow-mb 512

# 3. 校验（列出 13 个目标路径是否全部存在；缺失则 exit 1）
./integrate.sh verify --system-img-copy work/gsi-copy/system.img

# 4. 可选：删除被替换的 AOSP UI 应用（默认不删；见第 4 节）
./integrate.sh integrate \
  --apk-dir /path/to/apks \
  --system-img-copy work/gsi-copy/system.img \
  --remove-replaced

# 5. 首次启动后核对（QEMU 启动方 / 手工）：
#    - 13 个应用均出现在启动器中且可打开；
#    - 默认角色按第 7.2 节逐项授予并生效；
#    - logcat 无 privapp-permissions 拒绝（时钟除外：未平台签名时预期无授予，
#      但应用应走 SCHEDULE_EXACT_ALARM 降级路径正常工作）；
#    - ls -Z 核对写入文件的 SELinux 上下文为 u:object_r:system_file:s0。
```

## 10. 已知缺口与未验证项（汇总）

1. **无 APK**：13 个应用均未构建，`integrate.sh` 从未对真实 APK 运行过；
   仅用 3 个假 APK（合法 zip + 占位 `AndroidManifest.xml`）做过写入测试
   （见 `TEST-RECORD.md`，含测试中发现并修复的两个脚本 bug）。
2. AOSP 包名映射：**已验证**（107 个 APK 全部解析）；但各 AOSP 应用的
   intent-filter/角色声明未逐一解析——默认角色授予以首次启动实测为准。
3. 签名证书身份：**未核实**（无 apksigner）；平台签名路径为已知 blocker，
   见第 5 节。
4. 扩容：`--grow-mb` 路径（truncate + e2fsck + resize2fs）**未实际测试**
   （测试时剩余空间足够）；首次真实集成时需核对扩容后 `e2fsck -fn` 通过。
5. `--remove-replaced` 删除路径：**未实际测试**（测试仅覆盖默认添加模式）；
   首次使用前应在测试副本上先跑一次并用 `verify` + `e2fsck` 核对。
6. SELinux 上下文 NUL 字节差异：见第 3 节末，首次启动用 `ls -Z` 核对。
7. fsverity / AVB：见第 8 节，首次启动验证。
8. 备忘录笔记角色：Manifest 缺 intent-filter，见第 7.2 节。
9. 本方案假设 system.img 以原始 ext4 直接作 QEMU 磁盘；如启动方改用
   sparse/动态分区（super.img）组装，集成目标路径与扩容方式需重新评估。
