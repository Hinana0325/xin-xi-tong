# SEPolicy / selinux_setup readiness

Date: 29 October 2026. GSI: Android 17 QPR3 Beta, build DP11.261002.005
(SDK 37), ARM64 without GMS. All file facts below were read from the
GSI `system.img` (read-only `debugfs` on a copy) and from the existing
ramdisk (cpio listing); no original was modified.

## 1. Headline finding

**The ramdisk's `/sepolicy` file is never read on this device.** The GSI
is a split-policy (Treble) device: `/system/etc/selinux/plat_sepolicy.cil`
exists, so first-stage init takes the split-policy path
(`IsSplitPolicyDevice()` in `system/core/init/selinux.cpp`), which never
opens the monolithic `/sepolicy` file. The ramdisk copy of
`plat_sepolicy.cil` at `/sepolicy` (byte-identical to the system copy,
SHA-256 `9db2c480…`, CIL text) is dead weight under the current code.

**Bigger gap: `selinux_setup` cannot succeed with this GSI alone.**
On the split-policy path, after the (absent) precompiled policy is
skipped, init compiles policy on-device with `/system/bin/secilc`,
and that compilation hard-requires three files under `/vendor` that do
not exist in this setup (see §3). Without them, `OpenSplitPolicy()`
fails and `ReadPolicy()` ends in `LOG(FATAL) "Unable to open SELinux
policy"`. A minimal vendor sepolicy set — or a matching precompiled
policy — is a prerequisite for `selinux_setup`, independent of the
first-stage init binary. Whether the Android 17 QPR3 branch behaves
exactly like the main-branch source cited here is **unconfirmed** (see
§5); the requirement must be re-checked against the first-stage init
that WorkBuddy builds.

## 2. Inventory: sepolicy-related files in the GSI

### `/system/etc/selinux/` (in `system.img`)

| File | Size (bytes) | Notes |
|---|---|---|
| `plat_sepolicy.cil` | 3,418,955 | CIL text (`(role object_r)`…); the split-policy trigger file |
| `plat_sepolicy_and_mapping.sha256` | 65 | First line `f6d4906fc3e5685988526f5ba128a670b66a1643cc7fc7ac4bfd43ed795af7ba` |
| `plat_file_contexts` | 57,929 | |
| `plat_hwservice_contexts` | 8,865 | |
| `plat_keystore2_key_contexts` | 1,544 | |
| `plat_mac_permissions.xml` | 16,506 | |
| `plat_property_contexts` | 132,783 | |
| `plat_seapp_contexts` | 5,106 | |
| `plat_service_contexts` | 48,620 | |
| `plat_tee_service_contexts` | 832 | |
| `plat_sepolicy_genfs_202504.cil` | 142 | |
| `plat_sepolicy_genfs_202604.cil` | 303 | |
| `plat_sepolicy_genfs_202704.cil` | 303 | |
| `mapping/` | — | `202404.cil`, `202504.cil`, `202604.cil`, `31.0.cil`, `32.0.cil`, `33.0.cil`, `34.0.cil` + `.compat.cil` for each |
| `bug_map` | 718 | |

### `/system/product/etc/selinux/` and `/system/system_ext/etc/selinux/`

Both exist inside `system.img` (these are directories under `/system`,
reached after `/system` is mounted):

| File | Size (bytes) |
|---|---|
| `product_sepolicy.cil` / `system_ext_sepolicy.cil` | 280,691 each |
| `product_sepolicy_and_mapping.sha256` / `system_ext_sepolicy_and_mapping.sha256` | 65 each |
| `product_*_contexts` / `system_ext_*_contexts` | mostly 0 bytes, except keystore2/mac_permissions/property/tee_service (101–185 bytes) |
| `mapping/` | `202404/202504/202604/31.0/32.0/33.0/34.0.cil` (+ `.compat.cil` under system_ext; product mapping has no `.compat.cil` files) |

### Absent — searched, not found

- **No `precompiled_sepolicy`** anywhere: `/vendor` is an empty mount
  point in `system.img`, `/vendor/etc` does not exist, `/odm` contains
  only symlinks (`apex`, `app`, `bin`, `etc` → outside the image), and
  no `precompiled_sepolicy*` file exists under `/system/etc/selinux`.
- **No `plat_sepolicy_vers.txt`, no `vendor_sepolicy.cil`, no
  `plat_pub_versioned.cil`, no `nonplat_sepolicy.cil`** — there is no
  vendor policy content at all in this GSI.
- **No `microdroid_precompiled_sepolicy`** (Microdroid path, not
  applicable).
- **No `apex/` sepolicy dir** under `/system/etc/selinux` (updatable
  APEX sepolicy path; **unconfirmed** whether the APEX itself ships
  one — not inventoried here).
- **No `userdebug_plat_sepolicy.cil`** (userdebug override; not
  expected on a user GSI build).

### Binaries and ramdisk files

- `/system/bin/secilc` exists in the GSI (387,504 bytes, mode 0700).
  It runs from `/system` after first-stage init mounts it; it is
  correctly **not** in the ramdisk.
- Ramdisk (`ramdisk.cpio.gz`, SHA-256 `a50640cf…`, 205 entries):
  `/sepolicy` (copy of `plat_sepolicy.cil`, see §1 — unread on the
  split path), full `/system/etc/selinux/` tree, `/system/bin/*`,
  `/system/lib64/*`. No `secilc` in the ramdisk (expected).
- `/system/bin/init` is the second-stage-only binary (see
  `gdb-ptregs/PTREGS-STACKWALK.md`); it is not a first-stage init and
  its `selinux_setup` branch is the one `SetupSelinux()` below would
  execute — **unconfirmed** whether the GSI second-stage binary's
  `selinux_setup` implementation matches the main-branch source.

## 3. What selinux_setup accepts (AOSP source, main branch)

Source: `platform/system/core`, `init/selinux.cpp`, main branch, read
29 Oct 2026 via
<https://android.googlesource.com/platform/system/core/+/main/init/selinux.cpp>
(blob `2a27c1d…`). Function names below are that file's. The GSI is
Android 17 QPR3, not main; differences are possible — see §5.

Flow: first-stage init execs itself as `selinux_setup` →
`SetupSelinux()` → `LoadSelinuxPolicyAndroid()` → `ReadPolicy()` →
`security_load_policy()` into `/sys/fs/selinux`, then
`SelinuxSetEnforcement()`, restorecon of `/system/bin/init`, and
`execv("/system/bin/init", {"init", "second_stage"})`.

`ReadPolicy()` chooses:

1. **Split policy** if `/system/etc/selinux/plat_sepolicy.cil` is
   readable (`IsSplitPolicyDevice()`). **This GSI qualifies.** The
   monolithic `/sepolicy` file is not consulted at all
   (`OpenMonolithicPolicy()` is the else-branch only).
2. **Monolithic policy** otherwise: single file `/sepolicy`, loaded
   directly. Not applicable here.

On the split path, `OpenSplitPolicy()` tries in order:

1. **Precompiled policy** at `/odm/etc/selinux/precompiled_sepolicy`
   if readable, else `/vendor/etc/selinux/precompiled_sepolicy`, used
   **only if** the sha256 id files match: for each of plat /
   system_ext / product, the `*.sha256` beside the precompiled file
   must be both-present-or-both-absent with the system copy and
   identical in content. **Not available here** (no vendor/odm
   policy at all). Note the hash rule also means a stale precompiled
   policy is rejected, not silently used.
2. **On-device compile** with `/system/bin/secilc`, output to a
   temp file under `/dev` (`/dev/sepolicy.XXXXXX`), then loaded from
   that fd. Exact compile inputs (main branch):
   - Mandatory: `plat_sepolicy.cil` (or the userdebug substitute),
     the mapping file `/system/etc/selinux/mapping/<vend_plat_vers>.cil`
     where `<vend_plat_vers>` comes from
     **`/vendor/etc/selinux/plat_sepolicy_vers.txt`** (first line;
     missing/unreadable → `GetVendorMappingVersion()` fails →
     `OpenSplitPolicy()` returns false),
     **`/vendor/etc/selinux/vendor_sepolicy.cil`** (missing → error
     + return false),
     **`/vendor/etc/selinux/plat_pub_versioned.cil`** (missing →
     error + return false).
   - Optional (skipped if absent): plat `.compat.cil`,
     system_ext policy/mapping/compat CILs, product policy/mapping
     CILs, odm policy CIL, and one genfs CIL
     `/system/etc/selinux/plat_sepolicy_genfs_<version>.cil`
     (version from `get_genfs_labels_version()`).
   - secilc flags: `-m -M true -G -N -c <SEPOLICY_VERSION>`,
     `-o <compiled>`, `-f /sys/fs/selinux/null`.
   - **All three vendor files are absent in this GSI**, so step 2
     fails at the first missing file on the main-branch code path.

Policy version: `-c` uses the compile-time `SEPOLICY_VERSION`, and
`security_policyvers()` (kernel support) is queried in older code;
the main-branch code shown uses `SEPOLICY_VERSION` directly.
**Unconfirmed** for the Android 17 branch.

Context files (`plat_file_contexts`, etc.) are **not** inputs to
policy compilation/loading; they are used later by restorecon
(`selinux_android_restorecon`) during second-stage setup. Their
presence in the ramdisk's `/system/etc/selinux/` tree is harmless but
not what makes `selinux_setup` succeed.

## 4. What first-stage must place, and where

Derived from §3 plus the existing ramdisk layout. "Must" = required by
the cited code path; "should" = needed by later stages.

| Path (as seen by first-stage init) | Content | Status in current setup |
|---|---|---|
| `/system/etc/selinux/plat_sepolicy.cil` | Platform CIL (from GSI) | Present after `/system` mount; also copied into ramdisk tree (unused copy) |
| `/system/bin/secilc` | Policy compiler (from GSI) | Present after `/system` mount |
| `/vendor/etc/selinux/plat_sepolicy_vers.txt` | Vendor mapping version, e.g. a `34.0`-style version string | **MISSING — must be created** (content TBD: must name a mapping file that exists, e.g. one of `31.0/32.0/33.0/34.0/202404/202504/202604`) |
| `/vendor/etc/selinux/vendor_sepolicy.cil` | Vendor CIL (may be minimal/empty policy for a vendor-less QEMU setup) | **MISSING — must be created** (minimal valid CIL TBD; must at least parse under secilc together with the plat policy) |
| `/vendor/etc/selinux/plat_pub_versioned.cil` | Versioned public platform policy | **MISSING — must be created** (normally generated at vendor build time from platform public policy; content TBD) |
| `/dev/` (tmpfs) | Writable temp for compiled policy | Mounted by first-stage init (tmpfs); present in ramdisk layout |
| `/sys/fs/selinux` | SELinux filesystem mount | Mounted by first-stage init / kernel; `security_load_policy` target |
| `/sepolicy` (ramdisk root) | Monolithic policy file | Present but **unread** on split-policy devices; keep or drop — no effect on this path |
| `/system_ext/`, `/product/` mounts | Optional policy inputs | Present in fstab scope; their CILs exist in the GSI and are picked up automatically if the partitions are mounted before `selinux_setup` |
| `/odm/etc/selinux/*` | Optional odm policy / precompiled policy location | No odm content; optional files are skipped if absent |

**Alternative to creating vendor CILs:** supply a precompiled policy
at `/vendor/etc/selinux/precompiled_sepolicy` **plus** the three
matching `precompiled_sepolicy.*.sha256` id files whose contents equal
the GSI's `plat_sepolicy_and_mapping.sha256`,
`system_ext_sepolicy_and_mapping.sha256`, and
`product_sepolicy_and_mapping.sha256`. The precompiled binary would
have to be produced by compiling the GSI's CIL set with `secilc`
offline (host-built secilc or the GSI's own `secilc` run under QEMU
user mode / on a booted system) — **unconfirmed** whether the
precompiled binary must also embed the vendor CILs; if it is compiled
from plat+system_ext+product only, it sidesteps the vendor-file
requirement. This is a hypothesis for the ramdisk lane to test, not a
verified route.

## 5. Unconfirmed / open questions (do not treat as settled)

1. **Branch drift:** all code statements above are from the `main`
   branch of `platform/system/core` as crawled 29 Oct 2026. The GSI is
   Android 17 QPR3 (build DP11.261002.005). The vendor-file
   requirements, `SEPOLICY_VERSION` handling, and genfs version
   selection may differ in the `android17-qpr3` branch. Re-check
   against the first-stage init source WorkBuddy builds, or against
   the GSI `secilc`/init binaries' behaviour at boot.
2. **`androidboot.selinux=disabled`:** **unconfirmed** whether the
   first-stage init skips the `selinux_setup` exec (and thus the whole
   vendor-policy requirement) when SELinux is disabled on the cmdline.
   The current cmdline uses `permissive`, under which policy load
   still runs. A `disabled` boot is a legitimate experiment, but its
   outcome is unknown.
3. **Genfs version:** which of `plat_sepolicy_genfs_202504/202604/
   202704.cil` is selected depends on `get_genfs_labels_version()`;
   not traced here.
4. **Minimal vendor CIL contents:** what a valid minimal
   `vendor_sepolicy.cil` + `plat_pub_versioned.cil` pair looks like
   for a vendor-less QEMU target, and which mapping version string
   `plat_sepolicy_vers.txt` should carry, were not determined here.
   The mapping files present cover versions `31.0`–`34.0` and
   `202404`–`202604`; the GSI targets SDK 37, so the correct
   `vend_plat_vers` value is **unconfirmed**.
5. **APEX sepolicy:** whether `com.android.sepolicy` APEX content
   affects this path was not inventoried.
6. **CIL `/sepolicy`:** an earlier hypothesis (missing/generated
   `ld.config.txt`, CIL-form `/sepolicy` unreadable) is superseded:
   the init-debug lane already ruled out `ld.config.txt`, and this
   lane shows the CIL `/sepolicy` is not read at all on split-policy
   devices. No `ld.config.txt` was written.

## 6. Sources

- AOSP `system/core/init/selinux.cpp` (main branch), functions
  `FindPrecompiledSplitPolicy`, `GetVendorMappingVersion`,
  `IsSplitPolicyDevice`, `OpenSplitPolicy`, `OpenMonolithicPolicy`,
  `ReadPolicy`, `LoadSelinuxPolicyAndroid`, `SetupSelinux`:
  <https://android.googlesource.com/platform/system/core/+/main/init/selinux.cpp>
- AOSP "Build SELinux policy" (precompiled policy rules):
  <https://source.android.com/docs/security/features/selinux/build?hl=en>
- GSI file facts: read-only `debugfs` listings/dumps of the
  `system.img` copy at `~/workspace/qemu-boot/system.img` and the
  cpio listing of `~/workspace/bootable-ramdisk/ramdisk.cpio.gz`
  (SHA-256 `a50640cf…`, unchanged; GSI zip SHA-256 `a359a50b…`,
  unchanged).
