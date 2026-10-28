#!/bin/sh
set -e
. "$(dirname "$0")/env.sh"
SRC="$BUILD_ROOT/linux-$KERNEL_VERSION"
OUT="$BUILD_ROOT/build-arm64"
[ -d "$SRC" ] || { echo "先运行 scripts/fetch-kernel.sh"; exit 1; }
cp "$OS_DIR/kernel/custom_defconfig" "$SRC/arch/arm64/configs/custom_defconfig"
make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" O="$OUT" custom_defconfig
make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" O="$OUT" -j"$JOBS" Image
mkdir -p "$OS_DIR/build"
cp "$OUT/arch/arm64/boot/Image" "$OS_DIR/build/Image"
ls -la "$OS_DIR/build/Image"
