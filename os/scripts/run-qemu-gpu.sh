#!/bin/sh
set -e
. "$(dirname "$0")/env.sh"
QEMU=${QEMU:-qemu-system-aarch64}
VNC=${VNC:-127.0.0.1:2}
MONITOR=${MONITOR:-/tmp/os-mon.sock}
SERIAL=${SERIAL:-stdio}
rm -f "$MONITOR"
exec "$QEMU" -M virt -cpu cortex-a57 -smp 2 -m 1024 \
  -kernel "$OS_DIR/build/Image" \
  -drive file="$OS_DIR/build/rootfs.ext4",format=raw,if=none,id=root \
  -device virtio-blk-pci,drive=root \
  -device virtio-gpu-pci \
  -append "root=/dev/vda rootwait rw console=ttyAMA0 init=/init" \
  -serial "$SERIAL" \
  -vnc "$VNC" -display none \
  -monitor "unix:$MONITOR,server=on,wait=off"
