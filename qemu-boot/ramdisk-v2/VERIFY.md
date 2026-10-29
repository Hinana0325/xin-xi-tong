# Lane B verification record

All verification was offline (no QEMU run, per lane constraints). The GSI zip
and the v1 ramdisk were re-checked unchanged at the end (see §4).

## 1. Stand-in run (pipeline correctness only)

Command (from `~/workspace/ramdisk-v2/`):

```sh
./assemble-ramdisk.sh \
  ~/workspace/init-debug/extract/system/bin/init \
  ~/workspace/init-debug/extract \
  test-output/ramdisk-standin.cpio.gz \
  ~/workspace/init-debug/extract/fstab.qemu
```

Result: exit 0. Interpreter `/system/bin/bootstrap/linker64`; dependency
closure 27 libraries; 185 cpio entries.

- Output: `test-output/ramdisk-standin.cpio.gz`
  SHA-256: `8bdbdac690f455a450b4484ce59b6797b3f8da2bbd9ede42e330739313c3f5f6`
- Manifest: `test-output/ramdisk-standin.cpio.gz.manifest.json`
  (185 entries, one SHA-256 per file entry).

**Stand-in warning (explicit):** the binary used here is the GSI
second-stage-only `init`. This run proves only that the script assembles a
well-formed ramdisk. If booted, this ramdisk is still expected to hit the
FATAL `Second-stage init requires an argument to main()` — no boot claim is
made or implied.

## 2. Independent cpio re-parse

The output was parsed back with an independent Python newc reader (not the
script's own writer):

- 185 entries (excluding `TRAILER!!!`), matching the manifest total.
- `/init` is a symlink (`0o120777`) to `/init_first_stage` — NOT to
  `/system/bin/init`.
- `/init_first_stage` SHA-256 is
  `bb702f17e6660ef8f2a1fd9158c2de876fa0c8f9679a7a49f4a2d02e1119451f`,
  identical to the GSI `system/bin/init` in the extract tree.
- Every file entry's SHA-256 in the manifest matches the bytes parsed out
  of the cpio: 0 mismatches.
- `/sepolicy` present (3,418,955 B); fstab present at `/fstab`,
  `/fstab.qemu`, `/first_stage_ramdisk/fstab`, `/first_stage_ramdisk/fstab.qemu`.
- 9 `/dev` character nodes present (console, null, zero, full, ptmx, tty,
  kmsg, random, urandom).

## 3. Dependency-closure completeness

Every ELF file in the ramdisk was extracted and `readelf -d` was run over
it: all `NEEDED` entries resolve to a basename present in the ramdisk
(`system/lib64` or `system/lib64/bootstrap`). Result: **0 unresolved
NEEDED** — closure complete for the stand-in binary. (The same check must
be re-run for the real WorkBuddy first-stage binary; its closure may differ.)

## 4. Reproducibility

A second run with identical inputs produced a byte-identical file
(`cmp` clean, same SHA-256 `8bdbdac6…`).

## 5. Negative tests (all must fail loudly, writing no output)

| Case | Result |
|---|---|
| Missing init binary path | `ERROR: init binary not found`, no output file |
| Missing fstab file path | `ERROR: fstab file not found`, no output file |
| Extract tree with only 1 of 18 needed libraries | exit 1, 17 `MISSING:` lines printed, no output file |

## 6. Hash re-verification (start and end of lane)

- GSI zip: `a359a50b6eb8e9f63168e928bd14167603225e92cd8605ec86a4bda6591fc13b`
  (unchanged; verified at lane start and again below at lane end).
- v1 ramdisk `~/workspace/bootable-ramdisk/ramdisk.cpio.gz`:
  `a50640cfbb0522dd1a014cf891a7413b45858feffdc2a83745ab8e0aa21b716c`
  (unchanged).
