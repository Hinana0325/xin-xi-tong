# QEMU environment restore — baseline re-verified (QEMU virt only)

Date: 2026-10-29 (run 14:59–15:00 CST / 06:59–07:00 UTC).
Scope: this directory (`~/workspace/qemu-restore/`) only was written.
No other workspace directory was modified; all boot inputs were copies.
Android did NOT boot. Nothing was repaired — this lane only restores the
test stack and re-proves the known pre-first-stage-init endpoint.

## 1. Why QEMU was missing

At the 14:47 CST check `qemu-system-aarch64` was not in PATH and no
`qemu*` binary existed under `/usr/bin`; `dpkg` had no record of
`qemu-system-arm` (package state: not installed). Evidence only shows
the package was absent on this VM instance; whether the VM was
reprovisioned or the package was removed is not established and is not
claimed here.

## 2. Restore (apt only, no full upgrade)

`apt-get update` hung for 6+ minutes on the HTTP mirror methods and was
killed; the cached package lists already contained the candidate, so the
install below used cached lists. A future reinstall on a fresh instance
may need a working `apt-get update` first.

```bash
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qemu-system-arm qemu-utils
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ipxe-qemu
```

Installed and verified:

| Package | Version |
|---|---|
| qemu-system-arm | 1:8.2.2+ds-0ubuntu1.18 (`QEMU emulator version 8.2.2`) |
| qemu-utils | 1:8.2.2+ds-0ubuntu1.18 |
| ipxe-qemu | 1.21.1+git-20220113.fbbdc3926-0ubuntu2 |

Same QEMU version (8.2.2) as the earlier harness runs.

### Known quirk: virtio-net option ROM

With only `--no-install-recommends`, QEMU failed at startup:
`failed to find romfile "efi-virtio.rom"`. ipxe-qemu installs
`efi-virtio.rom` under `/usr/lib/ipxe/qemu/`, which this QEMU build
does not search. Fix used here (no system firmware paths modified):
the baseline command disables ROM loading for the NIC only
(`virtio-net-pci,romfile=`). The NIC option ROM is irrelevant to the
init-abort baseline. If a future run needs PXE/network boot, install
the full recommended set instead of relying on `romfile=`.

## 3. Baseline run (reproduced)

Script: `run-baseline.sh` in this directory (timeout 900 s, no-progress
watchdog 300 s; QEMU exited on its own after ~10 s wall time).
Inputs — all copies in `work/`, originals untouched:

| Input | SHA-256 |
|---|---|
| Kernel `work/kernel-Image` (copy of `kernel-android17-6.18/out/dist-qemu-virt/Image`) | `578080b9ba3d56a21219142f7fad161f7f663d95809491899fd2da182e9aa278` |
| Initrd `work/initrd.img` (copy of `bootable-ramdisk/ramdisk.cpio.gz`) | `a50640cfbb0522dd1a014cf891a7413b45858feffdc2a83745ab8e0aa21b716c` |
| System `work/system.img` (copy of `qemu-boot/system.img`, pristine GSI) | `e771161b08b7d62614bc067b17861587532ae94de79b85a0e9a0afa381b07b85` |
| userdata `work/userdata.qcow2` | fresh 4G qcow2 per run |
| metadata `work/metadata.img` | fresh 16M ext4 per run |

Full QEMU command (as run; `$W` = `~/workspace/qemu-restore/work`,
`$OUT` = `~/workspace/qemu-restore/baseline-01`):

```bash
qemu-system-aarch64 \
  -machine virt -cpu cortex-a57 -smp 2 -m 1024 \
  -accel tcg,thread=multi \
  -kernel "$W/kernel-Image" \
  -initrd "$W/initrd.img" \
  -append "console=ttyAMA0,115200 androidboot.console=ttyAMA0 androidboot.hardware=qemu androidboot.selinux=permissive androidboot.verifiedbootstate=orange androidboot.vbmeta.device=none printk.devkmsg=on" \
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
  -no-reboot
```

Disk order is vda=system, vdb=userdata, vdc=metadata (same as the
earlier harness).

### Memory choice: `-m 1024`, not 2048

The earlier harness used `-m 2048`. At restore time this host had only
~738 MiB available (7.7 GiB total, parallel lanes running, no swap), so
2048 MiB guest RAM risked host OOM under TCG. 1024 MiB is ample for a
kernel+initramfs early-boot reproduction, and the run below proves it
reaches the same endpoint. If a later run needs more guest RAM (e.g.
full userspace), re-check `free -h` first and raise `-m` only with
headroom to spare.

### Result — known endpoint reproduced exactly

`baseline-01/serial.log`: 307 lines. Key lines (verbatim):

- Line 2: `Linux version 6.18.21-android17-5-maybe-dirty-4k ...`
- Line 281: `Run /init as init process`
- Line 284: `libc: Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 1 (init), pid 1 (<unknown>)`
- Line 285: `Kernel panic - not syncing: Attempted to kill init! exitcode=0x00007f00`

Zero `init:` log lines before the abort; no second-stage, no
SurfaceFlinger, no adb, no desktop. QEMU exited on its own
(`QEXIT=0`); no QEMU process was left running (verified with
`ps` after the run). Baseline verification: PASS — the restored stack
reproduces the pre-first-stage-init endpoint.

## 4. Handover: when the new first-stage init arrives

The WorkBuddy AOSP first-stage build is the gating item and had not
arrived when this lane ran. When its binary arrives, the ONLY step that
changes in this lane is the ramdisk:

1. In a NEW directory (never edit `bootable-ramdisk/` originals),
   unpack a copy of `ramdisk.cpio.gz`, replace `/init` (currently a
   symlink to the second-stage-only `/system/bin/init`) with the new
   first-stage binary plus whatever library closure it needs, and
   repack to a new `initrd.img` copy.
2. Copy the new `initrd.img` over `work/initrd.img` in THIS directory
   (or point `run-baseline.sh` at the new file), keep kernel/disks/
   cmdline identical, and re-run `run-baseline.sh` into a new output
   directory (do not overwrite `baseline-01/`).
3. Success for that run is narrow: any `init:` log line, any mount/
   fstab line, or a DIFFERENT failure past the current FATAL counts
   as progress and must be recorded verbatim. Only second-stage
   services/adb may be described as boot progress; absence of this
   FATAL alone does not mean Android booted.

Do not hand-write `ld.config.txt` (ruled out as the abort cause), do not
modify the ramdisk contents in place here, and re-verify the GSI zip
SHA-256 before and after any future run.

## 5. Originals integrity (checked before and after)

- GSI zip: `a359a50b6eb8e9f63168e928bd14167603225e92cd8605ec86a4bda6591fc13b` — unchanged.
- `bootable-ramdisk/ramdisk.cpio.gz`: `a50640cfbb0522dd1a014cf891a7413b45858feffdc2a83745ab8e0aa21b716c` — unchanged.
- Host resources at restore: 2 vCPU, 7.7 GiB RAM (~738 MiB available
  at run start, ~1.1 GiB after), 122 GiB disk free, x86_64, TCG only
  (no KVM).
