# DIAGNOSIS.md — GSI init SIGABRT crash-point location (locate only, no fix applied)

Task: locate, do not repair. Only `~/workspace/init-debug/` was written.
`~/workspace/bootable-ramdisk/` originals untouched (ramdisk SHA-256
re-verified `a50640cfbb0522dd1a014cf891a7413b45858feffdc2a83745ab8e0aa21b716c`).
GSI zip SHA-256 verified at start AND end:
`a359a50b6eb8e9f63168e928bd14167603225e92cd8605ec86a4bda6591fc13b`.
QEMU virt only, no real device, no push, no WorkBuddy, no credits.
Android did NOT boot in any run in this task. The crash was NOT fixed.

Inputs read first: `~/workspace/bootable-ramdisk/RAMDISK.md` §6,
`~/workspace/bootable-test/SUGGESTIONS.md` (S1–S3),
`~/workspace/bootable-test/BOOT-RESULT.md` (8 runs).

## 1. Verdict — crash point, with evidence

**The abort happens AFTER the dynamic linker finishes and jumps to
`_start`, i.e. inside `init`'s own early execution (libc runtime startup
through `main()`'s first statements, before any init log output). It is
NOT in linker loading, NOT in a static constructor, NOT in symbol
resolution.**

Decisive evidence — `diag5-serial.log`, LD_DEBUG trace
(`lddebug-trace.txt`, 3,020 lines, init run as a child of an rdinit
wrapper with stdout/stderr captured to a file, then printed via toybox):

```text
linker: [ Done calling DT_INIT_ARRAY for '/system/bin/init' ]
linker: [ Ready to execute "/system/bin/init" @ 0x557db64000 ]
linker: [ Jumping to _start (0x557db64000)... ]
libc: Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 67 (init), pid 67 (init)
Aborted
```

- All 9 `DT_INIT_ARRAY` constructors of `/system/bin/init` (indices 0–8)
  printed `Done calling c-tor function` — none aborted mid-constructor.
- All 29 libraries in the transitive closure linked successfully
  (bootstrap `libc.so`/`libdl.so`/`libm.so` + 26 others incl. `libfs_mgr`,
  `libselinux`, `libbase`, `libc++`); the trace contains **0** lines
  matching `CANNOT LINK` / `undefined symbol` / `failed to load`.
- The child exited **134** (`WRAPPER5-INIT-EXIT:134`, = 128+6, SIGABRT),
  reproducing the PID-1 `Fatal signal 6` in a non-PID-1 configuration.
- Between `Jumping to _start` and the abort, init printed **nothing** —
  no `init:` log line, no stderr message of its own. The only post-jump
  output is libc's fatal-signal line.

## 2. Static checks (on a copy of the ramdisk, `extract/`)

- `DT_NEEDED`: 18 libraries, `BIND_NOW` set. `symbol-check.py`
  (kept here) resolves init's 557 undefined symbols against the closure:
  after accounting for libc's `GNU_IFUNC`/`<OS specific>` definitions
  (`memcpy`, `memset`, `__strchr_chk`, … are defined in
  `system/lib64/bootstrap/libc.so`), the only unresolved symbols are
  three **WEAK** undefined ones — `_Z9backtracePPvi`, `__gcov_dump`,
  `__gcov_flush` — which resolve to null and cannot abort at load time
  under `BIND_NOW` unless called. **No required symbol is missing.**
  Interpreter: `/system/bin/bootstrap/linker64`. No RUNPATH/RPATH.
- `sepolicy` in the ramdisk is **CIL text** (3,418,955 B, starts
  `(role object_r)`), a verbatim copy of the GSI's
  `/system/etc/selinux/plat_sepolicy.cil`. The GSI contains **no**
  `precompiled_sepolicy` binary in `/system/etc/selinux/`. Whether init
  accepts CIL text at `/sepolicy` is **untested — the crash happens
  before any sepolicy load is observable**, so this remains an open
  candidate for the *next* stage, not evidence for this crash.
- Linkerconfig source exists: `/system/etc/linker.config.pb` (1,701 B)
  in the GSI; `/linkerconfig/` is empty in the ramdisk and in the GSI;
  the runtime APEX (`/system/apex/com.android.runtime.apex`, which
  contains the `linkerconfig` binary) is present in the image but
  `/apex/` is empty in the ramdisk. `init`'s strings show it mounts a
  tmpfs on `/linkerconfig` and runs
  `/apex/com.android.runtime/bin/linkerconfig` — i.e. linkerconfig
  generation is a *later* init step, after the crash point.
- `strings` on init confirm the fstab search order
  (`/first_stage_ramdisk/fstab.*`, `/system/etc/fstab.*`,
  `/vendor/etc/fstab.*`, `/fstab.*`), `/proc/bootconfig` handling, and
  `/dev/__properties__` / `/sepolicy` paths. None of these is reached
  in the logs.
- Kernel config (QEMU-virt dist `.config`, read-only): `CONFIG_DEVTMPFS
  is not set`, `CONFIG_BOOT_CONFIG=y`, built-in cmdline ends with the
  bare token `bootconfig` and no bootconfig blob is supplied. Whether
  an empty `/proc/bootconfig` aborts init is **unproven and untested** —
  it is a candidate for the post-`_start` stage, not established.
- Ramdisk-vs-expectation diff: present — init, linker, 33 libs,
  sepolicy CIL, init rc files, `init.environ.rc`, `fstab.qemu`
  (identical copies at `/fstab`, `/fstab.qemu`,
  `/first_stage_ramdisk/fstab{,.qemu}`), `linker.config.pb`,
  `/dev` nodes (in the original cpio only). Missing vs a normal
  first-stage ramdisk — `/linkerconfig/ld.config.txt`, any `/apex/*`
  payload, `ueventd.rc` (only present in the image at
  `/system/etc/ueventd.rc`; first-stage init reads it after mounting
  system — unreached), vendor files (none exist in the GSI).
  The virtual-device `initramfs.img` (303 cpio entries) is modules-only
  and contributes nothing to this diff.
- `strace`: **not available** for this target — no `strace` in the GSI
  or ramdisk; the host's `/usr/bin/strace` is x86_64 and cannot trace
  an ARM64 binary. Not used; recorded so it is not re-chased.

## 3. Dynamic runs in this task (copies only, 10-min no-progress cap each)

| Run | Wrapper / setup | Result |
|---|---|---|
| diag1 | rdinit child, `LD_DEBUG=1` (invalid value), no premounts | **Invalid experiment.** Child exit 1, empty stderr file, no fatal-signal line. `LD_DEBUG=1` is not a valid value (see diag2): the linker prints usage and exits before running init. Discard any conclusion from this run except the trap itself. |
| diag2 | rdinit, premount proc/sys/dev+nodes, `exec init`, `LD_DEBUG=1` | Same trap: linker printed the `$LD_DEBUG is a comma-separated list…` usage text, then kernel panic `exitcode=0x00000100` (exit_group(1) — the linker exiting, not init aborting). Premount effect **not** measured by this run. |
| diag3 | rdinit child, `LD_DEBUG=all`, premounts | Timed out at 90 s (TCG + full relocation tracing). No result; discarded. |
| diag4 | rdinit child, `LD_DEBUG=calls,dynamic`, premounts, `cat` missing (toybox applets not symlinked) | Child exit **134** (SIGABRT reproduced with premounts + valid LD_DEBUG). The trace was trapped in `/init-out.log` and unreadable (`cat: inaccessible or not found`). |
| diag5 | Same as diag4, but trace printed via `/system/bin/toybox cat` | **Decisive run.** Exit 134; full 3,020-line trace recovered (see §1). |

Premounting `/proc`+`/sys`+`/dev` (tmpfs + `console`/`null`/`kmsg`
nodes) does **not** change the crash: diag4/diag5 abort identically to
the no-premount PID-1 runs. Combined with the earlier exclusions
(SELinux-disabled identical abort; original vs integrated system.img
identical abort; `sh` via rdinit reaches a prompt), the crash is
init-specific and post-`_start`.

## 4. Excluded candidates (evidence-backed, do not re-chase)

1. Missing library / missing required symbol / `BIND_NOW` load failure
   (§1 trace + §2 symbol check).
2. Static-constructor (`DT_INIT_ARRAY`) failure (§1: all 9 complete).
3. Missing `/dev` nodes, missing `/proc`/`/sys` mounts (§3 diag4/diag5
   + earlier diagnostics).
4. SELinux cmdline flag, system.img variant (earlier 8-run harness).
5. Generic dynamic-linker / bootstrap-libc breakage (`sh` runs; 29
   libraries link; libc loads from `bootstrap/` even with no
   `ld.config.txt`).

## 5. What is NOT distinguished (honest boundary)

The trace ends at the `_start` jump, so these two sub-stages cannot be
separated from this evidence:

- (a) libc runtime startup between `_start` and `main()` (e.g. IFUNC
  resolution, TLS/`__libc_init`, auxv/`AT_SECURE` handling), vs
- (b) `main()`'s earliest statements before `InitKernelLogging`/any
  `LOG()` output (e.g. a `CHECK`/`LOG(FATAL)` abort with its message
  going nowhere because logging is not yet set up).

Distinguishing experiment (not run here — needs a new task):
run a trivial PIE linked against the same bootstrap libc via rdinit
that prints a marker and exits 0. If it also aborts, the fault is in
the libc/startup environment; if it runs, the fault is init-specific
and the next step is a rebuilt init with an `fprintf(stderr)` at the
top of `main()` (or a QEMU gdb stub break at `main`) to find the
failing statement. Do NOT hand-write `ld.config.txt` as the first
fix: the linker already resolves the full closure without it, and a
malformed config breaks every process.

## 6. Concrete fix proposal (NOT applied anywhere)

1. **Discriminator first** (cheap, one QEMU run): trivial test binary
   against the ramdisk's bootstrap libc, via an rdinit wrapper copy in
   a new directory. Record exit code + any output.
2. **If init-specific:** rebuild `init` from the matching AOSP
   `android17-6.18-2026-06_r68` source with debug output at `main()`
   entry and before each early step (`InitKernelLogging`,
   `SetupSelinux`, fstab load), or attach via QEMU `-gdb` and break
   at `main`. The failing step is the fix target; do not guess.
3. **If libc/environment:** inspect auxv/`AT_SECURE` and the
   `bootconfig`-less cmdline as the startup inputs; test with a
   bootconfig blob or a cmdline without the bare `bootconfig` token
   (kernel rebuild / `CONFIG_CMDLINE` change — parent decision).
4. **After init survives:** only then generate
   `/linkerconfig/ld.config.txt` with the AOSP `linkerconfig` tool
   from the GSI's `linker.config.pb` + runtime APEX, test the CIL
   `/sepolicy` form (compile with the GSI's `secilc` if init rejects
   CIL text), and validate the hand-written `fstab.qemu` (whole-disk
   `/dev/block/vda` + `wait` semantics — never exercised).

## 7. Deliverables in `~/workspace/init-debug/`

- [DIAGNOSIS.md](sandbox://workspace/init-debug/DIAGNOSIS.md) — this file
- [diag5-serial.log](sandbox://workspace/init-debug/diag5-serial.log) — decisive run (3,347 lines)
- [lddebug-trace.txt](sandbox://workspace/init-debug/lddebug-trace.txt) — extracted LD_DEBUG trace (3,020 lines)
- [diag5.cpio.gz](sandbox://workspace/init-debug/diag5.cpio.gz) — diagnostic ramdisk copy (SHA-256 `94e7401195bcafb9c76e442f7db8cd74d4ad65491d843e39f7bf1ee029182e58`), wrapper + premounts + `LD_DEBUG=calls,dynamic`; **not** a boot image
- [diag1–diag4 serial logs + cpio.gz](sandbox://workspace/init-debug/) — earlier/confounded runs, kept for audit; diag1/diag2 are invalid (see §3)
- [symbol-check.py](sandbox://workspace/init-debug/symbol-check.py) — symbol-closure checker used in §2
- [extract/](sandbox://workspace/init-debug/extract/) — unpacked copy of the original ramdisk (read-only use)
- [ramdisk-copy.cpio.gz](sandbox://workspace/init-debug/ramdisk-copy.cpio.gz) — verbatim copy of the original ramdisk
- [work/](sandbox://workspace/init-debug/work/) — kernel Image copy, system.img copy, userdata/metadata images used by the runs
