# 测试记录：可启动镜像集成流水线（假 APK 测试，非真实集成）

> **本记录只证明流水线在假 APK + 副本上的机械行为**（写入、扩容、拒绝、
> 校验、内容幂等）。它**不证明**真实 APK 能安装、角色能授予、系统能启动。
> 假 APK 是合法 zip + 占位 `AndroidManifest.xml`（生成器见
> `work-test/make-dummy-apks.py`），**不是应用**。真实集成须等真实 APK
> 到达后换 APK 目录重跑（见 `INTEGRATION-BOOTABLE.md` 第 8 节）。

## 测试环境

- 日期：2026-10-29（CST 12:32–12:42；日志 UTC 04:32–04:42）
- 机器：本 VM（x86_64，2 vCPU，7.7 GiB RAM，无 loop 设备、无 Java/Android SDK、
  无 `avbtool/apksigner/zipalign/simg2img`）
- 工具：`debugfs/e2fsck/resize2fs/dumpe2fs/qemu-img/mkfs.ext4/unzip/python3`
  （e2fsprogs 1.47.0）
- 输入副本：从 GSI zip（SHA-256 `a359a50b…`，测试前后均未被修改）解出
  `system.img` 到 `work-test/input/`，SHA-256 `e771161b…`，2,114,777,088 字节，
  剩余空间 67,198,976 字节（`dumpe2fs` 实测）。内核/ramdisk/boot 均取自
  `~/workspace/qemu-boot/` 的只读副本（仅复制进 bundle，不检验内容）。
- 假 APK：13 个小假 APK（各约 359 字节）+ 1 个假 Agent APK
  （`dev.pocketvm.aiagent.apk`，359 字节），见 `work-test/apks-small/`。

## 测试步骤与结果

| # | 步骤 | 结果 |
|---|---|---|
| A1 | 流水线主流程：13 个小假 APK + 假 Agent APK + 内核/ramdisk/boot.img，`--label dummy-test`，输出 `bundle-sample/` | ✅ 成功（exit 0）。`integrate.sh` 写入 13/13，白名单写入，Agent APK 与 Agent 白名单写入；集成前 SHA `e771161b…`，`integrate.sh` 步骤后 `579aaa19…`，Agent 写入后 `644b5d16…` |
| A2 | `verify-bootable.sh --bundle-dir bundle-sample` | ✅ PASS（exit 0）。manifest 13 个文件 SHA/大小一致；`e2fsck -fn` 通过；13/13 应用 + Agent 在位，模式 0644、`root:root`、上下文含 `system_file`；警告 17 条（1 条 dummy-test 标签 + 16 条 SELinux 上下文 25 字节，见下） |
| A3 | 幂等复跑：同一输入、同一 APK 目录、`--force` 重建 `bundle-sample`，再校验 | ⚠️ **内容幂等、字节不幂等**：重跑后镜像 SHA 变为 `8b17c9ba…`（与首次 `644b5d16…` 不同），但镜像内 14 个 APK/白名单文件的 SHA-256 逐一比对**全部相同**，校验再次 PASS。结论：debugfs 写入带时间戳元数据，ext4 镜像不保证字节级可复现；不要用镜像 SHA 判断两次集成是否相同，应以校验结果与镜像内文件 SHA 为准。`INTEGRATION-BOOTABLE.md` 已按此修正 |
| B1 | 扩容路径：3 个大假 APK（各约 31,461,041 字节，ZIP_STORED 随机填充，APK 文件本身够大）+ 10 个小假 APK，`--grow-mb 64` | ✅ 成功。空间检查：剩余 67,198,976 字节 < 需要 130,041,280 字节，触发扩容 +64 MiB，扩容后剩余 167,649,280 字节；最终镜像 2,181,885,952 字节，恰好比输入大 67,108,864 字节（64 MiB）；校验 PASS（13/13）。扩容 bundle 已删，manifest 证据保留在 `work-test/logs/bundle-grow-manifest.json` |
| C1 | 删除路径：13 个小假 APK + `--remove-replaced` | ❌ **失败，已实测为损坏**：8 个 AOSP UI 目录文件被删后，`e2fsck -fn` 未通过，`Block bitmap differences: +(85379--85385) +340187`；流水线中止，未产出 bundle，输入副本未受影响（SHA 仍为 `e771161b…`），损坏的工作区镜像已删除。根因：复用脚本的 debugfs `rm` 未同步块位图 |
| C2 | 处置：流水线前置拒绝 `--remove-replaced` 后重测 | ✅ 拒绝成功（exit 1，复制任何文件之前失败，未创建 bundle 目录），日志见 `work-test/logs/test-d4-remove-refused.log` |
| D1 | 空 APK 目录 | ✅ 拒绝（exit 1），列出全部 13 个缺失包名，未创建 bundle |
| D2 | 缺 1 个 APK（删 `cn.xinxitong.notes.apk`） | ✅ 拒绝（exit 1），只列缺失的 `cn.xinxitong.notes` |
| D3 | 以 GSI zip 作为 `--system-img-copy` | ✅ 拒绝（exit 1） |
| D4 | 见 C2 | — |

## SELinux 上下文 25 字节警告（全部写入文件均有）

`verify-bootable.sh` 对每个写入文件发出警告：`debugfs ea_set` 写入的
`security.selinux` 值为 25 字节（无结尾 NUL），而原镜像文件为 26 字节
（含 NUL）。上下文字符串本身为 `u:object_r:system_file:s0`，校验按字符串
通过。首次启动后必须用 `ls -Z` 复核写入文件是否被正确标记；如标记失败，
改用 `e2fsdroid` + `fs_config` 重建镜像（未验证）。

## 输入原件未改动核查（测试后复核）

- GSI 原始 zip SHA-256 仍为 `a359a50b…`（与公布值一致）。
- `~/workspace/qemu-system-integration/integrate.sh` SHA-256 仍为
  `5e6be3da…32c6c`，与本目录副本一致；映射表 SHA 仍为 `a29c6838…aa8b`。
- `~/workspace/xin-xi-tong` 仍为 24 个未提交改动（与任务开始前一致）；
  `~/workspace/system-apps` 仍为 162 个文件；内核 `Image` 未改动
  （2026-10-28 构建产物）。
- 本目录外唯一写出：`work-test/input/` 的 GSI 副本（测试输入）与
  `bundle-sample/` 样例 bundle。

## 未测试的路径

- 真实 APK 全量集成、真实 Agent APK 集成、签名/平台签名核实。
- `--default-permissions-file` 预授予、`apk-map.csv` 文件名映射（流水线不使用）。
- QEMU 启动（本流水线不启动 QEMU；此前启动尝试见 `~/workspace/qemu-boot/BOOT.md`）。
- 默认角色授予、logcat 白名单核对、首次启动 `ls -Z` 核对（均需启动后实测）。

## 样例 bundle（假 APK，标注 dummy-test）

`bundle-sample/`（2.1G，第二次复跑产物，镜像 SHA `8b17c9ba…`）：
`system.img`、`kernel-Image`、`ramdisk.img`、`boot.img`、`vbmeta.img`、
`build.prop`、`userdata.qcow2`、`metadata.img`、`manifest.json`、
`system-integration.json`、映射表、两份白名单草案、`verify-bootable.sh`。
**切勿把此样例当作真实系统镜像使用或发布。**

## 2026-10-29 更新：WorkBuddy 编译完成（转述，未在本机核实）

据父任务转述，WorkBuddy 克隆编译任务于 2026-10-29 12:43 CST 完成：
13/13 模块成功，13 个 debug APK（各约 54–57 MB）**只在 WorkBuddy 环境里，
未下载到本机**；单元测试 68/72 通过，4 个失败（计算器×2、备忘录×1据报为
错误测试期望，信息×1据报为真实过滤 bug）；WorkBuddy 副本里有 6 个文件的
最小源码修复，**未回推**到本机 `~/workspace/system-apps/` 与 GitHub。
本测试记录的作者**未访问 WorkBuddy、未核实上述结论、未见到任何真实 APK**。
真 APK 集成前必须先确认 6 个修复已回推（见 `INTEGRATION-BOOTABLE.md`
第 8 节第 4 条），否则重编会复现编译错误；4 个测试失败不阻塞本流水线
本身。真 APK 到达本机后，本流水线只需换 `--apk-dir` 重跑，无需改动脚本。
