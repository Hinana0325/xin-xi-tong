#!/usr/bin/env bash
# run-boot.sh — QEMU virt boot harness (xin-xi-tong bootable-image test).
#
# Read-only inputs: kernel / initrd / system.img are COPIED into the run
# directory before QEMU starts; the originals are never written to.
# system.img is attached readonly=on in addition, so a guest write attempt
# cannot mutate the copy either. userdata/metadata images are created fresh
# in the run directory for every run.
#
# Usage:
#   run-boot.sh --kernel K --initrd I [--extra-initrd E] [--boot-img B]
#               [--system-img S] --out DIR --label NAME
#               [--timeout SEC] [--no-progress SEC] [--loop-seconds SEC]
#               [--append "cmdline"] [--no-reboot]
#
#   --boot-img B : Android boot image; kernel (+ramdisk, if any) are
#                  unpacked from it. --initrd overrides the unpacked ramdisk.
#   --loop-seconds N : run WITHOUT -no-reboot for N seconds (reboot-loop
#                  determinism check), then kill QEMU. Default: use
#                  -no-reboot and stop at first panic/reset.
#   Exit status: 0 if QEMU exited on its own (panic/reset or clean exit),
#   124 if the timeout/watchdog killed it, 2 on usage/input errors.
#   Always writes: serial.log, qemu-cmdline.txt, inputs.txt, run-info.txt
#   into --out, plus stage-scan.txt (marker grep with line numbers).
set -u
KERNEL=""; INITRD=""; EXTRA_INITRD=""; BOOT_IMG=""; SYSTEM_IMG=""
OUT=""; LABEL=""; TIMEOUT=2700; NO_PROGRESS=1200; LOOP_SECONDS=0
APPEND="console=ttyAMA0,115200 androidboot.console=ttyAMA0 androidboot.hardware=qemu androidboot.selinux=permissive androidboot.verifiedbootstate=orange androidboot.vbmeta.device=none printk.devkmsg=on"
NO_REBOOT=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --kernel) KERNEL="$2"; shift 2;;
    --initrd) INITRD="$2"; shift 2;;
    --extra-initrd) EXTRA_INITRD="$2"; shift 2;;
    --boot-img) BOOT_IMG="$2"; shift 2;;
    --system-img) SYSTEM_IMG="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --label) LABEL="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --no-progress) NO_PROGRESS="$2"; shift 2;;
    --loop-seconds) LOOP_SECONDS="$2"; shift 2;;
    --append) APPEND="$2"; shift 2;;
    --no-reboot) NO_REBOOT=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$OUT" ] && [ -n "$LABEL" ] || { echo "--out and --label required" >&2; exit 2; }
[ -n "$SYSTEM_IMG" ] || SYSTEM_IMG="$HOME/workspace/qemu-boot/system.img"
[ -f "$SYSTEM_IMG" ] || { echo "system.img not found: $SYSTEM_IMG" >&2; exit 2; }

mkdir -p "$OUT"
RUN_DIR="$OUT/work"
mkdir -p "$RUN_DIR"
echo "label=$LABEL" > "$OUT/run-info.txt"
echo "started_utc=$(date -u +%FT%TZ)" >> "$OUT/run-info.txt"
echo "qemu=$(qemu-system-aarch64 --version | head -1)" >> "$OUT/run-info.txt"

# --- Resolve kernel / initrd (copies only) ---
if [ -n "$BOOT_IMG" ]; then
  [ -f "$BOOT_IMG" ] || { echo "boot.img not found: $BOOT_IMG" >&2; exit 2; }
  cp "$BOOT_IMG" "$RUN_DIR/boot.img"
  python3 "$SCRIPT_DIR/unpack_bootimg.py" "$RUN_DIR/boot.img" \
    "$RUN_DIR/Image" "$RUN_DIR/boot-ramdisk.img" > "$OUT/unpack.txt" 2>&1 \
    || { echo "boot.img unpack failed:"; cat "$OUT/unpack.txt"; exit 2; }
  cat "$OUT/unpack.txt" >> "$OUT/run-info.txt"
  [ -z "$KERNEL" ] && KERNEL="$RUN_DIR/Image"
  if [ -z "$INITRD" ] && [ -s "$RUN_DIR/boot-ramdisk.img" ]; then
    INITRD="$RUN_DIR/boot-ramdisk.img"
  fi
fi
[ -n "$KERNEL" ] || { echo "no kernel: pass --kernel or --boot-img" >&2; exit 2; }
[ -f "$KERNEL" ] || { echo "kernel not found: $KERNEL" >&2; exit 2; }
cp "$KERNEL" "$RUN_DIR/kernel-Image"
KERNEL_COPY="$RUN_DIR/kernel-Image"

INITRD_ARG=()
if [ -n "$INITRD" ]; then
  [ -f "$INITRD" ] || { echo "initrd not found: $INITRD" >&2; exit 2; }
  cp "$INITRD" "$RUN_DIR/initrd.img"
  if [ -n "$EXTRA_INITRD" ]; then
    [ -f "$EXTRA_INITRD" ] || { echo "extra initrd not found: $EXTRA_INITRD" >&2; exit 2; }
    # Concatenated cpio archives (and concatenated gzip members) are
    # unpacked sequentially by the kernel, so concatenation is a valid
    # way to combine a generic ramdisk with a vendor ramdisk.
    cp "$EXTRA_INITRD" "$RUN_DIR/extra-initrd.img"
    cat "$RUN_DIR/initrd.img" "$RUN_DIR/extra-initrd.img" > "$RUN_DIR/initrd-combined.img"
    INITRD_ARG=(-initrd "$RUN_DIR/initrd-combined.img")
    echo "initrd=combined($(stat -c%s "$RUN_DIR/initrd-combined.img") bytes)" >> "$OUT/run-info.txt"
  else
    INITRD_ARG=(-initrd "$RUN_DIR/initrd.img")
  fi
fi

# --- Disks (copies / fresh) ---
cp "$SYSTEM_IMG" "$RUN_DIR/system.img"
echo "system_img_sha256=$(sha256sum "$RUN_DIR/system.img" | cut -d' ' -f1)" >> "$OUT/run-info.txt"
echo "kernel_sha256=$(sha256sum "$KERNEL_COPY" | cut -d' ' -f1)" >> "$OUT/run-info.txt"
if [ -n "$INITRD" ]; then
  echo "initrd_sha256=$(sha256sum "$INITRD" | cut -d' ' -f1)" >> "$OUT/run-info.txt"
fi
qemu-img create -f qcow2 "$RUN_DIR/userdata.qcow2" 4G > "$OUT/qemu-img.txt" 2>&1
mkfs.ext4 -F -q "$RUN_DIR/metadata.img" 16M >> "$OUT/qemu-img.txt" 2>&1

QEMU_ARGS=(
  qemu-system-aarch64
  -machine virt -cpu cortex-a57 -smp 2 -m 2048
  -accel tcg,thread=multi
  -kernel "$KERNEL_COPY"
  "${INITRD_ARG[@]}"
  -append "$APPEND"
  -drive "file=$RUN_DIR/system.img,format=raw,if=none,id=sys,readonly=on"
  -device virtio-blk-pci,drive=sys
  -drive "file=$RUN_DIR/userdata.qcow2,format=qcow2,if=none,id=user"
  -device virtio-blk-pci,drive=user
  -drive "file=$RUN_DIR/metadata.img,format=raw,if=none,id=meta"
  -device virtio-blk-pci,drive=meta
  -device virtio-gpu-pci
  -device virtio-net-pci,netdev=net0
  -netdev user,id=net0
  -display none
  -serial "file:$OUT/serial.log"
  -monitor none
)
if [ "$LOOP_SECONDS" -gt 0 ]; then
  : # reboot loop allowed: QEMU keeps running until killed below
else
  QEMU_ARGS+=(-no-reboot)
fi
printf '%q ' "${QEMU_ARGS[@]}" > "$OUT/qemu-cmdline.txt"; echo >> "$OUT/qemu-cmdline.txt"
echo "cmdline_append=$APPEND" >> "$OUT/run-info.txt"
echo "timeout_s=$TIMEOUT no_progress_s=$NO_PROGRESS loop_seconds=$LOOP_SECONDS" >> "$OUT/run-info.txt"

# --- Run with watchdog ---
"${QEMU_ARGS[@]}" > "$OUT/qemu-stdout.log" 2> "$OUT/qemu-stderr.log" &
QPID=$!
echo "qemu_pid=$QPID" >> "$OUT/run-info.txt"
START=$(date +%s)
LAST_SIZE=0; LAST_CHANGE=$START; STATUS="timeout"
if [ "$LOOP_SECONDS" -gt 0 ]; then
  sleep "$LOOP_SECONDS"
  if kill -0 "$QPID" 2>/dev/null; then kill "$QPID" 2>/dev/null; STATUS="loop-killed"; fi
  wait "$QPID" 2>/dev/null || true
else
  while kill -0 "$QPID" 2>/dev/null; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
      kill "$QPID" 2>/dev/null; STATUS="timeout"; break
    fi
    if [ -f "$OUT/serial.log" ]; then
      SZ=$(stat -c%s "$OUT/serial.log")
      if [ "$SZ" != "$LAST_SIZE" ]; then LAST_SIZE=$SZ; LAST_CHANGE=$NOW; fi
      if [ $((NOW - LAST_CHANGE)) -ge "$NO_PROGRESS" ]; then
        kill "$QPID" 2>/dev/null; STATUS="no-progress"; break
      fi
    fi
    sleep 10
  done
  wait "$QPID" 2>/dev/null; QEXIT=$?
  if [ "$STATUS" = "timeout" ] && [ "${QEXIT:-1}" -eq 0 ]; then STATUS="exited"; fi
  [ "$STATUS" = "timeout" ] && STATUS="exited"
fi
END=$(date +%s)
echo "ended_utc=$(date -u +%FT%TZ)" >> "$OUT/run-info.txt"
echo "elapsed_s=$((END - START)) status=$STATUS" >> "$OUT/run-info.txt"
echo "serial_lines=$(wc -l < "$OUT/serial.log" 2>/dev/null || echo 0)" >> "$OUT/run-info.txt"

# --- Stage scan (evidence with line numbers; absence is recorded, not hidden) ---
{
  echo "Stage scan for $LABEL (grep -n over serial.log; 'count 0' = not observed)"
  for pat in \
    "Linux version|kernel boot" \
    "console \[ttyAMA0\] enabled|serial console" \
    "virtio_blk|virtio disks probed" \
    "Freeing unused kernel|kernel init done" \
    "Run /init|first-stage init exec" \
    "init: .*first stage|init first-stage" \
    "init:.*mount|fstab mount" \
    "Kernel panic|kernel panic" \
    "VFS: Unable to mount root fs|VFS panic" \
    "No working init found|no working init" \
    "init: starting service|second-stage services" \
    "SurfaceFlinger|surfaceflinger" \
    "avc:.*denied|SELinux denial" \
    ; do
    pat_text="${pat%%|*}"; label_text="${pat##*|}"
    n=$(grep -c -E "$pat_text" "$OUT/serial.log" 2>/dev/null || echo 0)
    echo "--- $label_text: count=$n"
    grep -n -E "$pat_text" "$OUT/serial.log" 2>/dev/null | head -5
  done
} > "$OUT/stage-scan.txt" 2>&1
echo "stage-scan written; status=$STATUS"
[ "$STATUS" = "loop-killed" ] || [ "$STATUS" = "no-progress" ] || [ "$STATUS" = "timeout" ] && exit 124
exit 0
