# GDB-SESSION.md — QEMU gdb stub localisation of the GSI init SIGABRT

Task: locate the abort statement with QEMU's gdb stub only. Only
`~/workspace/gdb-init/` was written; every other directory was
read-only. QEMU virt only, no real device, no push, no WorkBuddy,
no credits. Time box: 90 minutes, 6 sessions. **Android did NOT
boot; init was NOT fixed.** Diagnostic ramdisk copies are NOT boot
images.

## 1. Verdict — what was located, and what was not

**Located (evidence-backed):** the SIGABRT is raised by init itself,
in its early `main()` path, through the normal bionic
`raise()`/`abort()` mechanism: userspace issued syscall 240
(`rt_tgsigqueueinfo`) with `SIGABRT` (6) and an explicit siginfo
(`si_code = -1`, `SI_QUEUE`), for tgid = tid = 1 (PID 1). The kernel
call chain captured live is:

```text
__arm64_sys_rt_tgsigqueueinfo+0x9c  (bl do_send_specific, return 0xffffffc0804da474)
  -> do_send_specific               (0xffffffc0803ac060)
    -> do_send_sig_info             (0xffffffc080067e40, sig=6, si_code=-1)
```

**NOT located:** the exact userspace PC / init function / source
statement that called `raise()`/`abort()`. The userspace return
address (ELR) lives in the syscall's `pt_regs` on the kernel stack
and was not dumped in any session. No claim is made about which
`CHECK`/`LOG(FATAL)` in `main()` fired. Do not present this as
"the abort statement was found" — the mechanism and syscall were
found; the statement was not.

## 2. Tool inventory (step 1)

- No aarch64 gdb on the machine at start: `gdb`, `gdb-multiarch`,
  `aarch64-linux-gnu-gdb`, `aarch64-linux-android-gdb` all absent
  (`command -v` found none; only unrelated `gdbus`).
- NDK r27 (in the kernel tree, read-only) ships `lldb`, but it
  fails to start: `libpython3.11.so.1.0: cannot open shared object
  file` (host has Python 3.12). LLDB was not used.
- **One apt attempt (as allowed):** `apt-get install -y
  gdb-multiarch` succeeded in ~7 s from the azure mirror:
  `gdb-multiarch 15.1-1ubuntu1~24.04.1` (GNU gdb 15.1). This is a
  system (ephemeral) install, not a workspace change.
- QEMU: `qemu-system-aarch64` 8.2.2, gdb stub via `-S -gdb
  tcp::1234 -no-reboot`, guest `virt`/`cortex-a57`/2 vCPU/2 GiB/TCG.
- Init binary: `/system/bin/init`, 2,653,128 B, ELF PIE, **stripped**
  (no `.symtab`, no `.debug`, `main` absent from `.dynsym`).
  It DOES carry a `.gnu_debugdata` section (xz-compressed, 60,160 B;
  decompressed copy saved as `symbols/init-gnu_debugdata.elf`,
  symbol list in `symbols/init-symbols.txt`): 3,228 function
  symbols, including `main` at file offset `0x76e74` and `_start`
  at `0x70000`. A breakpoint at `main` **by name is impossible**
  with this binary; an address breakpoint needs the runtime load
  base, which ASLR randomises per boot (see §3).

## 3. Why the naive breakpoint approach failed (3 sessions)

- **Session 1** (`session1/`): software breakpoints at System.map
  link addresses (`el0_svc`, `__arm64_sys_tgkill`) with
  register-based conditions on `$x8`/`$x2`. Guest booted and
  aborted identically (serial: `Run /init`, `Fatal signal 6`),
  breakpoints never fired. Cause: **KASLR** — the serial log's
  `Kernel Offset` differs on (almost) every boot
  (0x19c7e00000, 0x234fa00000, 0x14a1800000, 0xfb4400000, … in
  prior logs), so link addresses are not where the kernel runs.
  Kernel config has `CONFIG_RANDOMIZE_BASE=y`.
- **Session 2** (`session2/`): hardware breakpoints (`hbreak`,
  DBGBVR) + `nokaslr` on the cmdline (serial confirms
  `Kernel Offset: disabled`), same register conditions, now
  with corrected syscall numbers for `kill`/`tgkill` — still no
  hit. Two compounding errors, found only later (see §4).
- **Session 3** (`session3/`): corrected syscall numbers from
  `common/include/uapi/asm-generic/unistd.h` — the decisive
  correction is `__NR_rt_tgsigqueueinfo = 240` (not 134;
  134 is `rt_sigaction`), `__NR_rt_sigqueueinfo = 138`,
  `__NR_kill = 129`, `__NR_tkill = 130`, `__NR_tgkill = 131`.
  Still no hit. The remaining error was the register assumption
  (§4).
- **Session 4** (`session4/`): unconditional `hbreak` at `el0_svc`
  with breakpoint commands printing every 500th hit and
  auto-continuing. **Proved hardware breakpoints DO fire**
  under this QEMU/TCG stub: 2,000+ hits logged, guest still
  aborted. No `x8 == 240` hit was recorded — but that check
  read `$x8` at the `el0_svc` C-function entry, where it is
  invalid (§4), so session 4 does not prove "no 240 syscall".

## 4. The `el0_svc` register trap (why sessions 1–4 could not work)

`el0_svc` (`0xffffffc081396e30`, `t` in System.map) is a **C
function**, not the exception-vector entry. Its disassembly
(vmlinux, verified) starts:

```text
ffffffc081396e30: paciasp
ffffffc081396e34: stp x29, x30, [sp, #-0x20]!
ffffffc081396e40: mov x19, x0          ; x0 = struct pt_regs *
ffffffc081396e44: mrs x20, SP_EL0
...
ffffffc081396e68: bl do_el0_svc
```

At the breakpoint, `$x0` is a `pt_regs` pointer and `$x8` is a
caller-saved scratch register — **not** the syscall number and
**not** the syscall arguments. The syscall number and arguments
live in `pt_regs` memory:

```c
struct pt_regs {          /* arch/arm64/include/asm/ptrace.h */
  u64 regs[31];   /* @0..248 */
  u64 sp;         /* @248 */
  u64 pc;         /* @256 */
  u64 pstate;     /* @264 */
  u64 orig_x0;    /* @272 */
  s32 syscallno;  /* @280 */
  ...
};
```

Sessions 1–4 conditioned on `$x8`/`$x2`, so they could never
match a kill-family syscall even though the breakpoints were
correctly placed (session 4 proves placement works). Any future
`el0_svc` filtering must read `pt_regs` memory
(`*(int*)($x0 + 280)` for the syscall number,
`*(long*)($x0 + 0/8/16)` for args, `+256` for ELR,
`+248` for the userspace SP, `+240` for the userspace LR).

## 5. The capture (sessions 5–6)

- **Session 5** (`session5/`): breakpoint at `do_send_sig_info`
  (`0xffffffc080067e40`, `T` in System.map) with condition
  `$x0 == 6` (its first C argument is the signal number). It
  **hit**, but the recording section wrongly assumed `$x0` was
  a `pt_regs` pointer (`$x0` was 6, the signal number), errored,
  gdb exited, and the runner killed QEMU mid-boot — serial log
  ends at the linker warning, before the abort print. Kept as
  evidence that the delivery breakpoint works; the guest was
  frozen before delivery completed.
- **Session 6** (`session6/`): same `do_send_sig_info`
  breakpoint, corrected recording. Captured verbatim
  (`gdb-transcript.txt`, "STOPPED (do_send_sig_info sig==6)"):

```text
$1 = PC = 0xffffffc080067e40 (do_send_sig_info)
$2 = sig  = 0x6
$3 = info = 0xffffffc082b0bde8
$4 = task = 0xffffff8003143780
$5 = type = 0x0
siginfo @ info: 0x00000006 0x00000000 0xffffffff   ; signo=6, errno=0, code=-1 (SI_QUEUE)
x30 (return) = 0xffffffc0803ac12c
  0xffffffc0803ac128: bl do_send_sig_info
  0xffffffc0803ac12c: cmn w0, #0x3
```

  Frame chain from the kernel stack dump in the same transcript:

```text
0xffffffc082b0bdb0: 0xffffffc082b0be20  0xffffffc0804da474   ; frame ptr, LR -> __arm64_sys_rt_tgsigqueueinfo+0xa0
0xffffffc082b0bdc0: 0x0000007f85e9611c  0x0000000000000006   ; userspace VA (uinfo ptr), sig 6
0xffffffc082b0bdd0: 0x0000000000000001  0x0000000000000001   ; tgid=1, tid=1
0xffffffc082b0bde0: 0xffffff807fb2e028  0x0000000000000006
0xffffffc082b0bdf0: 0x00000000ffffffff  0x0000000000000001   ; si_code=-1, ...
0xffffffc082b0be20: 0xffffffc082b0be50  0xffffffc0800c2474   ; next frame -> do_el0_svc area
0xffffffc082b0be70: 0xffffffc082b0be90  0xffffffc081396e6c   ; el0_svc+0x3c (bl do_el0_svc)
0xffffffc082b0be90: 0xffffffc082b0beb0  0xffffffc081396d84
```

  Offline verification (vmlinux disassembly): the LR
  `0xffffffc0804da474` is the instruction immediately after
  `bl do_send_specific` at `0xffffffc0804da470` inside
  `__arm64_sys_rt_tgsigqueueinfo` (`0xffffffc0804da3d4`–
  `0xffffffc0804da4b4`), which builds the siginfo on its stack
  (`add x3, sp, #0x8`) and calls `do_send_specific`. The
  userspace caller therefore invoked syscall 240 with
  SIGABRT for PID/TID 1 — the bionic `raise()`/`abort()` path.
  After `continue`, the guest printed the known
  `Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE)` line and
  panicked (serial.log), reproducing the original crash under
  the debugger. A second `do_send_sig_info` hit on CPU 1
  (Thread 2) appears at the end of the transcript (fatal
  handler re-raise path); it was not investigated further.

## 6. What this rules out / leaves open

Ruled out (with the earlier diagnoses): the abort is **not** a
kernel-generated signal, **not** a trap/`brk` fault, **not** a
linker/load failure, **not** a libc-startup environment failure
(minimal PIE ran). Init's own code deliberately raised SIGABRT
before printing any log — i.e. an early `CHECK`/`LOG(FATAL)`/
`abort()` in `main()`'s pre-logging path, or a failing
precondition in a library it calls that aborts the same way.

Still open: **which** statement. The ELR (userspace PC after the
SVC) and userspace stack were not captured. The userspace VA
`0x0000007f85e9611c` on the kernel stack is consistent with the
`uinfo` pointer argument, not an ELR; do not cite it as the
abort PC.

## 7. Precise next step (not done here)

Break at `__arm64_sys_rt_tgsigqueueinfo`
(`0xffffffc0804da3d4`) and, from the stopped kernel stack,
walk to the syscall's `pt_regs` (top of the current task's
kernel stack) to read ELR (`+256`), userspace SP (`+248`) and
LR (`+240`); dump the userspace stack at that SP and resolve
return addresses against `symbols/init-symbols.txt`
(`main` @ file offset `0x76e74`, `_start` @ `0x70000`) after
deriving the load base (ELR minus the file offset of the SVC
site in `libc.so`, or the load base printed by an `LD_DEBUG`
run of the same boot). Alternative, if that walk proves
impractical: rebuild `init` from the matching AOSP source
(`android17-6.18-2026-06_r68`) with `fprintf(stderr)` markers
at the top of `main()` and before each early step. Do NOT
hand-write `ld.config.txt` and do NOT chase auxv/bootconfig —
both were excluded by prior work.

## 8. Files in `~/workspace/gdb-init/`

- [GDB-SESSION.md](sandbox://workspace/gdb-init/GDB-SESSION.md) — this file
- `gdb-script.txt` — session 6 script (kept); `gdb-script-s123.txt`,
  `gdb-script-s4.txt`, `gdb-script-s5.txt`, `gdb-script-s6.txt` —
  scripts for sessions 1–3, 4, 5, 6 respectively
- `run-gdb-session.sh` — QEMU + gdb runner (copies only, `-S`,
  `-gdb tcp::1234`, `-no-reboot`, `nokaslr` from session 2 on)
- `session1/` … `session6/` — per-session `serial.log`,
  `gdb-transcript.txt`, `gdb-stdout.log`, `qemu-gdb.log`
  (session 5's serial log is truncated mid-boot by design of
  the failure described in §5; session 6's is complete)
- `symbols/` — `init-gnu_debugdata.elf` (decompressed
  `.gnu_debugdata`), `init-symbols.txt` (3,228 symbols),
  `kernel-symbols.txt` (System.map excerpts used)
- `work/` — copies only: `kernel-Image` (SHA-256
  `578080b9…aa278`, identical to the QEMU-virt dist Image),
  `ramdisk.cpio.gz` (SHA-256 `a50640cf…`, identical to the
  original), `system.img`, `metadata.img`, `userdata.qcow2`
  (fresh per session)

## 9. Compliance re-verification

- GSI zip SHA-256, start and end:
  `a359a50b6eb8e9f63168e928bd14167603225e92cd8605ec86a4bda6591fc13b`
  (unchanged).
- Original ramdisk SHA-256, start and end:
  `a50640cfbb0522dd1a014cf891a7413b45858feffdc2a83745ab8e0aa21b716c`
  (unchanged; only copies were used).
- No QEMU process left running. No other directory written.
  No `apt` use beyond the single `gdb-multiarch` install.
