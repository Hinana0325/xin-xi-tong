# os/：定制 arm64 系统（PocketVM 仓库内子项目）

从零构建的 arm64 定制 Linux 系统。目标平台分两步：先在 PC 的 QEMU `virt` 上跑通，最终进入 PocketVM（arm64 Android / 手机 + App 内的 QEMU 执行层）。

当前版本：**0.4 — 内核 + ext4 rootfs + BusyBox + virtio-gpu 显示 + Android 层内核前置（binder/binderfs）**。

## 现状（已验证）

- 内核：**Linux 7.3**（2026-10-18 mainline），arm64，`aarch64-none-elf-gcc` 交叉编译，`Image` 约 42.7 MB。
- 内核配置自带：GICv3、PL011 console、virtio-blk/net/console、ext4、devtmpfs、initramfs —— 均为内建 `=y`，启动不依赖模块。
- 根文件系统：256 MB ext4 镜像，内含 **BusyBox 1.37（aarch64 musl 静态）**；启动时 `busybox --install -s /bin` 装好全部 applet。
- 启动实测（QEMU `virt`）：

```
Linux (none) 7.3.0 #1 SMP PREEMPT ... aarch64 Linux
NAME=Linux
VERSION=7.3-custom
/dev/root  229.9M  1% used
```

- 显示：**virtio-gpu + DRM fbdev + framebuffer console**（1280×800，`Console: switching to colour frame buffer device 160x50`，`fb0: virtio_gpudrmfb`）。QEMU `screendump` 已实测出图：Tux logo + `custom Linux 7.3 / framebuffer console / kernel: 7.3.0`。
- Android 层（0.4，内核侧已验证）：`CONFIG_ANDROID_BINDER_IPC` + `ANDROID_BINDERFS`（`binder,hwbinder,vndbinder`）、`CONFIG_PSI`、FUSE、overlay、bridge/veth、netfilter 全部内建。实测 `/proc/filesystems` 有 `binder`；`/dev/binderfs` 生成 `binder` / `hwbinder` / `vndbinder` / `binder-control`，`/dev/binder` 等符号链接就位；`/proc/pressure/cpu` 可读。
- 另有 `init/bootstrap-init.c`：**不依赖 libc** 的极简 init（直接 arm64 syscall），用于无 rootfs 的 initramfs 引导与早期调试。

## 目录

```
os/
├── kernel/custom_defconfig      # savedefconfig，构建时放到内核源码里
├── init/bootstrap-init.c         # freestanding init（initramfs 用）
├── rootfs/init                   # 根文件系统启动脚本（BusyBox sh）
├── rootfs/etc/os-release
├── scripts/
│   ├── env.sh                    # 公共变量（版本/URL/SHA256/交叉前缀）
│   ├── fetch-kernel.sh           # 下载并校验 linux-7.3.tar.xz
│   ├── build-kernel.sh           # custom_defconfig → Image
│   ├── fetch-busybox.sh          # 取 Alpine aarch64 静态 BusyBox
│   ├── make-rootfs.sh            # 组装 rootfs + mke2fs -d → rootfs.ext4
│   ├── make-initramfs.sh         # 编译 bootstrap-init → initramfs
│   ├── build-all.sh              # 一键构建
│   ├── run-qemu.sh               # QEMU virt 启动（串口）
│   └── run-qemu-gpu.sh           # QEMU virt + virtio-gpu + VNC/Monitor
└── build/                        # 构建产物（gitignored）
```

内核源码本身**不入库**（约 1.8 GB），由 `fetch-kernel.sh` 按固定版本与 SHA256 拉取。

## 依赖（WSL Alpine / Linux）

- `gcc-aarch64-none-elf`（Alpine 包，当前 16.1）
- `curl`、`tar`、`xz`、`cpio`、`e2fsprogs`（`mke2fs`）
- `qemu-system-aarch64`（可用 PocketVM 的宿主构建，`QEMU=...` 指定）

```sh
apk add gcc-aarch64-none-elf curl tar xz cpio e2fsprogs
```


## 国内镜像与校验

所有下载默认走国内镜像，失败按顺序自动切换，并强制 **SHA256 校验**：

| 资源 | 版本 | 镜像（按顺序尝试） |
|---|---|---|
| Linux 内核 | 7.3 | 阿里云 → 清华 |
| BusyBox（aarch64 静态） | 1.37.0-r20 | 阿里云 → 清华 → 中科大 |

- 内核 `sha256=87363c24f10e06321eb362765521094e94471f6bff8bce2d6b3e40f39f004953`
- BusyBox apk `sha256=ee469aee2958feffd7f64dd96655704025ff60af614f77a1d7323dc237c34da2`（与官方 dl-cdn 包字节一致）

镜像列表可用 `KERNEL_MIRRORS` / `BUSYBOX_MIRRORS` 覆盖（空格分隔的 base URL），例如：

```sh
KERNEL_MIRRORS="https://mirrors.aliyun.com/linux-kernel/v7.x" sh scripts/fetch-kernel.sh
```

## 快速开始

```sh
cd os
sh scripts/build-all.sh          # 下载内核 → 编译 Image → 取 BusyBox → 做 rootfs.ext4
sh scripts/run-qemu.sh           # 串口交互
sh scripts/run-qemu-gpu.sh       # virtio-gpu + VNC (127.0.0.1:2) + monitor socket
```

显示版可用 QEMU monitor 截屏验证：

```sh
echo 'screendump /tmp/screen.ppm' | socat - UNIX-CONNECT:/tmp/os-mon.sock
```

构建根目录默认 `/root/pvm-os-build`，可用 `BUILD_ROOT` 覆盖。

## 路线图

1. ~~内核 + freestanding init（initramfs）~~ ✅
2. ~~ext4 根文件系统 + BusyBox~~ ✅
3. ~~显示：virtio-gpu / framebuffer console~~ ✅（0.3）
4. Android 层：binder/binderfs 内核前置 ✅（0.4）；下一步接 Android 用户空间（容器方案）
5. 持久化与控制台：/etc 配置、串口 getty、启动日志
6. 打包进 PocketVM（arm64 执行层 + 镜像导入）
