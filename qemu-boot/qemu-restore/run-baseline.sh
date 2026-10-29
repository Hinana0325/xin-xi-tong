#!/usr/bin/env bash
# Baseline reproduction: QEMU virt kernel + existing ramdisk copy + pristine
# GSI system.img copy. Expected known endpoint: kernel executes /init,
# init SIGABRTs, "Kernel panic - not syncing: Attempted to kill init!".
# Android must NOT boot; this run only proves the restored QEMU stack
# reproduces the pre-first-stage-init baseline.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
W="$DIR/work"
OUT="$DIR/baseline-01"
mkdir -p "$OUT"
# NOTE: virtio-net-pci uses romfile= (empty) because ipxe-qemu 1.21.1
# installs efi-virtio.rom under /usr/lib/ipxe/qemu, which this QEMU build
# does not search; the NIC option ROM is irrelevant to the init-abort
# baseline, so ROM loading is disabled rather than modifying system paths.
APPEND="console=ttyAMA0,115200 androidboot.console=ttyAMA0 androidboot.hardware=qemu androidboot.selinux=permissive androidboot.verifiedbootstate=orange androidboot.vbmeta.device=none printk.devkmsg=on"
qemu-system-aarch64 \
  -machine virt -cpu cortex-a57 -smp 2 -m 1024 \
  -accel tcg,thread=multi \
  -kernel "$W/kernel-Image" \
  -initrd "$W/initrd.img" \
  -append "$APPEND" \
  -drive "file=$W/system.img,format=raw,if=none,id=sys,readonly=on" \
  -device virtio-blk-pci,drive=sys \
  -drive "file=$W/userdata.qcow2,format=qcow2,if=none,id=user" \
  -device virtio-blk-pci,drive=user \
  -drive "file=$W/metadata.img,format=raw,if=none,id=meta" \
  -device virtio-blk-pci,drive=meta \
  -device virtio-gpu-pci \
  -device virtio-net-pci,netdev=net0,romfile= \
  -netdev user,id=net0 \
  -display none \
  -serial "file:$OUT/serial.log" \
  -monitor none \
  -no-reboot > "$OUT/qemu-stdout.log" 2> "$OUT/qemu-stderr.log" &
QPID=$!
echo "qemu_pid=$QPID started_utc=$(date -u +%FT%TZ)" > "$OUT/run-info.txt"
echo "cmdline_append=$APPEND" >> "$OUT/run-info.txt"
START=$(date +%s); LAST_SIZE=0; LAST_CHANGE=$START; STATUS="exited"
while kill -0 "$QPID" 2>/dev/null; do
  NOW=$(date +%s); ELAPSED=$((NOW - START))
  if [ "$ELAPSED" -ge 900 ]; then kill "$QPID" 2>/dev/null; STATUS="timeout"; break; fi
  if [ -f "$OUT/serial.log" ]; then
    SZ=$(stat -c%s "$OUT/serial.log")
    if [ "$SZ" != "$LAST_SIZE" ]; then LAST_SIZE=$SZ; LAST_CHANGE=$NOW; fi
    if [ $((NOW - LAST_CHANGE)) -ge 300 ]; then kill "$QPID" 2>/dev/null; STATUS="no-progress"; break; fi
  fi
  sleep 10
done
wait "$QPID" 2>/dev/null; QEXIT=$?
echo "ended_utc=$(date -u +%FT%TZ) elapsed_s=$(( $(date +%s) - START )) status=$STATUS qemu_exit=$QEXIT" >> "$OUT/run-info.txt"
echo "serial_lines=$(wc -l < "$OUT/serial.log" 2>/dev/null || echo 0)" >> "$OUT/run-info.txt"
echo "STATUS=$STATUS QEXIT=$QEXIT"
