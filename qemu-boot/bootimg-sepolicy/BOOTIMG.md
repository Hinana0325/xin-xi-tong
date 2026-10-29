# boot.img (v4) — Lane C deliverable

**Status: assembled and structurally verified. NEVER BOOTED. Android has NOT started.**
This image must not be described as a tested boot image. No QEMU was run in
this lane (per task constraints); boot behaviour is for the QEMU lane to
establish.

## Artifact

| Item | Value |
|---|---|
| File | `boot.img` (this directory) |
| Size | 53,567,488 bytes |
| SHA-256 | `ceb95c536af8ebb3b272d9e74946a289d33f576c8398976478ccd1cdb4cd1734` |
| Kernel input (copy) | `work/kernel-Image`, 44,329,472 bytes, SHA-256 `578080b9ba3d56a21219142f7fad161f7f663d95809491899fd2da182e9aa278` (copy of `~/workspace/kernel-android17-6.18/out/dist-qemu-virt/Image`, original untouched) |
| Ramdisk input (copy) | `work/ramdisk.cpio.gz`, 9,229,914 bytes, SHA-256 `a50640cfbb0522dd1a014cf891a7413b45858feffdc2a83745ab8e0aa21b716c` (copy of `~/workspace/bootable-ramdisk/ramdisk.cpio.gz`, original untouched) |
| Assembler | `assemble_bootimg_v4.py` (Python, no mkbootimg/avbtool on this host) |
| Independent parser | `parse_bootimg.py` (shares no code with the assembler) |
| Parser output (new image alone) | `verify-new-only.txt` (exit 0, all checks OK) |
| Parser output (new vs old) | `verify-output.txt` (exit 1 **only** because the old image fails the structural checks — see below) |

## Layout

```
[header, 4096 bytes][kernel, page-aligned][ramdisk, page-aligned]
header page: 0..4095
kernel:      offset 4096, size 44,329,472 (ends 44,333,568; padded to 44,335,104)
ramdisk:     offset 44,335,104, size 9,229,914 (padded to file end 53,567,488)
second / recovery_dtbo / dtb: absent (size 0)
```

Payload round-trip verified: kernel and ramdisk bytes in the image are
byte-identical to the input copies, and bytes 1660..4095 of the header
page are all zero.

## Header fields (parser-verified)

| Field | Value |
|---|---|
| magic | `ANDROID!` |
| header_version | 4 |
| header_size | 1660 |
| page_size | 4096 |
| kernel_size / kernel_addr | 44,329,472 / `0x40200000` |
| ramdisk_size / ramdisk_addr | 9,229,914 / `0x44000000` |
| second_size / second_addr | 0 / 0 |
| tags_addr | `0x40000100` |
| os_version | `0x220001aa` = Android 17.0.0, SPL 2026-10 (see assembler source for encoding) |
| name | empty |
| cmdline | `console=ttyAMA0,115200 androidboot.console=ttyAMA0 androidboot.hardware=qemu androidboot.selinux=permissive androidboot.verifiedbootstate=orange androidboot.vbmeta.device=none printk.devkmsg=on` |
| extra_cmdline | empty |
| id | SHA-1(kernel \|\| ramdisk), first 20 bytes, remainder zero (exact hash input documented in the assembler; not claimed byte-identical to mkbootimg's id) |
| recovery_dtbo_size / offset, dtb_size / dtb_addr | 0 |

## cmdline — basis for each token

The cmdline is the exact `-append` string used in all QEMU smoke runs
(`bootable-ramdisk/RAMDISK.md` §7). It is recorded in the header so a
bootloader-style boot gets the same arguments the `-kernel`/`-initrd`
smoke tests used. Basis, token by token:

- `console=ttyAMA0,115200`, `androidboot.console=ttyAMA0`,
  `androidboot.hardware=qemu` — QEMU `virt` PL011 serial console; the
  smoke logs were captured on it. Verified working in prior lanes.
- `androidboot.selinux=permissive` — prior lanes' choice. Rationale
  recorded in RAMDISK.md §3.1: no vendor policy exists for this setup
  (see SEPOLICY-READINESS.md), so enforcing mode would deny before any
  policy is loaded. **Not verified correct**: whether first-stage init
  honours this before policy load, and whether `disabled` would bypass
  the vendor-policy requirement entirely, are open questions for the
  boot test (see SEPOLICY-READINESS.md §5).
- `androidboot.verifiedbootstate=orange`, `androidboot.vbmeta.device=none`
  — prior lanes' choice: there is no vbmeta/Verified Boot chain on
  QEMU `virt` here (the GSI `vbmeta.img` is not attached as a device).
  Recorded as a prior choice, not independently verified.
- `printk.devkmsg=on` — prior lanes' choice, so init's klog output
  reaches the serial log.

Note: the kernel also carries a built-in cmdline containing a bare
`bootconfig` token (no bootconfig blob). That is a kernel property, not
changed by this image; `/proc/bootconfig` behaviour remains as found by
the init-debug lane.

## Differences from the previous boot.img

The previous image (`~/workspace/bootable-ramdisk/boot.img`,
SHA-256 `15449e0c…`, 53,567,488 bytes) was produced by reusing the
4096-byte header page of the Kleaf virtual-device boot.img verbatim and
patching only `kernel_size` and `ramdisk_size`. The independent parser
cannot derive section offsets from it at all. Field-by-field
differences (full output in `verify-output.txt`):

| Field | Previous image | This image |
|---|---|---|
| page_size | 0 | 4096 |
| kernel_addr | 0 | `0x40200000` |
| ramdisk_addr | `0x630` (1584; junk inherited from the reused header page) | `0x44000000` |
| tags_addr | 0 | `0x40000100` |
| os_version | 0 | `0x220001aa` |
| cmdline | empty | smoke-test cmdline (above) |
| id | all zero | SHA-1(kernel \|\| ramdisk) |
| header_size | 0 | 1660 |
| kernel_size / ramdisk_size / magic / header_version / name | same | same |

The Kleaf reference images (`dist-virtual-device/boot.img`,
`dist-plain-gki/boot.img`) show the same zeroed fields, so the zeros
are a property of the Kleaf packaging, not a deliberate address
scheme. A bootloader that parses the v4 header (e.g. QEMU's boot-image
loader) cannot place sections from the previous image.

## Address choices — and their limits

`kernel_addr 0x40200000`, `ramdisk_addr 0x44000000`, `tags_addr
0x40000100` were chosen for QEMU `virt` (RAM base `0x40000000`):
2 MiB-aligned kernel load clear of the DTB area, ramdisk above the
44 MiB kernel, tags near RAM start. **These addresses are this lane's
choice, not values copied from any reference image, and whether QEMU's
loader honours header addresses (vs. its own placement) is UNVERIFIED.**
If the boot test shows the kernel loading elsewhere or not at all,
these addresses are the first thing to re-examine; the parser output
above is the evidence to compare against.

## What this lane did NOT do

- No QEMU run, no QEMU install (task constraint).
- No change to the kernel Image, the ramdisk, the GSI zip, or any other
  directory. Start/end hashes: GSI zip `a359a50b…` and ramdisk
  `a50640cf…` unchanged; old boot.img `15449e0c…` unchanged.
- No `ld.config.txt` written, no original file modified.
