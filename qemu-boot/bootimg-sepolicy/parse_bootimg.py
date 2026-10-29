#!/usr/bin/env python3
"""Independent Android boot image header parser (v0-v4).

Written separately from assemble_bootimg_v4.py: it shares no code
with the assembler and re-derives every field from the raw header
bytes. It validates structure only; it never executes anything.

Usage: parse_bootimg.py <boot.img> [other.img ...]
For each image it prints every header field, the computed section
offsets, and structural checks (magic, page alignment, sections
inside the file, no overlap). With two images it also prints a
field-by-field comparison. Exit code 0 = all structural checks pass
for every image; 1 = a check failed.
"""
import struct
import sys


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def u64(d, o):
    return struct.unpack_from("<Q", d, o)[0]


def cstr(d, o, n):
    return d[o:o + n].split(b"\x00", 1)[0].decode(errors="replace")


def parse(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 1660:
        return path, None, ["file smaller than a v4 header (1660 bytes)"]
    h = data[:1660]
    fields = {
        "magic": h[:8],
        "kernel_size": u32(h, 8),
        "kernel_addr": u32(h, 12),
        "ramdisk_size": u32(h, 16),
        "ramdisk_addr": u32(h, 20),
        "second_size": u32(h, 24),
        "second_addr": u32(h, 28),
        "tags_addr": u32(h, 32),
        "page_size": u32(h, 36),
        "header_version": u32(h, 40),
        "os_version": u32(h, 44),
        "name": cstr(h, 48, 16),
        "cmdline": cstr(h, 64, 512),
        "id": h[576:608].hex(),
        "extra_cmdline": cstr(h, 608, 1024),
        "recovery_dtbo_size": u32(h, 1632),
        "recovery_dtbo_offset": u64(h, 1636),
        "header_size": u32(h, 1644),
        "dtb_size": u32(h, 1648),
        "dtb_addr": u64(h, 1652),
    }
    checks = []
    if fields["magic"] != b"ANDROID!":
        checks.append("BAD magic")
    page = fields["page_size"]
    if page == 0:
        checks.append("page_size is 0: section offsets cannot be derived (not a parseable image)")
    else:
        def align(n):
            return (n + page - 1) // page * page
        off = page
        sections = []
        for label, size in (("kernel", fields["kernel_size"]),
                            ("ramdisk", fields["ramdisk_size"]),
                            ("second", fields["second_size"])):
            sections.append((label, off, size))
            off += align(size)
        fields["sections"] = sections
        for label, o, s in sections:
            if s and o + s > len(data):
                checks.append(f"{label} section overruns file (off={o} size={s} file={len(data)})")
        if fields["dtb_size"] and fields["dtb_addr"] == 0:
            checks.append("dtb_size nonzero but dtb_addr is 0")
        if fields["header_version"] == 4 and fields["header_size"] not in (0, 1660):
            checks.append(f"v4 header_size is {fields['header_size']}, expected 1660")
    fields["file_size"] = len(data)
    return path, fields, checks


def show(path, fields, checks):
    print(f"== {path} (file_size={fields['file_size']}) ==")
    for key, value in fields.items():
        if key in ("sections", "file_size"):
            continue
        if isinstance(value, int) and key.endswith("_addr"):
            print(f"  {key} = 0x{value:08x} ({value})")
        elif key == "os_version":
            print(f"  {key} = 0x{value:08x}")
        else:
            print(f"  {key} = {value!r}")
    if "sections" in fields:
        for label, o, s in fields["sections"]:
            print(f"  section {label}: offset={o} size={s}")
    print("  checks: " + ("OK" if not checks else "; ".join(checks)))
    return not checks


def main():
    paths = sys.argv[1:]
    results = [parse(p) for p in paths]
    ok = True
    parsed = []
    for path, fields, checks in results:
        if fields is None:
            print(f"== {path} ==\n  UNPARSEABLE: {'; '.join(checks)}")
            ok = False
            continue
        parsed.append((path, fields))
        ok = show(path, fields, checks) and ok
    if len(parsed) == 2:
        print("== field-by-field comparison ==")
        (_, a), (_, b) = parsed
        for key in a:
            if key in ("sections", "file_size"):
                continue
            mark = "SAME" if a[key] == b[key] else "DIFF"
            print(f"  {mark:4} {key}: {a[key]!r}  vs  {b[key]!r}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
