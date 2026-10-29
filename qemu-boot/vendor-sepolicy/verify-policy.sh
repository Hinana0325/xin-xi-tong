#!/bin/bash
# Re-runnable offline verification of the minimal vendor sepolicy set.
# Uses the prebuilt upstream main-tip secilc in selinux-main/ (see
# VENDOR-SEPOLICY.md §4). Builds nothing. Exits 0 only if the compile
# succeeds AND the output is a valid binary policy (magic + version 33)
# AND a re-run is byte-identical.
set -euo pipefail
cd "$(dirname "$0")"

SECILC="$PWD/selinux-main/secilc/secilc"
export LD_LIBRARY_PATH="$PWD/selinux-main/libsepol/src:$PWD/selinux-main/libselinux/src"
E="$PWD/gsi-extract"

[ -x "$SECILC" ] || { echo "MISSING: $SECILC (rebuild per VENDOR-SEPOLICY.md §4)"; exit 2; }
ldd "$SECILC" | grep -q "selinux-main/libsepol/src/libsepol.so.2" \
  || { echo "WRONG LIBSEPOL: must use the just-built main-tip library, not system 3.5"; ldd "$SECILC"; exit 2; }

run_compile() {
  local out="$1" fc="$2"
  "$SECILC" "$E/system/etc/selinux/plat_sepolicy.cil" \
    -m -M true -G -N -c 33 \
    "$E/system/etc/selinux/mapping/202604.cil" \
    -o "$out" -f "$fc" \
    "$E/system/system_ext/etc/selinux/system_ext_sepolicy.cil" \
    "$E/system/system_ext/etc/selinux/mapping/202604.cil" \
    "$E/system/product/etc/selinux/product_sepolicy.cil" \
    "$E/system/product/etc/selinux/mapping/202604.cil" \
    vendor-sepolicy/plat_pub_versioned.cil \
    vendor-sepolicy/vendor_sepolicy.cil \
    "$E/system/etc/selinux/plat_sepolicy_genfs_202604.cil"
}

mkdir -p work
run_compile work/verify-policy.out work/verify-fc.out
echo "compile exit=0"
python3 - "$PWD/work/verify-policy.out" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
assert len(d) > 20, "output too small"
magic = struct.unpack('<I', d[0:4])[0]
ver = struct.unpack('<I', d[16:20])[0]
assert magic == 0xf97cff8c, "bad magic 0x%08x" % magic
assert ver == 33, "bad policy version %d" % ver
print("magic=0x%08x version=%d size=%d" % (magic, ver, len(d)))
EOF
run_compile work/verify-policy2.out work/verify-fc2.out
cmp -s work/verify-policy.out work/verify-policy2.out || { echo "NON-DETERMINISTIC OUTPUT"; exit 3; }
echo "determinism: identical"
sha256sum work/verify-policy.out
echo "VERIFY OK"
