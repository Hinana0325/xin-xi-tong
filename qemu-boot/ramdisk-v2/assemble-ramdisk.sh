#!/usr/bin/env bash
# assemble-ramdisk.sh — parameterised first-stage ramdisk builder (Lane B).
#
# Usage:
#   assemble-ramdisk.sh INIT_BINARY GSI_EXTRACT_DIR OUTPUT_CPIO_GZ [FSTAB_FILE]
#
#   INIT_BINARY       path to the first-stage init binary to place in the ramdisk
#                     (for pipeline testing, the GSI second-stage init may be
#                     used as a stand-in; see STAND-IN note below).
#   GSI_EXTRACT_DIR   read-only extracted GSI system.img tree (must contain
#                     system/bin, system/lib64, system/etc, ...). Never written.
#   OUTPUT_CPIO_GZ    destination cpio.gz (newc, gzip -n, deterministic).
#   FSTAB_FILE        optional fstab to install. If omitted, the script uses
#                     $GSI_EXTRACT_DIR/fstab.qemu when present, else fails.
#
# Behaviour:
#   * Computes the full DT_NEEDED closure of INIT_BINARY (and of its ELF
#     interpreter) with readelf, resolving each library from
#     $EXTRACT/system/lib64 first, then $EXTRACT/system/lib64/bootstrap.
#     ANY library that cannot be resolved is a hard error: the script prints
#     "MISSING:" lines and exits 1 without writing output. It never silently
#     ships a ramdisk with a missing library.
#   * The binary is installed at /init_first_stage; /init is a symlink to
#     /init_first_stage. It is NEVER a symlink to /system/bin/init (that was
#     the root cause of the GSI init FATAL: the GSI binary is second-stage
#     only and aborts when executed as PID 1 with argc=1).
#   * Includes the ELF interpreter at its original path, /sepolicy, the
#     selinux context files, init.environ.rc, cgroups.json, linker.config.pb,
#     the second-stage init rc tree, the fstab, empty mount-point dirs and
#     /dev character nodes (written by the Python newc writer: mknod fails
#     with EPERM on this host filesystem).
#   * Writes a JSON manifest next to the output: <output>.manifest.json,
#     with a SHA-256 per file entry and the total entry count. Re-running
#     with the same inputs reproduces byte-identical output (sorted entries,
#     mtime 0, gzip -n).
#
# STAND-IN WARNING: running this script with the GSI /system/bin/init as
# INIT_BINARY only proves the pipeline works. That binary is second-stage
# only and WILL still FATAL ("Second-stage init requires an argument to
# main()") if booted. No boot claim is made by this script.
#
# No QEMU is run by this script. No file outside the output path (and its
# manifest) is written. The GSI extract tree is only read.
set -euo pipefail

die() { echo "assemble-ramdisk: ERROR: $*" >&2; exit 1; }
warn() { echo "assemble-ramdisk: WARNING: $*" >&2; }

[ $# -ge 3 ] || die "usage: $0 INIT_BINARY GSI_EXTRACT_DIR OUTPUT_CPIO_GZ [FSTAB_FILE]"
INIT_BIN="$1"; EXTRACT="$2"; OUTPUT="$3"; FSTAB_ARG="${4:-}"

[ -f "$INIT_BIN" ] || die "init binary not found: $INIT_BIN"
[ -d "$EXTRACT" ] || die "GSI extract dir not found: $EXTRACT"
[ -f "$EXTRACT/system/bin/init" ] || warn "extract tree has no system/bin/init (unexpected for a GSI tree)"
command -v readelf >/dev/null || die "readelf not found"
command -v python3 >/dev/null || die "python3 not found"
command -v gzip >/dev/null || die "gzip not found"

if [ -n "$FSTAB_ARG" ]; then
    [ -f "$FSTAB_ARG" ] || die "fstab file not found: $FSTAB_ARG"
    FSTAB_FILE="$FSTAB_ARG"
elif [ -f "$EXTRACT/fstab.qemu" ]; then
    FSTAB_FILE="$EXTRACT/fstab.qemu"
    warn "no fstab argument; using $FSTAB_FILE"
else
    die "no fstab file: pass FSTAB_FILE or place fstab.qemu in the extract dir"
fi

# --- resolve interpreter -------------------------------------------------
INTERP="$(readelf -l "$INIT_BIN" 2>/dev/null | awk '/Requesting program interpreter/ {print $NF}' | tr -d '[]')"
[ -n "$INTERP" ] || die "no PT_INTERP found in $INIT_BIN (not a dynamic PIE?)"
INTERP_SRC="$EXTRACT${INTERP}"
[ -f "$INTERP_SRC" ] || die "interpreter $INTERP not found in extract tree at $INTERP_SRC"
echo "interpreter: $INTERP"

# --- compute DT_NEEDED closure -------------------------------------------
# Resolution order mirrors the previous ramdisk build: system/lib64 first,
# then system/lib64/bootstrap. Zero-size placeholder files (e.g. lib64/libc.so)
# are copied as-is; the real implementation lives in bootstrap/.
LIBDIRS="$EXTRACT/system/lib64:$EXTRACT/system/lib64/bootstrap"

CLOSURE_TMP="$(mktemp)"
trap 'rm -f "$CLOSURE_TMP"' EXIT

python3 - "$INIT_BIN" "$INTERP_SRC" "$LIBDIRS" "$CLOSURE_TMP" <<'PYEOF'
import re, subprocess, sys, os
init_bin, interp, libdirs, out = sys.argv[1], sys.argv[2], sys.argv[3].split(":"), sys.argv[4]

def needed(path):
    r = subprocess.run(["readelf", "-d", path], capture_output=True, text=True)
    return re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", r.stdout)

def resolve(name):
    for d in libdirs:
        cand = os.path.join(d, name)
        if os.path.isfile(cand) or os.path.islink(cand):
            return cand
    return None

resolved, missing, queue = {}, [], [init_bin, interp]
seen = set()
while queue:
    f = queue.pop(0)
    if f in seen:
        continue
    seen.add(f)
    for lib in needed(f):
        if lib in resolved:
            continue
        src = resolve(lib)
        if src is None:
            missing.append(lib)
            continue
        resolved[lib] = src
        queue.append(src)

if missing:
    for lib in sorted(set(missing)):
        print(f"MISSING: {lib}", file=sys.stderr)
    sys.exit(1)

with open(out, "w") as fh:
    for lib in sorted(resolved):
        fh.write(f"{lib}\t{resolved[lib]}\n")
PYEOF
[ $? -eq 0 ] || die "dependency closure incomplete (see MISSING lines above)"
echo "dependency closure: $(wc -l < "$CLOSURE_TMP") libraries"

# --- stage the ramdisk tree ----------------------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"; rm -f "$CLOSURE_TMP"' EXIT

install_file() { # install_file SRC RELPATH [MODE]
    local src="$1" rel="$2" mode="${3:-}"
    mkdir -p "$STAGE/$(dirname "$rel")"
    cp --no-preserve=ownership "$src" "$STAGE/$rel"
    [ -n "$mode" ] && chmod "$mode" "$STAGE/$rel" || chmod "$(stat -c %a "$src")" "$STAGE/$rel" 2>/dev/null || true
}
install_tree() { # install_tree SRC_DIR RELPATH (recursive, regular files only)
    local srcdir="$1" rel="$2"
    ( cd "$srcdir" && find . -type f -print0 ) | while IFS= read -r -d '' f; do
        install_file "$srcdir/${f#./}" "$rel/${f#./}"
    done
}
install_symlink() { # install_symlink TARGET RELPATH
    mkdir -p "$STAGE/$(dirname "$2")"
    ln -sfn "$1" "$STAGE/$2"
}

# First-stage binary + /init symlink (never -> /system/bin/init).
install_file "$INIT_BIN" "init_first_stage" 755
install_symlink "/init_first_stage" "init"

# Interpreter at its original path, plus the GSI's own symlinks.
install_file "$INTERP_SRC" "${INTERP#/}" 755
[ -L "$EXTRACT/system/bin/linker64" ] && install_symlink "$(readlink "$EXTRACT/system/bin/linker64")" "system/bin/linker64"
[ -L "$EXTRACT/system/bin/linker" ] && install_symlink "$(readlink "$EXTRACT/system/bin/linker")" "system/bin/linker"
[ -L "$EXTRACT/system/bin/ueventd" ] && install_symlink "$(readlink "$EXTRACT/system/bin/ueventd")" "system/bin/ueventd"

# Dependency closure, preserving extract-relative paths.
while IFS="$(printf '\t')" read -r lib src; do
    rel="${src#$EXTRACT/}"
    install_file "$src" "$rel"
done < "$CLOSURE_TMP"

# sepolicy: root /sepolicy in the extract tree if present, else the platform
# policy it was copied from.
if [ -f "$EXTRACT/sepolicy" ]; then
    install_file "$EXTRACT/sepolicy" "sepolicy" 644
elif [ -f "$EXTRACT/system/etc/selinux/plat_sepolicy.cil" ]; then
    install_file "$EXTRACT/system/etc/selinux/plat_sepolicy.cil" "sepolicy" 644
else
    die "no sepolicy found (neither $EXTRACT/sepolicy nor plat_sepolicy.cil)"
fi
[ -d "$EXTRACT/system/etc/selinux" ] && install_tree "$EXTRACT/system/etc/selinux" "system/etc/selinux"
[ -f "$EXTRACT/init.environ.rc" ] && install_file "$EXTRACT/init.environ.rc" "init.environ.rc" 644
[ -f "$EXTRACT/system/etc/cgroups.json" ] && install_file "$EXTRACT/system/etc/cgroups.json" "system/etc/cgroups.json" 644
[ -f "$EXTRACT/system/etc/linker.config.pb" ] && install_file "$EXTRACT/system/etc/linker.config.pb" "system/etc/linker.config.pb" 644
[ -d "$EXTRACT/system/etc/init" ] && install_tree "$EXTRACT/system/etc/init" "system/etc/init"

# fstab: install at every path the GSI init binary searches (see
# MOUNT-EXPECTATIONS.md; which suffix matches is unconfirmed).
install_file "$FSTAB_FILE" "fstab" 644
install_file "$FSTAB_FILE" "fstab.qemu" 644
install_file "$FSTAB_FILE" "first_stage_ramdisk/fstab" 644
install_file "$FSTAB_FILE" "first_stage_ramdisk/fstab.qemu" 644

# Empty mount-point / layout dirs (standard first-stage layout).
for d in dev proc sys vendor odm product system_ext metadata data cache mnt \
         apex linkerconfig debug_ramdisk second_stage_resources first_stage_ramdisk \
         system system/etc system/bin system/lib64 system/lib64/bootstrap; do
    mkdir -p "$STAGE/$d"
done

# --- write cpio.gz + manifest (Python newc writer) ------------------------
MANIFEST="${OUTPUT}.manifest.json"
python3 - "$STAGE" "$OUTPUT" "$MANIFEST" "$INIT_BIN" "$FSTAB_FILE" <<'PYEOF'
import gzip, hashlib, json, os, stat, sys

stage, output, manifest_path, init_bin, fstab_file = sys.argv[1:6]

# (path, mode, rdev_major, rdev_minor) — mknod fails with EPERM on this host,
# so device nodes are emitted directly as cpio entries.
DEVNODES = [
    ("dev/console", 0o600, 5, 1),
    ("dev/null",    0o666, 1, 3),
    ("dev/zero",    0o666, 1, 5),
    ("dev/full",    0o666, 1, 7),
    ("dev/ptmx",    0o666, 5, 2),
    ("dev/tty",     0o666, 5, 0),
    ("dev/kmsg",    0o600, 1, 11),
    ("dev/random",  0o666, 1, 8),
    ("dev/urandom", 0o666, 1, 9),
]

entries = []  # (name, mode, uid, gid, mtime, type, data|target, rdev)
for root, dirs, files in os.walk(stage):
    dirs.sort()
    for d in sorted(dirs):
        p = os.path.join(root, d)
        rel = os.path.relpath(p, stage)
        entries.append((rel, 0o40755, 0, 0, 0, "dir", None, 0))
    for f in sorted(files):
        p = os.path.join(root, f)
        rel = os.path.relpath(p, stage)
        st = os.lstat(p)
        if stat.S_ISLNK(st.st_mode):
            entries.append((rel, 0o120777, 0, 0, 0, "symlink", os.readlink(p), 0))
        else:
            with open(p, "rb") as fh:
                data = fh.read()
            entries.append((rel, 0o100000 | (stat.S_IMODE(st.st_mode)), 0, 0, 0, "file", data, 0))
entries.append((".", 0o40755, 0, 0, 0, "dir", None, 0))
for name, mode, maj, mnr in DEVNODES:
    entries.append((name, 0o020000 | mode, 0, 0, 0, "char", None, (maj << 8) | mnr))

# Deduplicate by name (walk can list the same dir twice via nested dirs); sort.
seen, uniq = set(), []
for e in entries:
    if e[0] in seen:
        continue
    seen.add(e[0])
    uniq.append(e)
uniq.sort(key=lambda e: e[0])

def header(name, ino, mode, uid, gid, nlink, mtime, filesize, devmajor, devminor, rdevmajor, rdevminor):
    # newc: magic(6) + 11 fields(8 each) + namesize(8) + check(8) = 110 bytes.
    fields = [ino, mode, uid, gid, nlink, mtime, filesize, devmajor, devminor, rdevmajor, rdevminor]
    return b"070701" + "".join(f"{v:08x}" for v in fields).encode() + f"{len(name) + 1:08x}".encode() + b"00000000" + name.encode() + b"\0"

def pad4(n):
    return (4 - (n % 4)) % 4

buf = bytearray()
manifest_entries = []
for i, (name, mode, uid, gid, mtime, typ, payload, rdev) in enumerate(uniq, start=1):
    if typ == "file":
        data, nlink = payload, 1
        sha = hashlib.sha256(data).hexdigest()
        manifest_entries.append({"path": "/" + name, "type": "file",
                                 "mode": oct(mode & 0o777), "size": len(data), "sha256": sha})
    elif typ == "symlink":
        data, nlink = payload.encode(), 1
        manifest_entries.append({"path": "/" + name, "type": "symlink",
                                 "mode": "0777", "size": len(data), "target": payload})
    elif typ == "char":
        data, nlink = b"", 1
        manifest_entries.append({"path": "/" + name, "type": "char",
                                 "mode": oct(mode & 0o777),
                                 "rdev": {"major": (rdev >> 8) & 0xFF, "minor": rdev & 0xFF}})
    else:
        data, nlink = b"", 2
        manifest_entries.append({"path": "/" + name, "type": "dir", "mode": "0755"})
    hdr = header(name, i, mode, uid, gid, nlink, mtime, len(data), 0, 0,
                 (rdev >> 8) & 0xFF, rdev & 0xFF)
    buf += hdr
    buf += b"\0" * pad4(len(hdr))
    buf += data
    buf += b"\0" * pad4(len(data))
buf += header("TRAILER!!!", 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0)
buf += b"\0" * pad4(len(header("TRAILER!!!", 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0)))
while len(buf) % 512:
    buf += b"\0"

with open(output, "wb") as fh:
    with gzip.GzipFile(filename="", mode="wb", compresslevel=9, mtime=0, fileobj=fh) as gz:
        gz.write(bytes(buf))

def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        h.update(fh.read())
    return h.hexdigest()

manifest = {
    "init_binary": os.path.abspath(init_bin),
    "init_binary_sha256": sha256_file(init_bin),
    "fstab_source": os.path.abspath(fstab_file),
    "fstab_sha256": sha256_file(fstab_file),
    "init_symlink_target": "/init_first_stage",
    "total_entries": len(manifest_entries),
    "entries": sorted(manifest_entries, key=lambda e: e["path"]),
}
with open(manifest_path, "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
print(f"entries: {len(manifest_entries)}  output: {output}  manifest: {manifest_path}")
PYEOF

echo "OK: $OUTPUT"
sha256sum "$OUTPUT"
