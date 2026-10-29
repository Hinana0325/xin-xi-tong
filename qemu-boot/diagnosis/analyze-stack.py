#!/usr/bin/env python3
"""Offline analysis of gdb-ptregs stackdump.txt: auxv hunt + symbol resolution."""
import re

DUMP = "/home/hatch/workspace/gdb-ptregs/stackwalk-out/stackdump.txt"
SYMS = "/home/hatch/workspace/gdb-init/symbols/init-symbols.txt"

words = []
for line in open(DUMP):
    m = re.match(r"0x([0-9a-f]+):\s+0x([0-9a-f]+)", line.strip())
    if m:
        words.append((int(m.group(1), 16), int(m.group(2), 16)))
print("words:", len(words), "VA range: 0x%x..0x%x" % (words[0][0], words[-1][0]))
print("first 16 stack words (siginfo at SP expected: 6, 0, -1, ...):")
for va, v in words[:16]:
    print("  0x%x: 0x%016x" % (va, v))

# --- auxv hunt: scan for (type, value) pairs ---
AT = {3: "AT_PHDR", 5: "AT_PHNUM", 6: "AT_PAGESZ", 7: "AT_BASE", 9: "AT_ENTRY",
      11: "AT_UID", 12: "AT_EUID", 15: "AT_PLATFORM", 16: "AT_HWCAP",
      17: "AT_CLKTCK", 23: "AT_SECURE", 25: "AT_RANDOM", 31: "AT_EXECFN", 33: "AT_SYSINFO_EHDR"}
vals = [v for _, v in words]
vas = [a for a, _ in words]
print("\nauxv candidate pairs (type in known set, scanning all offsets):")
cands = []
for i in range(len(vals) - 1):
    t = vals[i]
    if t in AT and vals[i + 1] != 0:
        cands.append((vas[i], t, vals[i + 1]))
for va, t, v in cands:
    print("  stack VA 0x%x: %s(%d) = 0x%x" % (va, AT[t], t, v))

# AT_ENTRY / AT_PHDR cross-check for init base (entry offset 0x70000, PHDR offset 0x40)
entry_vals = [v for _, t, v in cands if t == 9]
phdr_vals = [v for _, t, v in cands if t == 3]
base_vals = [v for _, t, v in cands if t == 7]
print("\nAT_ENTRY values:", [hex(x) for x in entry_vals])
print("AT_PHDR values:", [hex(x) for x in phdr_vals])
print("AT_BASE values:", [hex(x) for x in base_vals])
bases = set()
for x in entry_vals:
    bases.add(x - 0x70000)
for z in phdr_vals:
    bases.add(z - 0x40)
print("candidate init bases:", [hex(b) for b in bases])

# --- load init symbols ---
syms = []
for line in open(SYMS):
    m = re.match(r"\s*\d+:\s+([0-9a-f]+)\s+(\d+)\s+(\S+)\s+(\S+)\s+\S+\s+\S+\s+(.+)$", line)
    if m:
        val, size, typ, bind = int(m.group(1), 16), int(m.group(2)), m.group(3), m.group(4)
        name = m.group(5).strip()
        if typ == "FUNC" and size > 0:
            syms.append((val, size, name))
syms.sort()
print("\ninit FUNC symbols:", len(syms), "range 0x%x..0x%x" % (syms[0][0], syms[-1][0] + syms[-1][1]))

def resolve(addr, base):
    off = addr - base
    # return address points just past a call; use off-1 for containment
    tgt = off - 1
    lo, hi = 0, len(syms) - 1
    best = None
    while lo <= hi:
        mid = (lo + hi) // 2
        if syms[mid][0] <= tgt:
            best = mid
            lo = mid + 1
        else:
            hi = mid - 1
    if best is None:
        return None
    val, size, name = syms[best]
    if val <= tgt < val + size:
        return (name, tgt - val, size)
    return ("(gap after %s+0x%x)" % (name, tgt - val), tgt - val, size)

for base in sorted(bases):
    print("\n=== stack words resolving into init range [0x%x, 0x%x) ===" % (base, base + 0x280000))
    for va, v in words:
        if base <= v < base + 0x280000:
            r = resolve(v, base)
            print("  stack VA 0x%x: value 0x%x -> %s" % (va, v, r))
    print("=== ELR/LR check: ELR=0x7f8455c11c LR=0x7f8455c0f8 (this run) ===")
    print("  (libc range; resolve after libc base is known)")
