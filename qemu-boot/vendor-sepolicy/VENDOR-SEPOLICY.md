# Minimal vendor sepolicy set — offline secilc verification

Date: 29 October 2026. GSI: Android 17 QPR3 Beta, build DP11.261002.005
(SDK 37), ARM64 without GMS. GSI zip SHA-256
`a359a50b6eb8e9f63168e928bd14167603225e92cd8605ec86a4bda6591fc13b`
(re-verified unchanged at start and end of this lane; see §7).

## 1. What was required, and why

Per `~/workspace/bootimg-sepolicy/SEPOLICY-READINESS.md` (AOSP
`platform/system/core`, `init/selinux.cpp`, main branch, blob
`2a27c1d…`, re-read in full for this lane — the exact compile
invocation was confirmed from `OpenSplitPolicy()`, lines 456–796 of
that file), first-stage init's `selinux_setup` on a split-policy
device compiles policy on-device with `/system/bin/secilc`. The
compile is only reached if all three of these exist:

| File (as seen by first-stage init) | Role |
|---|---|
| `/vendor/etc/selinux/plat_sepolicy_vers.txt` | First line = vendor mapping version; selects `/system/etc/selinux/mapping/<vers>.cil` (`GetVendorMappingVersion()`; missing/unreadable → `OpenSplitPolicy()` fails) |
| `/vendor/etc/selinux/vendor_sepolicy.cil` | Vendor CIL input (missing → error + fail) |
| `/vendor/etc/selinux/plat_pub_versioned.cil` | Versioned public platform policy input (missing → error + fail) |

The exact init-equivalent compile command (main branch) is:

```
secilc <plat_sepolicy.cil> -m -M true -G -N -c <SEPOLICY_VERSION> \
  <mapping/<vers>.cil> -o <out> -f /sys/fs/selinux/null \
  [<plat .compat.cil>] [<system_ext policy+mapping+compat>] \
  [<product policy+mapping>] [<plat_pub_versioned.cil>] \
  [<vendor_sepolicy.cil>] [<odm policy>] [<genfs cil>]
```

All three vendor files were absent from the GSI. This lane created
them and verified the compile offline. **What this does NOT prove:**
whether the first-stage init (still being built) accepts this set at
boot, whether the compiled policy loads into the 6.18 kernel, or
whether second-stage proceeds. Those need the first-stage binary and
a QEMU boot, and are explicitly out of scope here. Android has not
booted; nothing about boot is claimed.

## 2. The three files

All three live in `vendor-sepolicy/` in this directory (i.e. they are
to be installed at `/vendor/etc/selinux/` by the ramdisk/first-stage
lane). Contents are deliberately minimal; every statement is
accounted for below.

### `plat_sepolicy_vers.txt` (7 bytes)

```
202604
```

First line = mapping version. `202604` was chosen empirically: it is
the newest date-based mapping present in the GSI (`mapping/` holds
`31.0`, `32.0`, `33.0`, `34.0`, `202404`, `202504`, `202604`), a
`plat_sepolicy_genfs_202604.cil` exists for the genfs step, and —
decisively — it is the only version whose mapping file compiles
against this GSI's plat policy with the minimal set (see §5 for the
`34.0` failure). The `34.0` mapping is **not** ruled out in principle:
a real `plat_pub_versioned.cil` (generated at vendor build time from
public policy) declares the versioned attributes that `34.0.cil`
references; with the comment-only placeholder below, `34.0` does not
compile. Which version the Android 17 QPR3 branch's init would
*prefer* is **unconfirmed** — `202604` is the version verified here,
not a claim about branch intent.

### `vendor_sepolicy.cil` (129 bytes, comment-only)

```cil
; Minimal vendor policy for a vendor-less QEMU virt target.
; No vendor HALs exist on this target; no vendor rules are declared.
```

No rules are declared because this target has no vendor HALs, no
vendor types, and no vendor services. The file's job in this setup is
to satisfy init's existence check and to be a valid (empty) CIL
input. Verified: compilation succeeds with it, and the control run
without it produces a byte-identical policy (§5), confirming it
contributes no rules — as intended. If vendor HALs are added later,
their types/rules must be added here.

### `plat_pub_versioned.cil` (191 bytes, comment-only)

```cil
; Minimal versioned public platform policy placeholder.
; The vendor policy declares no rules referencing versioned public
; types, so no versioned declarations are required for compilation.
```

Role (from the AOSP build system): the versioned public policy
declares the versioned names (e.g. `foo_34_0`) that vendor rules
reference. Since `vendor_sepolicy.cil` references none, no
declarations are needed for the `202604` compile. This is a
placeholder, not a generated versioned policy: any future vendor rule
that references a versioned public type will require the real
declarations (derived from the public policy + mapping at vendor
build time) to be added here. With mapping version `34.0` this
placeholder is **insufficient** (see §5).

## 3. secilc used for verification (path a/b/c, all tried)

| Path | Result |
|---|---|
| (a) Host apt `secilc` 3.5-1 | **Rejected.** Fails parsing the GSI plat policy: `Unknown permissionx kind, nlmsg. Must be "ioctl"` at `plat_sepolicy.cil:16450` (`app_neverallows.te:150`). The GSI policy uses `permissionx` kinds newer than libsepol 3.5. |
| (b) GSI `/system/bin/secilc` (arm64) under `qemu-aarch64-static` 8.2.2 | **Blocked.** QEMU exits 1 with zero output before executing any guest code, including when the GSI static-PIE `linker64` is invoked directly (host `strace` shows only the linker binary open + `/proc/sys/vm/mmap_min_addr` read, then exit). A freestanding aarch64 static test binary runs fine under the same QEMU, so the failure is specific to loading the Android static-PIE linker. `-cpu max`, guest-base and MTE/BTI flag variants did not change it. Exact cause **unconfirmed**; not pursued further — see §6. The GSI secilc was never executed. |
| (c) Host-built secilc from SELinuxProject source | **Used.** See §4. |

## 4. The secilc that verified the compile

Built in this directory from the SELinuxProject `selinux` repository,
`main` tip, commit `6423998bc7b154da7f9fe726cfda9ace774dfa94`
("libsemanage: synchronize user join caches across transactions"),
in `selinux-main/`. libsepol 3.8 (tag `3.8`) was tried first and rejected: it parses `permissionx
nlmsg` but rejects the policy's `(policycap functionfs_seclabel)`
— upstream 3.8 only knows policycaps 0–9, while the
android17-6.18 kernel (`common/security/selinux/include/policycap.h`,
read from the kernel tree in `~/workspace/kernel-android17-6.18`)
defines 0–13 including `FUNCTIONFS_SECLABEL` (12). Upstream main
has all of them (plus `BPF_TOKEN_PERMS`).

One local build patch was required, in `selinux-main/secilc/secilc.c`
only (diff kept in the source tree; original at `/tmp/secilc.c.orig`
is ephemeral — the change is two lines): the main tip removed the
Xen target support from libsepol, leaving `POLICYDB_XEN_VERSION_MIN/
MAX` undeclared; the patch maps them to `POLICYDB_VERSION_MIN/MAX`
in the `-t xen` branch. The default `selinux` target path is
untouched, and `-t xen` is never used here. The man-page build step
was skipped (`xmlto` absent); only the `secilc` binary was built.

Build (from `selinux-main/`, `PREFIX` set to a staging dir):
`make -C libsepol`, `make -C libselinux`, `make -C secilc secilc`.
Runtime libs are the just-built `libsepol.so.2` /
`libselinux.so.1` from the source tree (`LD_LIBRARY_PATH` set by
`verify-policy.sh`); the binary must **not** pick up the system
libsepol 3.5 (verified with `ldd` in §5).

**Fidelity caveat:** this is upstream main-tip secilc, not the AOSP
fork's secilc that ships in the GSI, and not the Android 17 QPR3
branch code. It accepts every construct in the GSI CIL set and
produces a deterministic binary policy, which is the offline
verification claimed here. Byte-identity with what the GSI secilc
would produce at boot is **unconfirmed** until the GSI secilc (or the
first-stage init) runs the same compile on-device.

## 5. Verification results

Command run (exact; also in `verify-policy.sh`, with `-f` pointed at
a scratch file instead of the on-device `/sys/fs/selinux/null`,
which does not exist on this host — `-f` is file-contexts *output*,
discarded by init):

```
secilc gsi-extract/system/etc/selinux/plat_sepolicy.cil \
  -m -M true -G -N -c 33 \
  gsi-extract/system/etc/selinux/mapping/202604.cil \
  -o work/policy-main.33 -f work/file_contexts-main.out \
  gsi-extract/system/system_ext/etc/selinux/system_ext_sepolicy.cil \
  gsi-extract/system/system_ext/etc/selinux/mapping/202604.cil \
  gsi-extract/system/product/etc/selinux/product_sepolicy.cil \
  gsi-extract/system/product/etc/selinux/mapping/202604.cil \
  vendor-sepolicy/plat_pub_versioned.cil \
  vendor-sepolicy/vendor_sepolicy.cil \
  gsi-extract/system/etc/selinux/plat_sepolicy_genfs_202604.cil
```

Notes on inputs: no `202604.compat.cil` exists in the GSI (only
`34.0.compat.cil` and `system_ext`'s `34.0.compat.cil`), so the
optional compat inputs are skipped exactly as init's `access()`
checks would skip them. No odm policy exists. The genfs file used is
`plat_sepolicy_genfs_202604.cil` (matching the chosen mapping
version; `get_genfs_labels_version()` behaviour on the QPR3 branch
is unconfirmed). Policy version `-c 33` = host secilc default and
the long-standing AOSP `SEPOLICY_VERSION`; kernel acceptance of
version 33 on this 6.18 kernel is unconfirmed until boot (the
version field at offset 16 of the output was verified to be 33, and
30 when `-c 30` was used as a control).

| Check | Result |
|---|---|
| Main compile, mapping `202604`, `-c 33` | **exit 0**, zero stderr. Output `work/policy-main.33`, 727,467 bytes, SHA-256 `58a333b2fb9913c2f6a720f78cd448cf0676ab1eb21fbac4ae2ef82f78006f04`. Magic `0xf97cff8c` (`SELINUX_MAGIC`), version field 33. File-contexts output empty (expected; init discards it). |
| Determinism | Re-run → identical SHA-256. |
| Control: omit `vendor_sepolicy.cil` + `plat_pub_versioned.cil` | exit 0, byte-identical output (727,467 bytes, same SHA). Confirms the minimal files contribute no rules; their role is init's existence requirement + future vendor rules. (secilc itself never required them.) |
| Control: `-c 30` | exit 0, 724,219 bytes, version field 30 — proves `-c` takes effect. |
| Control: mapping `34.0` (+ its compat files) | **exit 254**: `Failed to resolve expandtypeattribute statement at mapping/34.0.cil:18`. `DockObserver_service_34_0` is referenced there but its `(typeattribute …)` declaration does not exist anywhere in the inputs (only the `typeattributeset` at line 1373). Same failure without the compat files. A real `plat_pub_versioned.cil` would declare it; the placeholder does not. |
| `ldd` on the secilc used | `libsepol.so.2` resolves to the just-built main-tip library in this directory, not the system 3.5 library. |

## 6. Unconfirmed / open questions

1. **Boot acceptance:** whether the first-stage init + kernel accept
   this set at boot is unproven until the WorkBuddy first-stage
   binary arrives and a QEMU boot runs `selinux_setup`. In
   particular, `SEPOLICY_VERSION` on the QPR3 branch, genfs version
   selection, and any QPR3-vs-main differences in `OpenSplitPolicy`
   are unconfirmed.
2. **GSI secilc byte-identity:** the on-device compile (GSI secilc,
   Android fork) may produce a different binary policy than upstream
   main-tip secilc. The offline compile proves the CIL set is
   compilable and self-consistent, not that the bytes match.
3. **QEMU-user path (b):** why QEMU 8.2.2 cannot load the Android
   static-PIE linker64 is unconfirmed (BTI/MTE/CPU-feature handling
   suspected, not established). If the GSI secilc is ever needed
   offline, this must be revisited.
4. **`34.0` mapping:** usable in principle with a real
   `plat_pub_versioned.cil`; not usable with this placeholder.
   `202604` is the verified choice for this minimal set.
5. **Future vendor rules:** any vendor HAL added later needs real
   types/rules in `vendor_sepolicy.cil` and, if versioned public
   types are referenced, real declarations in
   `plat_pub_versioned.cil`. The placeholders must not be mistaken
   for a complete vendor policy.
6. **Precompiled alternative (not pursued):** the compiled output
   `work/policy-main.33` is retained as evidence only. Supplying it
   as `/vendor/etc/selinux/precompiled_sepolicy` (plus the three
   matching `.sha256` id files) is a hypothesis from
   SEPOLICY-READINESS.md §4, **not** verified here and not part of
   this deliverable.

## 7. Integrity and scope

- Only `~/workspace/vendor-sepolicy/` was written (plus `/tmp`
  scratch and apt package installs of `secilc`, `qemu-user-static`,
  `flex`, `bison`, `libpcre2-dev` — no other package changes).
  Nothing else was modified; no push, no WorkBuddy, no credits, no
  QEMU system boot.
- GSI zip SHA-256 re-verified unchanged at end:
  `a359a50b6eb8e9f63168e928bd14167603225e92cd8605ec86a4bda6591fc13b`.
  All GSI inputs were extracted read-only with `debugfs` from the
  pristine copy at
  `~/workspace/qemu-system-integration/work/gsi-copy/system.img`
  (SHA-256 `e771161b…` per Lane C records; the copy itself was not
  modified). Extracted plat policy SHA-256 `9db2c480…` matches the
  Lane C record.
- No `ld.config.txt` was written. No original file was modified.

## 8. Files in this directory

- `vendor-sepolicy/plat_sepolicy_vers.txt` — mapping version `202604`
- `vendor-sepolicy/vendor_sepolicy.cil` — comment-only minimal vendor CIL
- `vendor-sepolicy/plat_pub_versioned.cil` — comment-only placeholder
- `VENDOR-SEPOLICY.md` — this document
- `verify-policy.sh` — re-runnable verification (builds nothing; uses
  the prebuilt `selinux-main/secilc/secilc` + its libraries)
- `work/policy-main.33` — compiled policy artifact (SHA-256 above)
- `work/*.log`, `work/*.out` — full command logs
- `gsi-extract/` — read-only debugfs extracts of the GSI inputs used
- `selinux-main/` — upstream main-tip source + built secilc (with the
  two-line Xen patch documented in §4). The rejected libsepol 3.8
  tree was removed after documentation; its failure is recorded in §3–§4.
