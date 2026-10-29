# QEMU virt boot attempt — Android 17 QPR3 Beta GSI + android17-6.18 QEMU kernel

QEMU-only test. No real-device work. All inputs were copied read-only into
`~/workspace/qemu-boot/`; the originals in `~/workspace/kernel-android17-6.18/`
and `~/workspace/gsi/` were not modified.

## Inputs (verified)

- Kernel: `Image-qemu-virt` (copy of
  `~/workspace/kernel-android17-6.18/out/dist-qemu-virt/Image`, 43 MB),
  `Linux version 6.18.21-android17-5-maybe-dirty-4k`, ARM64, 4K pages,
  virtio blk/net/console/input/mmio/PCI + virtio-gpu built in (`=y`).
  No `boot.img` exists for this dist (Kleaf packaging failed; dist was
  manually assembled).
- Generic ramdisk / modules: `initramfs.img` (copy of the virtual-device
  dist initramfs, 11 MB, LZ4 cpio). Inspected: it contains ONLY
  `lib/modules/6.18.21-android17-5-maybe-dirty-4k/**` — no `/init`, no
  fstab. It is a kernel-modules archive, NOT a first-stage ramdisk.
- Virtual-device `boot-virtual-device.img`: Android boot image header v4,
  `header_size=1584`, `kernel_size=43989504`, **`ramdisk_size=0`** — kernel
  only, no ramdisk. Same for `boot-gz/lz4/lzma/zst.img`. No `vendor_boot.img`
  exists in the virtual-device dist.
- GSI: `aosp_arm64-exp-DP11.261002.005-16594701-a359a50b.zip`, SHA-256
  `a359a50b6eb8e9f63168e928bd14167603225e92cd8605ec86a4bda6591fc13b`
  (verified). Extracted copy: `system.img` 2,114,777,088 bytes (ext4),
  `vbmeta.img` 4,096 bytes, `build.prop` (fingerprint
  `Android/generic_system/generic:17/DP11.261002.005/16594701:user/release-keys`,
  SDK 37). The GSI zip contains no kernel, no ramdisk, no vendor image.
- `system.img` root (read via debugfs): `/init` symlink -> `/system/bin/init`
  (2.6 MB binary present), `/system/etc/init/`, `/system/etc/fstab.postinstall`
  — but no generic `fstab.*` for first-stage mounting. The GSI expects the
  device/vendor ramdisk to supply first-stage init + fstab.

## Images created here

- `userdata.qcow2` — fresh, 4 GB qcow2 (`qemu-img create -f qcow2`).
- `metadata.img` — fresh, 16 MB raw ext4 (`mkfs.ext4 -F`).
- `system.img`, `vbmeta.img`, `build.prop` — extracted copies (see above).

## QEMU

- `qemu-system-aarch64` 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1.18), installed via
  apt. Note: the first `apt-get update` hung on a slow mirror and was killed;
  after dropping the slow cogentco mirror (azure mirror only) `apt-get update`
  succeeded and the install completed. The apt sources change is a system
  (ephemeral) change, not a workspace change.
- Host: x86_64, 2 vCPUs, 7.7 GiB RAM — arm64 guest runs under TCG, no KVM.

## Command line (attempt 1)

```
qemu-system-aarch64 \
  -machine virt \
  -cpu cortex-a57 \
  -smp 2 \
  -m 2048 \
  -accel tcg,thread=multi \
  -kernel Image-qemu-virt \
  -initrd initramfs.img \
  -append "console=ttyAMA0,115200 androidboot.console=ttyAMA0 androidboot.hardware=qemu androidboot.selinux=permissive androidboot.verifiedbootstate=orange androidboot.vbmeta.device=none printk.devkmsg=on" \
  -drive file=system.img,format=raw,if=none,id=sys,readonly=on \
  -device virtio-blk-pci,drive=sys \
  -drive file=userdata.qcow2,format=qcow2,if=none,id=user \
  -device virtio-blk-pci,drive=user \
  -drive file=metadata.img,format=raw,if=none,id=meta \
  -device virtio-blk-pci,drive=meta \
  -device virtio-gpu-pci \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0 \
  -display none \
  -serial file:serial.log \
  -monitor none
```

Kernel built-in cmdline (from the QEMU fragment `.config`, `CONFIG_CMDLINE_EXTEND=y`):
`console=ttynull stack_depot_disable=on cgroup_disable=pressure kasan.stacktrace=off kvm-arm.mode=protected bootconfig`
— the `-append` cmdline extends it; `console=ttyAMA0` comes last and is
expected to become the preferred console.

Verified Boot: no signing was attempted. `vbmeta.img` was NOT attached;
`androidboot.verifiedbootstate=orange` / `androidboot.vbmeta.device=none`
were passed on the cmdline only. Whether first-stage init honours them could
not be tested because boot does not reach init (see serial.log).

## Known gap before running (recorded, not assumed away)

There is no first-stage ramdisk in any provided artifact: the kernel-only
boot.img, the modules-only initramfs, and the ramdisk-less GSI together mean
the kernel has no `/init` to exec after unpacking the initramfs. The expected
outcome of attempt 1 is therefore a kernel boot followed by a
"No working init found" panic (or equivalent). This attempt exists to verify
the kernel itself under TCG (decompression, virtio probing, console) and to
capture the exact failure stage as evidence. The next blocker after that is:
assemble a real first-stage ramdisk / vendor_boot (init + linker + libs +
fstab + sepolicy, sourced from the GSI system image or a matching AOSP
ramdisk build) — that assembly was NOT done here.

## Result (attempt 1, run 2026-10-29 ~03:52–03:56 UTC, killed after deterministic loop)

Stage reached: **kernel boots fully, then kernel-panics in a reboot loop.
No init, no Android userspace, no adb. Did NOT boot to Android.**

Evidence (`serial.log`, 8,335 lines, verbatim):
- 23 identical boot cycles, 23 identical panics. Each cycle: kernel
  `6.18.21-android17-5-maybe-dirty-4k` boots on QEMU `virt`
  (cortex-a57, TCG), reaches ~2.8 s guest time, panics, and the guest
  reboots via PSCI (QEMU was left running without `-no-reboot`, so it
  looped; killed with SIGTERM once the loop was confirmed deterministic).
- Virtio validated: panic-time partition list shows
  `fe00 2065212 vda (driver: virtio_blk)` = system.img,
  `fe10 4194304 vdb (driver: virtio_blk)` = userdata.qcow2,
  `fe20 16384 vdc (driver: virtio_blk)` = metadata.img. The QEMU fragment
  kernel's built-in virtio-blk works; PL011 serial console works
  (`console [ttyAMA0] enabled`).
- Failure lines (identical every cycle, first cycle):
  ```
  [    2.798096][    T1] check access for rdinit=/init failed: -2, ignoring
  [    2.827109][    T1] /dev/root: Can't open blockdev
  [    2.828984][    T1] VFS: Cannot open root device "" or unknown-block(0,0): error -6
  [    2.829062][    T1] Please append a correct "root=" boot option; here are the available partitions:
  ...
  [    2.861391][    T1] Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
  ```
  Cause (evidence-based, not guessed): the unpacked initramfs contains no
  `/init` (modules only), so the kernel falls through to mounting a root
  filesystem, but no `root=` was given and no initramfs init exists to run.
  Verified Boot was never reached/tested — boot stops before init.

## Next blocker

Assemble a real first-stage ramdisk / vendor_boot for QEMU virt: Android
first-stage `init` + dynamic linker + its shared libraries + fstab for the
virtio disks (vda/vdb/vdc) + sepolicy, sourced from the GSI system image
(`/system/bin/init` etc. are present in system.img) or from a matching AOSP
ramdisk build. Until that exists, no cmdline/drive change can get past this
panic — the panic is in kernel root-mounting, not in Android init. After a
ramdisk exists, the next unknowns in order are: vendor HALs (graphics/audio/
sensors — none present), fstab/partition naming for virtio, and SELinux
policy for a QEMU-only build.
