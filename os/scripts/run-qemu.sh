#!/bin/sh
set -e
. "$(dirname "$0")/env.sh"
QEMU=${QEMU:-qemu-system-aarch64}
exec "$QEMU" -M virt -cpu cortex-a57 -smp 2 -m 1024 \
  -kernel "$OS_DIR/build/Image" \
  -drive file="$OS_DIR/build/rootfs.ext4",format=raw,if=none,id=root \
  -device virtio-blk-pci,drive=root \
  -append "root=/dev/vda rootwait rw console=ttyAMA0 init=/init" \
  -serial stdio -display none -monitor none
