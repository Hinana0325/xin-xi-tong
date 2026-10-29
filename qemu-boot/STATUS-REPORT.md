# 项目状态报告：QEMU virt 通用 Android 17 启动

日期：2026-10-29（Asia/Shanghai）。本文只写已核验的事实，标清未经验证的部分。

## 结论先说

**Android 从未启动；没有可启动的镜像。** 内核已编好并能在 QEMU 里启动，
GSI 系统镜像已就绪，init 崩溃的根因已定位（缺 first-stage init），
最小 vendor sepolicy 集只证明了离线可编。第一道关是 first-stage init 二进制，
WorkBuddy 上的 AOSP 构建跑了 5 个多小时仍未产出。

目标：QEMU `virt` / cortex-a57，Android 17 QPR3 Beta GSI（构建号
DP11.261002.005，ARM64 无 GMS）——通用 Android 17 替代品，不是 OriginOS 7
（vivo 闭源系统，无 QEMU 可用镜像；OriginOS 7 移植是另一条线）。

## 已完成并核验

- **内核**（`android17-6.18-2026-06_r68`，4K 页）：Kleaf/Bazel 构建，
  `common/` HEAD `edb80646c73dd6eb2ef3549f335d513916e8a70d`；
  三个 Image 已验（QEMU virt 版 virtio 全 `=y`，44,329,472 B，
  SHA-256 `578080b9…`）。详见 `KERNEL-BUILD.md`。
- **GSI 原包**：官方 Android 17 QPR3 Beta zip，SHA-256
  `a359a50b6eb8e9f63168e928bd14167603225e92cd8605ec86a4bda6591fc13b`，
  保持原样未改动，多次复验一致；内含 `system.img`（raw ext4）、`vbmeta.img`。
- **QEMU 基线**：QEMU 8.2.2、TCG、`virt`/cortex-a57，内核启动并探测全部三块
  virtio-blk 磁盘，随后因无 ramdisk 而 VFS panic。基线脚本与日志见
  `qemu-restore/`。
- **init 崩溃根因**（GDB + pt_regs 栈回溯，已定位）：GSI 的 init 二进制没有
  first-stage 分支；ramdisk `/init` 软链至 `/system/bin/init`，以 argc=1 作为
  PID 1 执行必触发 `LOG(FATAL) "Second-stage init requires an argument to main()"`。
  崩溃在 linker 跳转到 `_start` 之后、init 打印任何日志之前；libc 启动环境、
  `ld.config.txt` 缺失均已排除。记录见 `diagnosis/`。
- **三条并行 lane**（已验）：QEMU 恢复与基线复现；参数化 ramdisk 组装流水线
  （仅用替身验证）；从零组装的 v4 boot.img（已独立解析）+ sepolicy 分析
  （ramdisk `/sepolicy` 在分流策略设备上不被读取；vendor 三件套缺失是第二道关）。
- **最小 vendor sepolicy 集（本机）**：`plat_sepolicy_vers.txt` 为 `202604`，
  另两个文件仅注释；用 GSI 真实文件、`-c 33` 离线 secilc 编译 exit 0，
  产物 727,467 B、SHA-256 `58a333b2…`、重跑字节一致。**仅证明离线可编，
  启动时是否被接受未验证。** 文件见 `vendor-sepolicy/`。
- **system.img 集成脚本**：仅用 3 个 dummy APK 在副本上测过；
  `--remove-replaced` 会损坏文件系统，已禁用。见 `integration/`。
- **检查清单**：`QEMU-BOOT-CHECKLIST.md` 为工作清单；第四节前三项（日志保存、
  阶段确认、失败点定位）已完成，其余待启动验证项均阻塞在 first-stage 二进制上。

## WorkBuddy 任务与花费

账户：青 蒋（Free）。积分 348.67（29 日初）→ **177.83**（19:59 查到），
共消耗 170.84；分任务明细页面不显示。

| 任务 | 结果（截至 19:59） |
|---|---|
| 系统应用编译（12:43 完成，Hy4 preview，-23.63） | 13/13 模块编过，13 个 APK（54–57 MB），测试 68/72 过。**APK 只在 WorkBuddy 环境内，从未下载、未验安装；** 6 处源码修复只留在其拷贝内（等价修复已由本机重做并推上 system-apps 仓库）。 |
| 最小 vendor sepolicy（16:38 完成，24 分） | 三件套 + 编好策略（SHA-256 `93e10a08…`，688,585 B，`-c 30`，AOSP 代理输入）。**只佐证离线可编；** 启动用本机那套为准。 |
| first-stage init 构建（14:48 开始，仍在跑） | **无二进制。** 全树构建多次 OOM（exit 137，峰值约 6.9–7.2 GB，容器上限 8 GiB）；裁剪版避开 OOM 后报未定义模块；窄化闭包构建已过 OOM 关，陆续遇到 AIDL 冻结检查、rust aconfig panic，正在重建。产物栏仅有 BUILD-REPORT.md，其正文自认“构建尚未成功，二进制尚未产出”。 |

源码版本书面答复（该任务 agent 自述，已记录未独立核验）：同步的是
`android17-release`（manifest `29ace668`，2026-06-16），BUILD_ID
`CP2A.260605.016`，**与 GSI 的 DP11.261002.005 不相等**；AOSP 无 Android 17
QPR 分支，QPR3 源码未发布，现有源码缺约 4 个月的 QPR1–QPR3 改动。
即使编出二进制，能否与 GSI 配合只能靠开机实测。

任务链接：

- first-stage init：https://www.workbuddy.ai/app/task/2115697370825977856
- vendor sepolicy：https://www.workbuddy.ai/app/task/2115718683737141248

## 未完成 / 阻塞

1. first-stage init 二进制（WorkBuddy 窄化构建进行中；本机无法 Soong 构建）。
   备选方案（待决定）：最小 shim——本机用 NDK clang 编一个静态一阶段程序，
   挂载 system 后按 `selinux_setup` → `second_stage` 顺序 exec GSI init；
   14:46 曾选 AOSP 路线而未走 shim。
2. 新 ramdisk 组装（Lane B 流水线已备好）与 QEMU 启动测试，等二进制到达。
3. vendor sepolicy 启动接受性、fstab 挂载行为、`/system` 挂载表现、second-stage
   预期，均只能开机实测。
4. system-apps：修复已推上仓库，未重跑构建验证；APK 未取回；仓库缺
   gradle-wrapper.jar。

## 仓库状态

- xin-xi-tong：`main` 在 `99ab77e`（SPEC + Agent 代码、qemu-boot/ 工具记录、
  内核构建记录）。本地克隆已同步，干净。
- system-apps：`main` 在 `14443b0`（13 个应用 + 10 处修复）。
- PocketVM：CI 已绿（setup-android v4 修复，run 40840208797 成功）；本地克隆
  仍停在旧提交，未同步。

## 下一步

1. 等 WorkBuddy 窄化构建结果（只读复查定于次日 09:00，之后停止）。
2. 决定是否做最小 shim（与 WorkBuddy 并行或替代）。
3. 二进制一到：组新 ramdisk → 单变量启动测试 → 逐项更新检查清单。
