#!/usr/bin/env python3
"""Unpack an Android boot/vendor_boot image (header v0-v4, best effort).

Extracts the kernel Image and (if present) the ramdisk to separate files.
Kernel location is found empirically: the first page-aligned offset whose
bytes at +56 are the ARM64 Image magic b'ARM\\x64'. Ramdisk, when
ramdisk_size (offset 16) is non-zero, starts at the next 4096-aligned
offset after the kernel. This avoids depending on header-version-specific
field layouts that differ between GKI builds.
Exits non-zero with a message on stderr if no kernel is found.
"""
import os
import struct
import sys


def align(x, a):
    return (x + a - 1) // a * a


def main():
    if len(sys.argv) != 4:
        print("usage: unpack_bootimg.py <boot.img> <kernel-out> <ramdisk-out>",
              file=sys.stderr)
        return 2
    src, kout, rout = sys.argv[1:4]
    with open(src, "rb") as f:
        data = f.read()
    if data[:8] != b"ANDROID!":
        print("not an Android boot image (bad magic)", file=sys.stderr)
        return 1
    kernel_size = struct.unpack_from("<I", data, 8)[0]
    ramdisk_size = struct.unpack_from("<I", data, 16)[0]
    kernel_off = None
    for off in (4096, 2048, 1024, 512, 1584):
        if off + 64 <= len(data) and data[off + 56:off + 60] == b"ARM\x64":
            kernel_off = off
            break
    if kernel_off is None:
        print("kernel Image magic not found at any probed offset",
              file=sys.stderr)
        return 1
    if kernel_size == 0 or kernel_off + kernel_size > len(data):
        print(f"implausible kernel_size={kernel_size}", file=sys.stderr)
        return 1
    with open(kout, "wb") as f:
        f.write(data[kernel_off:kernel_off + kernel_size])
    if ramdisk_size:
        ram_off = align(kernel_off + kernel_size, 4096)
        if ram_off + ramdisk_size > len(data):
            print(f"implausible ramdisk_size={ramdisk_size}", file=sys.stderr)
            return 1
        with open(rout, "wb") as f:
            f.write(data[ram_off:ram_off + ramdisk_size])
        print(f"kernel_off={kernel_off} kernel_size={kernel_size} "
              f"ramdisk_off={ram_off} ramdisk_size={ramdisk_size}")
    else:
        # Empty ramdisk placeholder so callers can test for presence by size.
        open(rout, "wb").close()
        print(f"kernel_off={kernel_off} kernel_size={kernel_size} "
              "ramdisk_size=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
