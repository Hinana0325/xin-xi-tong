# EXPERIMENT.md — Minimal PIE discriminator: is the GSI init SIGABRT an
# environment fault or init-specific?

Task: distinguish only, do not repair. Only `~/workspace/minimal-pie/`
was written. All other directories were read-only; the original
ramdisk and GSI zip hashes were verified at start AND end (see §6).
QEMU virt only, no real device, no push, no WorkBuddy, no credits.
Android did NOT boot in any run. Init was NOT fixed. The diagnostic
ramdisks here are NOT boot images.

## 1. Question (from `~/workspace/init-debug/DIAGNOSIS.md`)

GSI `init` aborts with SIGABRT (exit 134) after the dynamic linker
jumps to `_start`, before printing any init log. Two sub-stages could
not be separated from the diag5 trace:

- (a) libc runtime startup between `_start` and `main()` (IFUNC/TLS/
  `__libc_init`, auxv/`AT_SECURE`, empty `/proc/bootconfig`), vs
- (b) `main()`'s earliest statements before logging is set up
  (a `CHECK`/`LOG(FATAL)` whose message goes nowhere).

Distinguishing experiment: run a trivial PIE linked against the same
bootstrap libc, via rdinit, in the same environment. If it also aborts,
the fault is in the startup environment; if it runs, the fault is
init-specific.

## 2. Toolchain inventory (read-only, no apt used)

- Host `clang`: NOT installed (`clang: command not found`).
  `aarch64-linux-gnu-gcc`: NOT installed. No apt attempt was needed.
- Kernel prebuilt clang exists under
  `~/workspace/kernel-android17-6.18/prebuilts/clang/host/` but was
  NOT used (it targets kernel builds, no Android sysroot).
- **Used: NDK r27** (already present, read-only, in the kernel tree):
  `prebuilts/ndk-r27/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android35-clang`
  — `Android (12027248, ...) clang version 18.0.1`, target
  `aarch64-unknown-linux-android35`. Full version string in
  `build-log.txt`. The GSI is Android 17 (API 37); NDK r27 tops out
  at API 35. This API gap is a stated confound (§5) — mitigated by
  keeping the program to 4 libc symbols, all verified present in the
  GSI libc (§3).

## 3. Binaries built (sources + readelf archived in `build-log.txt`)

### 3a. `minimal-pie` — libc-linked discriminator (SHA-256 `7e863fa5…370f0e`)

Source: `minimal.c` — `main()` writes `MINPIE-MARKER` to fd 1 and fd 2
via `write()`, returns 42. No stdio, no heap.

Build: `aarch64-linux-android35-clang -O2 -fPIE -pie minimal.c -o minimal-pie`
(normal NDK bionic link — no `-nostdlib`, no custom linker script).

readelf (verbatim in `build-log.txt`):
- INTERP: `/system/bin/linker64` — the same interpreter as init.
- NEEDED: `libdl.so`, `libc.so`; FLAGS `BIND_NOW`, `NOW PIE`.
- Undefined dynamic symbols (only 4): `__libc_init@LIBC`,
  `__cxa_atexit@LIBC`, `__register_atfork@LIBC`, `write@LIBC`.
- Each of the 4 was verified defined (`@@LIBC`) in the GSI bootstrap
  `libc.so` extracted read-only via `debugfs` from a copy of
  `system.img` (`work/gsi-libs/libc.so`, BuildID
  `b3e08ec972342dd240b38b5879fd54f0`; also extracted `libdl.so`,
  `libm.so`, `linker64` for inspection only — none was modified).

### 3b. `control-pie` — syscall-only control group (SHA-256 `953bc4b5…34ef55`)

Source: `control.S` — `_start` issues raw syscalls: `write(1,
"CONTROL-MARKER\n")` then `exit_group(42)`. No libc. (Note: the link
still emitted an INTERP segment requesting `/system/bin/linker64`
with zero NEEDED libraries, so this control tests exec + linker entry
+ raw syscalls, not a fully static binary. Documented so the control's
reach is not overstated.)

Build: `aarch64-linux-android35-clang -c control.S -o control.o`,
then `aarch64-linux-android35-clang -nostdlib -Wl,-e,_start -o control-pie control.o`.

## 4. Runs (copies only; `~/workspace/bootable-test/run-boot.sh` harness)

Diagnostic ramdisks were built by unpacking a COPY of
`bootable-ramdisk/ramdisk.cpio.gz` in `work/ramdisk-tree/`, replacing
the `/init` symlink with a wrapper script (diag5 pattern: premount
proc/sys/dev-tmpfs + console/null/kmsg nodes), adding the two
binaries, and repacking (newc cpio + gzip). Caveat: the `/dev` device
nodes in the original cpio could not be extracted in this container
(`cpio: Cannot mknod: Operation not permitted`, same as init-debug);
the wrapper recreates console/null/kmsg itself, as diag5 did. The
repacked ramdisks are `diag-minpie.cpio.gz` (SHA-256
`c21a704c…ba82bc20`) and `diag-minpie-lddebug.cpio.gz` (SHA-256
`248e8fff…1af2a`). Kernel: copy of `bootable-ramdisk/Image-qemu-virt`;
system.img: copy of `qemu-boot/system.img` (readonly virtio-blk).
Cmdline: the harness default (console=ttyAMA0, selinux=permissive,
verifiedbootstate=orange, vbmeta.device=none). Each run exited on its
own (wrapper exit → kernel panic `exitcode=0x00000000`, i.e. PID 1
exiting normally — NOT a crash); no watchdog kill, no reboot loop.

### Run 1 — `logs/run1/serial.log` (337 lines), both programs, no LD_DEBUG

```text
[    2.930251] Run /init as init process
MINPIE-WRAPPER-START
MINPIE-PROC:0
MINPIE-SYS:0
MINPIE-DEV:0
MINPIE-NODES-DONE
MINPIE-RUN-CONTROL
CONTROL-MARKER
MINPIE-CONTROL-EXIT:42
MINPIE-RUN-MINIMAL
MINPIE-MARKER
MINPIE-MARKER
MINPIE-MINIMAL-EXIT:42
MINPIE-WRAPPER-DONE
[    5.325244] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
```

Zero `Fatal signal` lines. Both programs printed their markers and
exited 42. The minimal PIE reached `main()`, ran `write()` twice
(fd 1 and fd 2), and returned normally through libc exit handling.

### Run 2 — `logs/run2/serial.log` (645 lines), minimal PIE with `LD_DEBUG=calls,dynamic`

Confirms run 1's minimal PIE really loaded the GSI bootstrap libc
(extracted trace in `lddebug-trace-minpie.txt`, 322 lines):

```text
linker: [ Linking "/system/lib64/bootstrap/libc.so" ]
linker: [ finished linking /system/lib64/bootstrap/libc.so ]
linker: [ Ready to execute "/minimal-pie" @ 0x557d57e680 ]
linker: [ Jumping to _start (0x557d57e680)... ]
MINPIE-MARKER
MINPIE-MARKER
MINPIE2-MINIMAL-EXIT:42
```

Same `_start` jump that precedes init's abort, followed here by
normal execution. No `Fatal signal` line anywhere in the log.

## 5. Conclusion — init-specific, NOT a startup-environment fault

**The SIGABRT is init-specific (stage (b)).** A minimal PIE using the
same interpreter (`/system/bin/linker64`), the same bootstrap
`libc.so`, the same rdinit wrapper, the same premounts, and the same
cmdline reaches `main()`, prints, and exits 42 — twice, once with a
full `LD_DEBUG` trace proving the bootstrap libc was the one loaded.
Therefore libc runtime startup in this environment works: IFUNC/TLS/
`__libc_init`, auxv handling, the bare `bootconfig` cmdline token,
and the empty `/proc/bootconfig` do NOT abort a normal bionic
program here. The fault lies in something init does (or links)
between `_start` and its first log line — e.g. an early `CHECK`/
`LOG(FATAL)`, a property/sepolicy/fstab access that aborts before
logging is initialised, or an init-only dependency (its other 25
libraries beyond the bootstrap three were NOT exercised by the
minimal program).

Honest limits / confounds:
- The minimal program exercises only the bootstrap libc closure
  (`libc.so`/`libdl.so`/`libm.so`). Init's other 25 libraries
  (libselinux, libbase, libfs_mgr, libc++, …) were not loaded here;
  a fault in one of those libraries' constructors is still possible
  but would be init-specific in the same sense (diag5 already showed
  init's own 9 `DT_INIT_ARRAY` ctors completing, which covers the
  directly-linked closure's constructors).
- NDK API 35 vs GSI API 37: only 4 symbols were needed and all 4
  resolve in the GSI libc; no version-mismatch symptom appeared
  (no `CANNOT LINK` / version errors in either trace).
- `strace` remains unavailable for this target (x86_64 host strace
  cannot trace ARM64); not re-chased.
- The final kernel panic in both runs is the expected
  PID-1-wrapper-exited panic (`exitcode=0x00000000`), not a crash.

## 6. Compliance re-verification

- GSI zip SHA-256, start and end:
  `a359a50b6eb8e9f63168e928bd14167603225e92cd8605ec86a4bda6591fc13b`
  (unchanged).
- Original ramdisk SHA-256, start and end:
  `a50640cfbb0522dd1a014cf891a7413b45858feffdc2a83745ab8e0aa21b716c`
  (unchanged — only copies were unpacked/repacked).
- No QEMU process left running. No other directory written.

## 7. Next-step proposal (ONE, based on the conclusion)

**Attach QEMU's gdb stub and break at init's `main`, or rebuild init
with an `fprintf(stderr)` at the top of `main()`** — precise operation
for the next task:

1. Rebuild a diagnostic ramdisk copy as here, but with `/init`
   replaced by a wrapper that runs the REAL `/system/bin/init` under
   the same premounts (no LD_DEBUG needed).
2. Start QEMU with `-gdb tcp::1234 -S`, attach the host
   `aarch64-linux-gnu-gdb` (or the NDK/prebuilt gdb — record which
   is available first; do not apt-install blindly), set a breakpoint
   at `main` using init's unstripped symbols
   (`/system/bin/init` is not stripped per the extraction notes),
   `continue`, and single-step / break at each early call until the
   aborting statement is identified. If no gdb is available, fall
   back to rebuilding `init` from the matching AOSP
   `android17-6.18-2026-06_r68` source with `fprintf(stderr, …)`
   markers at `main()` entry and before each early step
   (`InitKernelLogging`, property init, sepolicy load, fstab load).
3. Do NOT pursue auxv/`AT_SECURE` or bootconfig-blob work first:
   run 1/run 2 prove those inputs do not abort a normal program in
   this environment. Do NOT hand-write `ld.config.txt` either
   (already excluded by init-debug). After the aborting statement
   is known, the fix target is that statement's precondition
   (missing file, property, or sepolicy form) — do not guess it
   before the breakpoint/printout evidence exists.

## 8. Deliverables in `~/workspace/minimal-pie/`

- [EXPERIMENT.md](sandbox://workspace/minimal-pie/EXPERIMENT.md) — this file
- [minimal.c](sandbox://workspace/minimal-pie/minimal.c) / [control.S](sandbox://workspace/minimal-pie/control.S) — sources
- [minimal-pie](sandbox://workspace/minimal-pie/minimal-pie) / [control-pie](sandbox://workspace/minimal-pie/control-pie) — built binaries
- [build-log.txt](sandbox://workspace/minimal-pie/build-log.txt) — toolchain version, build commands, readelf output, symbol checks, hashes
- [diag-minpie.cpio.gz](sandbox://workspace/minimal-pie/diag-minpie.cpio.gz) / [diag-minpie-lddebug.cpio.gz](sandbox://workspace/minimal-pie/diag-minpie-lddebug.cpio.gz) — diagnostic ramdisk copies (NOT boot images)
- [logs/run1/serial.log](sandbox://workspace/minimal-pie/logs/run1/serial.log) / [logs/run2/serial.log](sandbox://workspace/minimal-pie/logs/run2/serial.log) — full serial logs
- [lddebug-trace-minpie.txt](sandbox://workspace/minimal-pie/lddebug-trace-minpie.txt) — run 2 LD_DEBUG trace extract
- `work/` — GSI lib extracts (`gsi-libs/`), ramdisk tree, run inputs
