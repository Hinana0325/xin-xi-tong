#!/bin/sh
set -e
. "$(dirname "$0")/env.sh"
CC=${CROSS_COMPILE}gcc
mkdir -p "$BUILD_ROOT/initramfs/dev" "$BUILD_ROOT/initramfs/proc" "$BUILD_ROOT/initramfs/sys" "$BUILD_ROOT/initramfs/tmp"
$CC -nostdlib -static -O2 -ffreestanding -fno-builtin -fno-stack-protector \
  -Wl,-e,_start -o "$BUILD_ROOT/initramfs/init" "$OS_DIR/init/bootstrap-init.c"
mkdir -p "$OS_DIR/build"
( cd "$BUILD_ROOT/initramfs" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$OS_DIR/build/initramfs.cpio.gz"
ls -la "$OS_DIR/build/initramfs.cpio.gz"
