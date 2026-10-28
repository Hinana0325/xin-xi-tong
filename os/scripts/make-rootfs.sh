#!/bin/sh
set -e
. "$(dirname "$0")/env.sh"
if [ ! -f "$BUILD_ROOT/busybox.static" ]; then
  sh "$(dirname "$0")/fetch-busybox.sh"
fi
R="$BUILD_ROOT/rootfs"
rm -rf "$R"
cp -a "$OS_DIR/rootfs" "$R"
mkdir -p "$R/bin" "$R/dev" "$R/proc" "$R/sys" "$R/tmp" "$R/root" "$R/etc" "$R/var" "$R/mnt"
cp "$BUILD_ROOT/busybox.static" "$R/bin/busybox"
chmod 755 "$R/bin/busybox"
chmod 755 "$R/init"
mkdir -p "$OS_DIR/build"
rm -f "$OS_DIR/build/rootfs.ext4"
dd if=/dev/zero of="$OS_DIR/build/rootfs.ext4" bs=1M count=256 status=none
mke2fs -F -q -t ext4 -d "$R" "$OS_DIR/build/rootfs.ext4"
ls -la "$OS_DIR/build/rootfs.ext4"
