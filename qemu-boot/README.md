# QEMU virt 启动工具与记录

本目录存放 QEMU `virt` 上启动通用 Android 17 GSI 的脚本、文档与诊断记录。
按项目分工存放在此，与 `custom/`（单用户特权 Agent）与 `os/`（Linux 实验）
分开；OriginOS 7 移植本身是另一条线，这里只有通用 Android 17 的 QEMU 启动工作，
不是 OriginOS 7 固件。

目标：QEMU `virt` / cortex-a57，Android 17 QPR3 Beta GSI（构建号 DP11.261002.005，
ARM64 无 GMS）。GSI 原包不在此目录（1.2 GB zip，SHA-256 另行记录保管）。

## 当前状态（截至 2026-10-29）

**Android 从未启动；没有可启动的镜像。** 已定位根因：GSI 的 init 二进制没有
first-stage 分支，ramdisk `/init` 指向它并以 argc=1 执行时必触发
`LOG(FATAL) "Second-stage init requires an argument to main()"`。
第一道关是真正的 first-stage init 二进制（AOSP 构建进行中），第二道关是最小
vendor sepolicy 集在启动时是否被接受（仅离线编译验证过）。

## 目录

- `QEMU-BOOT-CHECKLIST.md` — QEMU 启动检查清单（工作清单，含核验修正）
- `FLASH-CHECKLIST-REFERENCE.md` — 真机刷机包检查清单，仅存档参考，不按它做
- `BOOT.md` — 首次 QEMU 启动尝试记录（内核启动后 VFS panic，无 ramdisk）
- `qemu-restore/` — QEMU 8.2.2 恢复与基线复现脚本（`run-baseline.sh` +
  `baseline-01/serial.log`，复现到 init FATAL 的基线）
- `ramdisk-v2/` — 参数化 ramdisk 组装脚本（等 first-stage 二进制到达后组装；
  仅用替身验证过流水线，未真正启动过）
- `bootimg-sepolicy/` — 从零组装 v4 boot.img 的脚本与独立解析器，及 sepolicy
  就绪性分析（ramdisk `/sepolicy` 在分流策略设备上不被读取；vendor 三件套缺失）
- `vendor-sepolicy/` — 最小 vendor sepolicy 三件套（`plat_sepolicy_vers.txt` 为
  `202604`，另两个文件仅注释）与离线编译验证脚本；仅证明离线可编，
  启动接受性未验证
- `integration/` — system.img 集成脚本与替换映射（仅用 3 个 dummy APK 在副本上
  测过；`--remove-replaced` 会损坏文件系统，已禁用）
- `bootable/` — 第一批多 agent 启动镜像尝试的脚本与记录（均未启动成功；
  含 `--grow-mb` 验证记录）
- `diagnosis/` — init 崩溃诊断链：DIAGNOSIS（linker 之后、init 日志之前崩溃）、
  最小 PIE 对照实验、GDB 会话、pt_regs 栈回溯（定位到 FATAL）

## 未包含的内容

- 内核源码与构建产物（`kernel-android17-6.18`，44 GB，android17-6.18-2026-06_r68）
- GSI 原包 zip、system.img、userdata/metadata 磁盘镜像、已组装的 ramdisk/boot.img
  二进制、各轮启动的大量日志（仅保留基线 serial.log）
- WorkBuddy 任务产物（first-stage init 二进制、vendor sepolicy 代理输入版）

## 复现基线

```sh
./qemu-restore/run-baseline.sh
```

预期终点（基线）：`Run /init as init process` → `Fatal signal 6 (SIGABRT)` →
`Kernel panic - not syncing: Attempted to kill init!`，无 `init:` 日志。
