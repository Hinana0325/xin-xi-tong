# GSI 对 first-stage 的挂载 / 准备期望

来源：只读挖掘 GSI 解出内容（`~/workspace/init-debug/extract/`，由 `system.img`
经 debugfs 解出）与 `system.img` 只读副本（`~/workspace/qemu-boot/system.img`，
debugfs 只读 `ls`）。**没有运行 QEMU，没有修改任何原始文件。**

重要前提：GSI zip 内只有 `system.img`、`vbmeta.img`、`build.prop`——没有
vendor 镜像、没有 boot 镜像、没有 vendor ramdisk。因此下面凡是 GSI 文件中
没有的东西，一律记为“未确认”，不推测为事实。

> 注意：解出树根部的 `/fstab`、`/fstab.qemu`、`/first_stage_ramdisk/` 是
> 先前 agent 手写后放入解出树的（与 `fstab.qemu` 内容逐字节相同，2416 B），
> 不是 GSI 原有文件。`system.img` 只读副本的根目录中**没有** `fstab`、
> `first_stage_ramdisk`、`sepolicy`。下文引用 `fstab.qemu` 时均标注为手写推测。

## 1. fstab 的查找位置（有二进制证据）

GSI `init` 二进制内含以下 fstab 查找路径字符串（`strings system/bin/init`）：

```text
/first_stage_ramdisk/fstab.
/first_stage_ramdisk/system/etc/fstab.
/fstab.
/odm/etc/fstab.
/system/etc/fstab.
/vendor/etc/fstab.
```

另有 `fstab_suffix` 字符串与 `ro.boot.*` 属性读取。由此可确认：

- first-stage init 会按上述顺序查找带后缀的 fstab，`fstab_suffix` 的取值
  来源（`ro.hardware` / cmdline）在 GSI 文件中**未确认**（GSI 的 `build.prop`
  在 zip 根部，不在 `system.img` 内；解出树中无 `system/build.prop`）。
- GSI 自身不带任何 `fstab.*`：`system.img` 根目录与 `system/etc` 中均无
  fstab 文件（debugfs 只读 `ls` 核实）。因此 QEMU 启动用的 fstab 必须由
  ramdisk 提供（`/fstab.*` 或 `/first_stage_ramdisk/fstab.*`），其内容只能
  手写，**手写内容本身不是 GSI 证据**。

## 2. /system 挂载（system-as-root 布局，有镜像布局证据）

- `system.img` 根目录同时包含 `/init`（指向 `/system/bin/init` 的符号链接）、
  `/init.environ.rc` 与一个完整的 `/system/` 子树（`app/`、`framework/`、
  `lib64/`、`etc/`……）。这是 system-as-root 布局：first-stage 挂载 system
  分区后，`/system` 即为该子树的挂载点。
- 挂载方式（whole-disk `/dev/block/vda` 还是分区/by-name 节点）、挂载选项
  （`ro,barrier=1` 等）与 `wait` 语义：**未确认**。手写 `fstab.qemu` 的三行
  （见 §8）是先前 agent 根据 QEMU panic 日志中的磁盘探测顺序推测的，
  从未被 first-stage 走到过。
- init 二进制字符串含 `/dev/block/by-name`、`/dev/block/by-name/super`，
  说明它能处理 by-name 设备；QEMU virt 的 whole-disk 上有无 by-name 节点：
  **未确认**（取决于 ueventd 是否为 virtio-blk whole-disk 建 by-name 链接，
  GSI 文件中无证据）。
- 挂载 `/system` 后 ramdisk 内 `/system/lib64`（first-stage 依赖库）是否被
  遮住、first-stage 是否在挂载前已完成所有库加载：**未确认**。组装脚本
  （`assemble-ramdisk.sh`）把库放在 `/system/lib64`，与 v1 ramdisk 一致；
  该布局在挂载后的行为须由启动实验回答。

## 3. /dev 与 ueventd（有 rc 与二进制证据）

- `system/etc/init/hw/init.rc` 第二阶段部分：`on early-init` 中
  `mkdir /dev/bootchart`、`/dev/memcg/*`、`/dev/net` 等，并在 `start ueventd`
  后继续。ueventd 服务定义（同文件约 1243 行）：

  ```text
  service ueventd /system/bin/ueventd
      class core
      critical
      seclabel u:r:ueventd:s0
      user root
      shutdown critical
  ```

- GSI 中 `/system/bin/ueventd` 是指向 `init` 的符号链接（即同一二进制以
  `argv[0]` 区分模式）。init 二进制字符串含 `ueventd: Coldboot took ...`、
  `parallel_ueventd_main_loop`，证明 coldboot/并行 uevent 处理在该二进制内。
- first-stage 是否必须在 `selinux_setup` 之前启动 ueventd、ueventd 是否由
  first-stage 直接 exec（而非等 second-stage 的 `start ueventd`）：**未确认**。
  GSI 文件只证明 second-stage 会 `start ueventd`；first-stage 内的顺序无
  GSI 文件证据，须以 AOSP `init_first_stage` 源码或启动实验为准。
- ramdisk 内 `/dev` 静态节点（console/null/zero 等）是否为必需：先前诊断
  已证明缺节点与有节点崩溃相同（已排除为唯一原因），但 first-stage 正式
  流程是否依赖它们：**未确认**。本流水线仍打入 9 个标准节点（见 manifest）。

## 4. sepolicy（有文件证据，接受形式未确认）

- GSI 的平台策略是 CIL 文本：解出树 `/sepolicy` 与
  `/system/etc/selinux/plat_sepolicy.cil` 的 SHA-256 完全相同
  （`9db2c480…035f7b0`，3,418,955 B，首行 `(role object_r)`）。
  `/system/etc/selinux/` 下另有 `plat_file_contexts`、
  `plat_property_contexts`、`mapping/*.cil`（202404/202504/202604、31.0–33.0）。
- 解出树中**没有** `precompiled_sepolicy` 二进制文件（`find` 无结果）。
- first-stage 是否接受 CIL 文本形态的 `/sepolicy`、是否要求先编译：
  **未确认**。组装脚本按 AOSP 惯例把 CIL 文本放在 ramdisk `/sepolicy`；
  `selinux_setup` 阶段的接受与否须由启动实验回答。
- `init` 二进制字符串含 `/sepolicy`、`/dev/sepolicy.XXXXXX`（临时文件模板），
  证明它会在该路径读写策略文件；具体加载调用顺序：**未确认**。

## 5. 模式分发：selinux_setup → second_stage（有二进制证据）

init 二进制字符串同时含 `selinux_setup` 与 `second_stage`，且栈回溯已证明
`main()` 按 `argv[1]` 分发、其余情况 FATAL。由此可确认 second-stage 二进制
接受这两种调用；但以下**未确认**：

- first-stage 是否必须先 exec `selinux_setup` 再 exec `second_stage`
  （标准 AOSP 流程如此，但 GSI 文件中无调用顺序证据；须以 AOSP 源码为准，
  本 lane 不引源码作 GSI 证据）；
- `second_stage` 是否要求特定的 argv/env（除 `argv[1]` 外的参数）；
- `/second_stage_resources`（GSI 根目录下为空目录，init 字符串含该路径）
  的用途与必需内容：**未确认**。

## 6. property 区（有字符串与 rc 证据）

- init 二进制字符串含 `/dev/__properties__`、`/dev/__properties__/property_info`、
  `/data/property`、`/data/property/persistent_properties` 及
  `plat_property_contexts` 等上下文文件路径。
- `/init.environ.rc`（GSI 根目录，621 B）只含 `on early-init` 的 `export`：
  `ANDROID_ROOT /system`、`ANDROID_DATA /data` 等；由
  `system/etc/init/hw/init.rc` 首行 `import /init.environ.rc` 引入。
- property 共享内存区由 first-stage 还是 second-stage 创建、创建时序：
  **未确认**。`/system/etc/selinux/plat_property_contexts`（132,783 B）已打入
  ramdisk（随 `system/etc/selinux` 整目录），供策略加载使用。

## 7. /data 与 /metadata（仅有间接证据）

- init 二进制字符串含 `/metadata/apex`、`/metadata/gsi`、`/metadata/bootstat/*`；
  `init.rc` 有 `restorecon /metadata` 与 apexd-bootstrap 相关段落。
- `/data`、`/metadata` 的挂载（`check,formattable,quota` 等标志）与
  `first_stage_mount` 语义：**未确认**。手写 `fstab.qemu` 中的对应行是
  典型 GSI fstab 的抄录，不是本 GSI 的证据。
- `/apex`、`/vendor`、`/odm` 在 `system.img` 根目录中均为空目录；
  vendor/apex 内容的来源（本 GSI 无 vendor 镜像）：**未确认**。

## 8. 手写 fstab.qemu（推测，非 GSI 证据）

解出树中的 `fstab.qemu`（亦即组装脚本默认采用的 fstab）全文非注释行：

```text
/dev/block/vda     /system     ext4   ro,barrier=1                                               wait,first_stage_mount
/dev/block/vdb     /data       ext4   noatime,nosuid,nodev,noauto_da_alloc,barrier=1,errors=panic   wait,check,formattable,first_stage_mount,quota
/dev/block/vdc     /metadata   ext4   noatime,nosuid,nodev                                        wait,check,formattable,first_stage_mount
```

依据仅为 QEMU panic 日志中的磁盘探测顺序（vda=system、vdb=userdata、
vdc=metadata）与典型 GSI fstab 写法。`wait` 能否解析 whole-disk 节点、
`first_stage_mount` 在本 GSI init 中的实际行为，均**未确认**，须启动实验验证。

## 9. 明确不在本 lane 范围

- 不手写 `/linkerconfig/ld.config.txt`（缺失它已被先前诊断排除为崩溃原因；
  生成它属另一 lane 的 linkerconfig 工作）。
- 不断言内核 cmdline（`androidboot.selinux=permissive`、
  `androidboot.verifiedbootstate=orange` 等为先前 QEMU 运行配置，非 GSI
  文件证据）；first-stage 对 cmdline/bootconfig 的期望：**未确认**。
- 不断言 first-stage 源码行为：AOSP `init_first_stage` 的具体步骤须由
  WorkBuddy 构建任务带回的源码/构建证据确认，本文件只记录 GSI 一侧的证据。
