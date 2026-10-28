#!/bin/sh
# 定制系统构建环境公共变量（在 WSL / Linux 下执行）
# 所有下载默认走国内镜像；镜像列表可用 KERNEL_MIRRORS / BUSYBOX_MIRRORS 覆盖。
OS_DIR=$(cd "$(dirname "$0")/.." && pwd)
BUILD_ROOT=${BUILD_ROOT:-/root/pvm-os-build}

KERNEL_VERSION=${KERNEL_VERSION:-7.3}
KERNEL_TARBALL=linux-${KERNEL_VERSION}.tar.xz
KERNEL_SHA256=${KERNEL_SHA256:-87363c24f10e06321eb362765521094e94471f6bff8bce2d6b3e40f39f004953}
KERNEL_MIRRORS=${KERNEL_MIRRORS:-"https://mirrors.aliyun.com/linux-kernel/v7.x https://mirrors.163.com/kernel/v7.x"}

BUSYBOX_VERSION=${BUSYBOX_VERSION:-1.37.0-r20}
BUSYBOX_APK=busybox-static-${BUSYBOX_VERSION}.apk
BUSYBOX_SHA256=${BUSYBOX_SHA256:-ee469aee2958feffd7f64dd96655704025ff60af614f77a1d7323dc237c34da2}
BUSYBOX_MIRRORS=${BUSYBOX_MIRRORS:-"https://mirrors.aliyun.com/alpine/v3.22/main/aarch64 https://mirrors.ustc.edu.cn/alpine/v3.22/main/aarch64 https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.22/main/aarch64"}

CROSS_COMPILE=${CROSS_COMPILE:-aarch64-none-elf-}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
