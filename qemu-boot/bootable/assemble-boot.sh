#!/bin/bash
# assemble-boot.sh — build boot.img from the QEMU kernel Image + ramdisk.cpio.gz
# for QEMU virt only. No mkbootimg/abootimg on this host, so the script
# reuses the 4096-byte header page of the Kleaf virtual-device boot.img
# verbatim and patches only kernel_size (offset 8) and ramdisk_size
# (offset 16). All other header words in that source image are zero
# (kernel_addr/ramdisk_addr/page_size/os_version/cmdline empty), and
# are preserved as-is; do not interpret them as standard v4 semantics.
# Layout: [header page 4096][kernel, page-aligned][ramdisk, page-aligned].
# Usage: ./assemble-boot.sh [kernel] [ramdisk] [output]
set -euo pipefail
K="${1:-Image-qemu-virt}"
R="${2:-ramdisk.cpio.gz}"
OUT="${3:-boot.img}"
REF="/home/hatch/workspace/kernel-android17-6.18/out/dist-virtual-device/boot.img"
python3 - "$K" "$R" "$OUT" "$REF" <<'PY'
import struct, sys, os
kernel, ramdisk, out, ref = sys.argv[1:5]
k = open(kernel, "rb").read()
r = open(ramdisk, "rb").read()
hdr = bytearray(open(ref, "rb").read(4096))
assert hdr[:8] == b"ANDROID!", "reference is not an Android boot image"
assert struct.unpack("<I", hdr[40:44])[0] == 4, "expected header_version 4"
struct.pack_into("<I", hdr, 8, len(k))
struct.pack_into("<I", hdr, 16, len(r))
page = 4096
def align(n): return (n + page - 1) // page * page
with open(out, "wb") as f:
    f.write(bytes(hdr))
    f.write(k)
    f.write(b"\0" * (align(len(k)) - len(k)))
    f.write(r)
    f.write(b"\0" * (align(len(r)) - len(r)))
print(f"wrote {out}: kernel={len(k)} ramdisk={len(r)} total={os.path.getsize(out)}")
PY
