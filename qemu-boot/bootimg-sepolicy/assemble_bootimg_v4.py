#!/usr/bin/env python3
"""Assemble a format-correct Android boot image, header version 4.

Inputs are read, never modified. Layout (page_size = 4096):
  [header, 1 page][kernel, page-aligned][ramdisk, page-aligned]
  second / recovery_dtbo / dtb are all absent (size 0).

Address choices are for QEMU `virt` only (RAM base 0x40000000) and are
NOT copied from any GKI reference image: the Kleaf reference boot.imgs
in this tree have kernel_addr/ramdisk_addr/tags_addr/page_size all zero,
so they carry no usable addresses. Whether QEMU's boot-image loader
honours these addresses is UNVERIFIED and must be confirmed by a boot
test; the addresses are documented here so that test can be interpreted.

  kernel_addr  0x40200000  (2 MiB aligned, clear of the DTB area at RAM start)
  ramdisk_addr 0x44000000  (above the 44 MiB kernel image)
  tags_addr    0x40000100

os_version encodes Android 17.0.0 with security-patch level 2026-10
(GSI build DP11.261002.005, 20 Oct 2026):
  (17 << 25) | (0 << 18) | (0 << 11) | ((2026 - 2000) << 4) | 10

id is SHA-1(kernel || ramdisk), first 20 bytes, remainder zero.
This is documented as the exact hash input; it is not claimed to be
byte-identical to mkbootimg's id computation.

Usage: assemble_bootimg_v4.py <kernel> <ramdisk> <output> [cmdline]
If cmdline is omitted, the smoke-test cmdline from
bootable-ramdisk/RAMDISK.md section 7 is used (see BOOTIMG.md).
"""
import hashlib
import struct
import sys

PAGE_SIZE = 4096
HEADER_VERSION = 4
HEADER_SIZE = 1660  # boot image header v4 size in bytes

KERNEL_ADDR = 0x40200000
RAMDISK_ADDR = 0x44000000
TAGS_ADDR = 0x40000100

DEFAULT_CMDLINE = (
    "console=ttyAMA0,115200 androidboot.console=ttyAMA0 "
    "androidboot.hardware=qemu androidboot.selinux=permissive "
    "androidboot.verifiedbootstate=orange androidboot.vbmeta.device=none "
    "printk.devkmsg=on"
)


def align(n, page=PAGE_SIZE):
    return (n + page - 1) // page * page


def main():
    kernel_path, ramdisk_path, out_path = sys.argv[1:4]
    cmdline = sys.argv[4] if len(sys.argv) > 4 else DEFAULT_CMDLINE
    cmdline_bytes = cmdline.encode()
    assert len(cmdline_bytes) <= 512, "cmdline does not fit in the 512-byte field"

    with open(kernel_path, "rb") as f:
        kernel = f.read()
    with open(ramdisk_path, "rb") as f:
        ramdisk = f.read()

    os_version = (17 << 25) | (0 << 18) | (0 << 11) | ((2026 - 2000) << 4) | 10
    digest = hashlib.sha1(kernel + ramdisk).digest()
    img_id = digest + b"\x00" * (32 - len(digest))

    header = bytearray(PAGE_SIZE)
    struct.pack_into("<8s", header, 0, b"ANDROID!")
    struct.pack_into("<I", header, 8, len(kernel))
    struct.pack_into("<I", header, 12, KERNEL_ADDR)
    struct.pack_into("<I", header, 16, len(ramdisk))
    struct.pack_into("<I", header, 20, RAMDISK_ADDR)
    struct.pack_into("<I", header, 24, 0)  # second_size
    struct.pack_into("<I", header, 28, 0)  # second_addr
    struct.pack_into("<I", header, 32, TAGS_ADDR)
    struct.pack_into("<I", header, 36, PAGE_SIZE)
    struct.pack_into("<I", header, 40, HEADER_VERSION)
    struct.pack_into("<I", header, 44, os_version)
    struct.pack_into("<16s", header, 48, b"\x00" * 16)  # name
    struct.pack_into("<512s", header, 64, cmdline_bytes)
    struct.pack_into("<32s", header, 576, img_id)
    struct.pack_into("<1024s", header, 608, b"\x00" * 1024)  # extra_cmdline
    struct.pack_into("<I", header, 1632, 0)  # recovery_dtbo_size
    struct.pack_into("<Q", header, 1636, 0)  # recovery_dtbo_offset
    struct.pack_into("<I", header, 1644, HEADER_SIZE)
    struct.pack_into("<I", header, 1648, 0)  # dtb_size
    struct.pack_into("<Q", header, 1652, 0)  # dtb_addr

    with open(out_path, "wb") as f:
        f.write(bytes(header))
        f.write(kernel)
        f.write(b"\x00" * (align(len(kernel)) - len(kernel)))
        f.write(ramdisk)
        f.write(b"\x00" * (align(len(ramdisk)) - len(ramdisk)))

    total = PAGE_SIZE + align(len(kernel)) + align(len(ramdisk))
    print(f"wrote {out_path}: kernel={len(kernel)} ramdisk={len(ramdisk)} "
          f"total={total} header_version={HEADER_VERSION} page_size={PAGE_SIZE}")


if __name__ == "__main__":
    main()
