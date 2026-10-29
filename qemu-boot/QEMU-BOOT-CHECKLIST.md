# QEMU 启动检查清单（工作清单）

来源：Jiang 于 2026-10-29 发来的清单，状态为发送时的“原始状态”。
本文件为工作清单：按此推进，逐项核验后更新状态。核验备注以实际证据为准，
与原始状态不一致处以备注为准。

## 一、目标与环境
- [x] 确认目标为 QEMU virt / cortex-a57（原始状态：已完成）
- [x] 确认 Android 17 QPR3 Beta，DP11.261002.005（原始状态：已完成）
- [x] 确认官方 GSI 原包与 SHA-256 恢复基准（原始状态：已完成；2026-10-29 复核：zip SHA-256 a359a50b… 与记录一致）
- [ ] 确认 vda / vdb / vdc 的磁盘用途与映射（原始状态：已完成 → 核验修正：待启动验证。映射只写在手写 fstab 里，从未经过启动验证；whole-disk wait 解析未确认，见 ramdisk-v2/MOUNT-EXPECTATIONS.md）

## 二、启动镜像
- [x] boot.img v4 头结构检查（原始状态：已完成；2026-10-29 复核：parse_bootimg.py 解析通过，magic ANDROID!，header_version 4，cmdline 与记录一致）
- [ ] QEMU loader 对 boot.img 加载地址的兼容性验证（原始状态：待验证）
- [ ] 补齐 ramdisk 的 first-stage init 二进制（原始状态：未完成；WorkBuddy 任务进行中，见 MEMORY.md）
- [ ] 验证 ramdisk 文件权限、目录结构与 cpio 内容（原始状态：待复核；旧 ramdisk 已验过 204 条目，新 ramdisk 组出后重验）
- [ ] 核对内核命令行与 init 启动参数（原始状态：待验证）
- [ ] 核对 vbmeta 与 orange 验证状态配置（原始状态：待验证）

## 三、系统与运行环境
- [x] 确认 system.img 为预期的 raw ext4 GSI（原始状态：已完成）
- [ ] 核对 system 镜像挂载方式及启动参数（原始状态：待验证）
- [x] 确认 userdata 为新建镜像（原始状态：已完成）
- [ ] 确认 metadata 磁盘用途及实际访问路径（原始状态：待验证）
- [ ] 核对 QEMU virt 设备、virtio-blk 与内核驱动（原始状态：待验证；内核已验 virtio built-in，启动时枚举待确认）
- [ ] 复核 sepolicy 产物与 permissive 配置（原始状态：待复核；本地离线编译已验，启动接受性待验证）

## 四、启动故障排查
- [x] 保存当前 init FATAL 完整日志（原始状态：待完成 → 核验修正：已完成。qemu-restore/baseline-01 serial.log 及 bootable-test 8 轮日志已存）
- [x] 确认 FATAL 前最后成功执行的 init 阶段（原始状态：待完成 → 核验修正：已定位。根因为缺 first-stage init；FATAL 字符串 "Second-stage init requires an argument to main()" 已定位，见 gdb-ptregs/PTREGS-STACKWALK.md）
- [x] 定位具体失败的可执行文件、属性或挂载操作（原始状态：待完成 → 核验修正：已定位。ramdisk /init 软链至 /system/bin/init，以 argc=1 作为 PID 1 执行必触发该 FATAL）
- [ ] 每次只改变一个变量并记录结果（原始状态：待完成；新 ramdisk 启动后执行）
- [ ] 修复后重复启动并验证故障消失（原始状态：待完成）

## 五、可复现性与交付
- [x] GSI、system、boot、ramdisk、sepolicy 的 SHA-256 记录（原始状态：已完成；备注：记录的是旧 ramdisk 与旧 boot.img 的值，新 ramdisk/boot.img 组出后须重新记录）
- [x] 基线启动脚本与各 lane 文档（原始状态：已完成）
- [ ] 固定 QEMU 启动参数与环境版本（原始状态：待复核）
- [ ] 首次成功启动 Android 用户空间（原始状态：未完成）
- [ ] 重复启动与 userdata 持久性测试（原始状态：未完成）
- [ ] 整理可复现的启动包、版本说明与恢复步骤（原始状态：未开始）
