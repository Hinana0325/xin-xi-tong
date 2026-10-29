# 内核构建记录：android17-6.18 通用内核（QEMU virt 专用）

本文件记录 `~/workspace/kernel-android17-6.18`（44 GB）中通用 Android 17 内核的
构建方式与验证结果，目的是让人不下载整棵源码树也能复现出同一个内核。
源码本身不在 GitHub 上：它是 Google 的 AOSP 内核源码，公开可拉取；
本仓库只记录版本钉选、本地改动、配置与构建命令。

目标：QEMU `virt` / cortex-a57，配 Android 17 QPR3 Beta GSI（DP11.261002.005）。
仅 QEMU 用，不保留 GKI/KMI 纯洁性，不针对真机。

## 版本钉选（已核验）

- 发布：`android17-6.18-2026-06_r68`（2026-10-20）
- Manifest 分支（`.repo/manifests/default.xml`）：superproject
  `revision="common-android17-6.18-2026-06"`；`common` 项目
  `revision="android17-6.18-2026-06"`
- `common/` HEAD：`edb80646c73dd6eb2ef3549f335d513916e8a70d`
- 构建方式：Kleaf/Bazel（仓库内无 legacy `build/build.sh`，`LTO=thin` 不适用）
- 工具链（取自 Image 内嵌版本字符串）：clang 22.0.1、LLD 22.0.1（Kleaf 自带）
- 页大小：4K；版本字符串：
  `Linux version 6.18.21-android17-5-maybe-dirty-4k`
  （`maybe-dirty` 仅来自下文两处本地补丁）

同步（manifest 分支见上，历史命令行未逐字保留）：

```bash
repo init -u https://android.googlesource.com/kernel/manifest -b common-android17-6.18-2026-06
repo sync
```

## 本地改动：仅两行（已核验，`build/kernel` 仓库内唯一 dirty 内容）

起因：本机文件系统的 toybox `cp -p` 会因 fchown 失败（EPERM），构建因此中断。
改动只去掉 `-p`，不改任何行为；`common/` 干净。

```diff
--- a/kleaf/impl/kernel_env.bzl
+++ b/kleaf/impl/kernel_env.bzl
@@ -368,7 +368,7 @@
-          cp -p {config_tags_comment_file} {out}
+          cp {config_tags_comment_file} {out}  # LOCAL WORKAROUND: toybox cp -p fchown fails EPERM on this FS

--- a/kleaf/impl/kernel_module.bzl
+++ b/kleaf/impl/kernel_module.bzl
@@ -527,7 +527,7 @@
-            cp -L -p {modules_staging_dir}/lib/modules/*/extra/{ext_mod}/modules.order.* {modules_order}
+            cp -L {modules_staging_dir}/lib/modules/*/extra/{ext_mod}/modules.order.* {modules_order}  # LOCAL WORKAROUND: toybox cp -p fchown fails EPERM on this FS
```

## 配置：gki_defconfig + QEMU virt fragment

`qemu-virt/qemu-virt.fragment`（全文引用，Bazel 目标 `//qemu-virt:qemu_virt_fragment`）：

```
# QEMU virt fragment for android17-6.18 (QEMU-only, NOT a GKI build)
# Applied on top of gki_defconfig via Kleaf.
# Purpose: boot the Android 17 QPR3 Beta GSI system.img in QEMU
# "virt" (arm64) with a plain `-kernel Image` invocation, i.e. with no
# initramfs-supplied modules. The virtio drivers that GKI builds as
# modules (=m) therefore have to be built in (=y), otherwise the
# kernel cannot find its root disk / console / network before any
# module could be loaded.
# Sources: gki_defconfig values (=m) promoted to =y, plus the
# upstream virtual-device fragments
# (common-modules/virtual-device/virtual_device_core.fragment and
# aarch64.fragment), also promoted to =y. KMI/GKI purity is
# intentionally NOT preserved here; this kernel is for QEMU only.
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_VIRTIO_INPUT=y
CONFIG_VIRTIO_BALLOON=y
CONFIG_HW_RANDOM_VIRTIO=y
# virtio-gpu display (SurfaceFlinger talks DRM directly; no fbcon needed)
CONFIG_DRM_VIRTIO_GPU=y
```

构建命令（fragment 文件头原文）：

```bash
tools/bazel run //common:kernel_aarch64_dist \
    --defconfig_fragment=//qemu-virt:qemu_virt_fragment \
    -- --destdir=<dist dir>
```

另两个 dist 用同一 Kleaf 目标、不同 defconfig 组合构建（plain GKI 仅
`gki_defconfig`；virtual-device 用上游 virtual-device fragment，virtio 为 `=m`）；
其逐字命令行未保留，以上命令加 fragment 定义为准。

## 构建产物（已核验，2026-10-29）

三个 dist 均为 ARM64、4K 页、`6.18.21-android17-5-maybe-dirty-4k`：

| dist | Image 大小 | Image SHA-256 | 说明 |
|---|---|---|---|
| `out/dist-plain-gki`（787 MB） | 43,203,072 B | `64aff3d4ea7b2a3b1a16dfad706f89a72ff11d426a460ad9454f3212876416a2` | 纯 GKI，含 `boot.img` |
| `out/dist-qemu-virt`（347 MB） | 44,329,472 B | `578080b9ba3d56a21219142f7fad161f7f663d95809491899fd2da182e9aa278` | virtio 全 `=y`；`.config` 已验 `VIRTIO_BLK/NET/CONSOLE/INPUT/MMIO/PCI=y`、`SERIAL_AMBA_PL011=y`；手动组装，无 `boot.img`（Kleaf 打包失败，因 GKI 模块清单仍要求这些驱动为 `.ko`） |
| `out/dist-virtual-device`（629 MB） | 43,989,504 B | `2fbfb8a681a93a52f88201fbf26e12cc8604ca7b1d31c154f6898c5843533071` | virtio 为 `=m`，含 `boot.img` + 11 MB initramfs（仅内核模块，无 `/init`） |

## 启动验证（已核验）

QEMU 8.2.2、TCG、`virt`/cortex-a57、2 vCPU/2 GiB：QEMU-virt 内核启动，
探测到全部三块 virtio-blk 磁盘，随后 23 次以相同方式 panic
（`VFS: Unable to mount root fs`，无 `/init`），因没有任何 boot 镜像带真正的
ramdisk/`vendor_boot`。Android 未启动，无 adb。记录见 `BOOT.md` 与
`qemu-restore/`（基线已复现）。

## 复现要点

1. 按上文钉选同步源码，应用两行本地补丁（或在支持 `cp -p` 的文件系统上构建，
   则不需要补丁）。
2. 用上文命令构建 QEMU-virt dist，核对 Image SHA-256 与 `.config` 中的 virtio 项。
3. 内核只负责启动到 `/init`；继续需要 ramdisk + first-stage init + vendor sepolicy，
   见 `ramdisk-v2/`、`vendor-sepolicy/` 与 `QEMU-BOOT-CHECKLIST.md`。
