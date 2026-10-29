#!/usr/bin/env bash
# run-gdb-session.sh — QEMU virt + gdb stub session: pt_regs userspace stack walk.
# Copies only (work/); originals untouched. QEMU runs with -S -gdb tcp::1234
# -no-reboot; gdb-multiarch runs in batch mode and drives the session from
# gdb-script.txt. Kills QEMU afterwards.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
QEMU_LOG="$DIR/qemu-gdb.log"
rm -f "$DIR/serial.log" "$DIR/gdb-transcript.txt" "$DIR/gdb-stdout.log"
qemu-system-aarch64 \
  -machine virt \
  -cpu cortex-a57 \
  -smp 2 \
  -m 2048 \
  -accel tcg,thread=multi \
  -kernel work/kernel-Image \
  -initrd work/ramdisk.cpio.gz \
  -append "nokaslr console=ttyAMA0,115200 androidboot.console=ttyAMA0 androidboot.hardware=qemu androidboot.selinux=permissive androidboot.verifiedbootstate=orange androidboot.vbmeta.device=none printk.devkmsg=on" \
  -drive file=work/system.img,format=raw,if=none,id=sys,readonly=on \
  -device virtio-blk-pci,drive=sys \
  -drive file=work/userdata.qcow2,format=qcow2,if=none,id=user \
  -device virtio-blk-pci,drive=user \
  -drive file=work/metadata.img,format=raw,if=none,id=meta \
  -device virtio-blk-pci,drive=meta \
  -device virtio-gpu-pci \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0 \
  -display none \
  -serial file:serial.log \
  -monitor none \
  -S -gdb tcp::1234 -no-reboot >"$QEMU_LOG" 2>&1 &
QEMU_PID=$!
echo "QEMU pid=$QEMU_PID"
sleep 3
echo "starting gdb (QEMU -S already listening on :1234)"
timeout 420 gdb-multiarch -batch -x gdb-script.txt > gdb-stdout.log 2>&1
GDB_RC=$?
echo "gdb rc=$GDB_RC"
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
echo "qemu reaped rc=$?"
echo "session done"
