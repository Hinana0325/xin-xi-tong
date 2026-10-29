# 测试记录：integrate.sh 假 APK 集成测试（非真实集成）

> 本记录只证明脚本在**假 APK + 副本**上的机械行为（写入、权限、幂等、拒绝）。
> 它**不证明**真实 APK 能安装、角色能授予、系统能启动。真实集成须等 APK
> 构建完成后再按 `INTEGRATION.md` 第 9 节重跑。

## 测试环境

- 日期：2026-10-29（CST）
- 机器：本 VM（x86_64，7.7 GiB RAM，无 loop 设备、无 Java/Android SDK、
  无 `avbtool/apksigner/zipalign/simg2img`）
- 工具：`debugfs/e2fsck/resize2fs/dumpe2fs`（e2fsprogs 1.47.0）、
  `unzip/python3/sha256sum`
- 原始 GSI zip：`~/workspace/gsi/aosp_arm64-exp-DP11.261002.005-16594701-a359a50b.zip`
  （SHA-256 `a359a50b…`，测试前后均未被修改；脚本也拒绝以 zip 为操作对象）
- 假 APK：3 个合法 zip，内含占位文本 `AndroidManifest.xml` 与 9 字节
  `classes.dex`，分别命名 `cn.xinxitong.launcher.apk` /
  `cn.xinxitong.settings.apk` / `cn.xinxitong.files.apk`
  （位于 `/tmp/dummy-apks/`，测试后已删除）。**假 APK 不是应用**，
  仅用于验证写入路径。

## 测试步骤与结果

| # | 步骤 | 结果 |
|---|---|---|
| 1 | `integrate.sh prepare --src-zip <GSI zip> --out-dir work/test-run` | ✅ 成功。写入标记文件，副本 system.img SHA-256 `e771161b…` 与 `work/gsi-copy/` 的 pristine 副本一致，耗时约 60 秒（2 GiB 哈希） |
| 2 | 首次 `integrate.sh integrate --apk-dir /tmp/dummy-apks --system-img-copy work/test-run/system.img`（第一次执行） | ❌ 挂起：`debugfs -w <镜像> <命令文件>` 写法错误，debugfs 等待 stdin，进程空转 >120 秒。已终止，镜像 SHA-256 未变，文件系统干净 |
| 3 | 修复 `dbg_batch` 改为 stdin 传命令；重跑 | ❌ 失败：`unzip -l \| grep -q` 在 `pipefail` 下因 SIGPIPE 返回 141，误报“APK 内无 AndroidManifest.xml”。已修复为先落盘再 grep |
| 4 | 修复后重跑 integrate | ✅ 成功（exit 0）。写入 3 个 APK + 特权白名单草案；集成后 SHA-256 `3b56e0648…`；日志见 `work/test-run-1.log` |
| 5 | 写回校验 | ✅ `debugfs dump` 取回的 launcher APK 与假 APK 的 SHA-256 完全一致；`stat` 显示模式 0644、uid/gid 0、`security.selinux` 上下文已设置 |
| 6 | `integrate.sh verify` | ⚠️ 初版 `img_exists` 误用 debugfs 退出码，13 个路径全报 OK（实际只有 3 个）。已修复为解析 `stat` 输出含 `Inode:` 才算存在；修复后 verify 报 `placed: 3, missing: 10`，exit 1——**正确** |
| 7 | 二次 integrate（幂等） | ✅ exit 0；3 个已写入项均报“已存在且内容相同”而跳过，白名单同样跳过；第二次运行的清单 before/after SHA-256 相同（无写入）。日志见 `work/test-run-2.log` |
| 8 | 空 APK 目录拒绝 | ✅ exit 1，错误信息列出全部 13 个缺失包名，并说明需先构建、脚本不伪造 APK |
| 9 | 无标记副本拒绝 | ✅ 复制一份镜像但不带 `.integration-copy-marker`，exit 1，拒绝操作 |
| 10 | 原始 zip 拒绝 | ✅ 以 GSI zip 为 `--system-img-copy`，exit 1，拒绝操作 |

## 测试中发现并修复的脚本 bug（均已修复，见上表）

1. `dbg_batch` 的 debugfs 调用方式错误（命令文件不能作位置参数）→ 改为
   stdin 重定向。
2. APK 校验管道在 `pipefail` 下因 SIGPIPE 误报 → 改为 `unzip -l` 落盘后 grep。
3. `img_exists` 误判（debugfs `stat` 对不存在路径也返回 0）→ 解析输出
   是否含 `Inode:`。

## 未测试的路径（首次真实集成前必须补测）

- `--grow-mb` 扩容路径（测试时剩余空间 67 MiB 足够 3 个小假 APK，未触发）；
- `--remove-replaced` 删除 AOSP 应用路径；
- `--default-permissions-file` 可选预授权文件写入；
- 13 个真实 APK 全量集成；
- 首次启动验证（角色授予、SELinux 上下文、AVB/fsverity）——属 QEMU 启动方。

## 清理

- 测试副本 `work/test-run/`（2 GiB，已修改的镜像）已删除；日志
  `work/test-run-1.log`、`work/test-run-2.log` 保留。
- `/tmp/dummy-apks/`、`/tmp/empty-apks/`、取回的 APK 副本已删除。
- `work/gsi-copy/` 的 pristine 副本（system.img SHA-256 `e771161b…`）**保留**，
  作为回滚基准；请勿删除。
