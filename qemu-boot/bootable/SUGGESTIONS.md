# Suggestions for A (ramdisk) and B (integration) — from boot harness evidence only

All items below are derived from serial logs in `logs/` in this directory.
Nothing in `~/workspace/bootable-ramdisk/` or `~/workspace/bootable-integration/`
was modified. "Unproven" means: a hypothesis consistent with the logs, not
yet demonstrated by a passing boot.

## Blocker (verified): GSI `init` starts, prints nothing, terminates

- `logs/ramdisk-01/serial.log` line 283: `Run /init as init process`
  (kernel 6.18.21, QEMU virt, A ramdisk `3c468960…`).
- Lines 284–286: linker warning about missing `/linkerconfig/ld.config.txt`,
  then `libc: Fatal signal 6 (SIGABRT) … in tid 1 (init)`, then line 287
  `Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000100`.
- No `init:` log line, no first-stage mount line, no fstab line appears
  before the abort. First-stage mount was therefore **not reached**.
- A's own smoke log (`~/workspace/bootable-ramdisk/diag-serial.log`,
  line 283–291) shows the same shape: `Run /init`, linker warning,
  panic `exitcode=0x00002a00`. Two independent runs, same failure point.

## Excluded by experiment (do not re-chase)

1. **Generic userspace / dynamic linker / bootstrap libs: WORKING.**
   `logs/diag-sh-02/serial.log` line 283: with cmdline
   `rdinit=/system/bin/sh`, toybox `sh` ran to a `# ` prompt and idled
   (watchdog-killed after 60 s of no progress, exit 124 by design).
   The same linker warning appears there and is non-fatal for `sh`.
   All 17 `DT_NEEDED` libraries of `system/bin/init` are present in the
   ramdisk with real sizes (checked read-only from the cpio listing;
   e.g. `libfs_mgr.so` 598,128 B, `libselinux.so` 448,000 B,
   `libc++.so` 1,154,016 B; `libc.so`/`libm.so`/`libdl.so` are 0-byte
   stubs in `system/lib64/` with real copies under `bootstrap/`, which is
   the normal GSI layout).
2. **SELinux setup: NOT the sole cause.** `logs/ramdisk-02-selinux-disabled/`
   (cmdline `androidboot.selinux=disabled` instead of `permissive`) aborts
   identically at lines 283–287. Do not spend another cycle on selinux flags.
3. **Missing `/linkerconfig/ld.config.txt` is NOT proven to be the cause.**
   It is the only userspace diagnostic in the log, and the ramdisk's
   `linkerconfig/` directory is empty (no `ld.config.txt` anywhere in the
   ramdisk or in `system.img`'s own `/linkerconfig/`), and
   `system/etc/linker.config.pb` is present as the generation source.
   But `sh` survives the same warning, so the warning alone does not
   explain an init-only abort. Treat generating `ld.config.txt` as
   worth trying (see S1) but do not assume it fixes init.

## Suggested next experiments (in order; A owns the ramdisk)

- **S1 — Generate `ld.config.txt`.** Use the AOSP `linkerconfig` tool
  against `system/etc/linker.config.pb` (plus apex info) to produce
  `/linkerconfig/ld.config.txt` in the ramdisk, then re-run this harness
  (`run-boot.sh --kernel …/Image-qemu-virt --initrd …/ramdisk.cpio.gz`).
  Evidence needed: either init progresses past line 283's abort, or the
  abort is unchanged (which would exclude S1 definitively).
- **S2 — Find init's abort site.** The abort happens before any `init:`
  kmsg line, i.e. inside `main()` before `InitKernelLogging` completes, or
  in an early `CHECK`/`LOG(FATAL)`. Instrument by running init under a
  minimal `rdinit` shell wrapper in a *copy* of the ramdisk that sets
  `LD_DEBUG=1` / redirects stderr, or by adding `init` debug output via a
  rebuilt init. Do not guess further from the serial log alone: the log
  contains no init-side message to distinguish sepolicy load, property
  setup, or fstab parsing failures.
- **S3 — Compare against a known-good first-stage ramdisk.** Build the
  ramdisk the AOSP way (`out/target/product/<virtual-device>/ramdisk.img`
  from the matching android17 virtual-device build that produced
  `initramfs.img`) instead of hand-assembling from GSI files, and diff
  its file list against the current ramdisk. In particular check for
  files the GSI-based assembly may lack entirely (e.g. generated
  linker config, `first_stage_ramdisk` marker semantics, apex payloads).
- **S4 — fstab is UNTESTED, not wrong.** The fstab (`/dev/block/vda` →
  `/system`, vdb → `/data`, vdc → `/metadata`, `first_stage_mount`) has
  never been exercised because init dies first. Its main untested
  assumption (per A's own comments in the fstab) is whether fs_mgr's
  `wait` resolves whole-disk `/dev/block/vda` nodes with no partition
  table / by-name symlinks. Revisit only after init survives; do not
  rework the fstab to chase the current abort.

## Notes for B (integration pipeline)

- B's bundle WAS boot-tested by this harness after it stabilized
  (04:41–04:42 rebuild): see `BOOT-RESULT.md` runs 6–8. As packaged it
  cannot boot (B `boot.img` is kernel-only; B `ramdisk.img` is the
  modules-only initramfs); with A's ramdisk substituted it reaches the
  same init abort as the plain GSI image. B should package A's
  first-stage ramdisk (not the modules initramfs) into/ alongside the
  bundle before any further boot claim.
- B's 04:33 bundle manifest itself states `real_apks_verified: false`
  and labels the bundle `dummy-test` (Agent APK 359 bytes). Even a
  successful boot of that bundle would prove the pipeline + ramdisk only,
  not real apps. The init abort in S-blocker applies to that bundle too,
  since it uses the same kernel + ramdisk.
- Cmdline used by this harness (kept identical across all runs except
  the two diagnostics): `console=ttyAMA0,115200
  androidboot.console=ttyAMA0 androidboot.hardware=qemu
  androidboot.selinux=permissive androidboot.verifiedbootstate=orange
  androidboot.vbmeta.device=none printk.devkmsg=on`. No cmdline/fstab/disk
  change is proposed as a fix for the current abort: the abort is in
  init's early startup, before first-stage mount parsing.
