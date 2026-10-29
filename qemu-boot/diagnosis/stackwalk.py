import gdb
import re
import struct
import traceback

OUTDIR = "/home/hatch/workspace/gdb-ptregs/stackwalk-out"

def log(msg):
    try:
        with open(OUTDIR + "/stackwalk-python.log", "a") as f:
            f.write(msg + "\n")
    except Exception:
        pass

try:
    inf = gdb.selected_inferior()
    pregs_addr = int(gdb.parse_and_eval("$x0")) & 0xFFFFFFFFFFFFFFFF
    raw = bytes(inf.read_memory(pregs_addr, 288))
    def u64(off):
        return struct.unpack_from("<Q", raw, off)[0]
    regs = [u64(i * 8) for i in range(31)]
    sp = u64(248)
    elr = u64(256)
    pstate = u64(264)
    orig_x0 = u64(272)
    sysno = struct.unpack_from("<i", raw, 280)[0]
    lr = regs[30]

    # --- TTBR0_EL1 ---
    ttbr0 = None
    ttbr0_src = None
    try:
        ttbr0 = int(gdb.parse_and_eval("$ttbr0_el1")) & 0xFFFFFFFFFFFFFFFF
        ttbr0_src = "$ttbr0_el1 register"
    except Exception as e1:
        log("ttbr0 register read failed: %r" % (e1,))
    if ttbr0 is None:
        try:
            out = gdb.execute("info registers", to_string=True)
            m = re.search(r"TTBR0_EL1\s+0x([0-9a-fA-F]+)", out)
            if m:
                ttbr0 = int(m.group(1), 16)
                ttbr0_src = "info registers"
        except Exception as e2:
            log("info registers parse failed: %r" % (e2,))
    if ttbr0 is None:
        try:
            out = gdb.execute("monitor info registers", to_string=True)
            m = re.search(r"TTBR0_EL1[=\s]+0x?([0-9a-fA-F]+)", out)
            if m:
                ttbr0 = int(m.group(1), 16)
                ttbr0_src = "monitor info registers"
        except Exception as e3:
            log("monitor info registers parse failed: %r" % (e3,))
    ttbr0_base = (ttbr0 & 0x0000FFFFFFFFF000) if ttbr0 is not None else None

    def read_phys(pa, count=1):
        out = gdb.execute("monitor xp /%dgx 0x%x" % (count, pa), to_string=True)
        vals = []
        for line in out.splitlines():
            if ":" in line:
                after = line.split(":", 1)[1]
                for tok in after.split():
                    try:
                        vals.append(int(tok, 16))
                    except ValueError:
                        pass
        if len(vals) < count:
            raise RuntimeError("monitor xp returned %d/%d words for pa 0x%x; raw=%r" % (len(vals), count, pa, out[:300]))
        return vals

    def va_to_pa(va):
        # 39-bit VA, 4K granule: L1 idx bits[38:30], L2 bits[29:21], L3 bits[20:12]
        if ttbr0_base is None:
            return None, "no TTBR0"
        table = ttbr0_base
        for level, shift in enumerate((30, 21, 12)):
            idx = (va >> shift) & 0x1FF
            desc = read_phys(table + idx * 8, 1)[0]
            typ = desc & 0x3
            if level < 2:
                if typ == 0b11:
                    table = desc & 0x0000FFFFFFFFF000
                    continue
                if typ == 0b01:
                    block_bits = 30 if level == 0 else 21
                    pa = (desc & ~((1 << block_bits) - 1)) + (va & ((1 << block_bits) - 1))
                    return pa, "block L%d desc=0x%x" % (level + 1, desc)
                return None, "invalid desc 0x%x at L%d idx %d" % (desc, level + 1, idx)
            if typ == 0b11:
                pa = (desc & 0x0000FFFFFFFFF000) + (va & 0xFFF)
                return pa, "page desc=0x%x" % desc
            return None, "invalid L3 desc 0x%x" % (desc)
        return None, "walk fell through"

    summary = []
    summary.append("pt_regs addr = 0x%x" % pregs_addr)
    summary.append("syscallno = %d" % sysno)
    summary.append("args: tgid=%d tid=%d sig=%d uinfo=0x%x" % (regs[0], regs[1], regs[2], regs[3]))
    summary.append("LR(+240) = 0x%x" % lr)
    summary.append("SP(+248) = 0x%x" % sp)
    summary.append("ELR(+256) = 0x%x" % elr)
    summary.append("PSTATE(+264) = 0x%x ORIG_X0(+272) = 0x%x" % (pstate, orig_x0))
    summary.append("TTBR0_EL1 = %s (via %s), table base = %s" % (
        ("0x%x" % ttbr0) if ttbr0 is not None else "NONE",
        ttbr0_src,
        ("0x%x" % ttbr0_base) if ttbr0_base is not None else "NONE"))

    # --- ELR page: check SVC instruction at ELR-4 ---
    elr_bytes = None
    try:
        elr_pa, elr_info = va_to_pa(elr - 4)
        summary.append("ELR-4 walk: %s -> pa 0x%x (%s)" % ("0x%x" % (elr - 4), elr_pa, elr_info) if elr_pa is not None else "ELR-4 walk FAILED: %s" % elr_info)
        if elr_pa is not None:
            words = read_phys(elr_pa & ~0x7, 4)
            # reconstruct 16 bytes around ELR-4 from aligned reads
            buf = b"".join(struct.pack("<Q", w) for w in words)
            off = (elr - 4) - (elr_pa & ~0x7)
            elr_bytes = buf[off:off + 8]
            summary.append("bytes at ELR-4: %s" % elr_bytes.hex())
            summary.append("SVC check: last 4 bytes %s (expect 010000d4 for svc #0)" % elr_bytes[0:4].hex() if len(elr_bytes) >= 4 else "short read")
    except Exception as e:
        summary.append("ELR page read failed: %r" % (e,))
        log(traceback.format_exc())

    # --- userspace stack dump: 16 pages upward from SP page ---
    stack_lines = []
    walk_log = []
    page_base = sp & ~0xFFF
    npages_ok = 0
    for i in range(16):
        va = page_base + i * 0x1000
        try:
            pa, info = va_to_pa(va)
        except Exception as e:
            walk_log.append("page %d va 0x%x: walk exception %r" % (i, va, e))
            log(traceback.format_exc())
            break
        if pa is None:
            walk_log.append("page %d va 0x%x: UNMAPPED (%s) -- stop" % (i, va, info))
            break
        walk_log.append("page %d va 0x%x -> pa 0x%x (%s)" % (i, va, pa, info))
        try:
            words = read_phys(pa, 512)
        except Exception as e:
            walk_log.append("page %d va 0x%x: read_phys failed %r -- stop" % (i, va, e))
            break
        npages_ok += 1
        for j, w in enumerate(words):
            stack_lines.append("0x%x: 0x%016x" % (va + j * 8, w))
    summary.append("stack pages dumped: %d/16" % npages_ok)
    summary.extend(walk_log)

    with open(OUTDIR + "/stackdump.txt", "w") as f:
        f.write("\n".join(stack_lines) + "\n")
    with open(OUTDIR + "/stackwalk-summary.txt", "w") as f:
        f.write("\n".join(summary) + "\n")
    print("STACKWALK-PYTHON-DONE sp=0x%x elr=0x%x pages=%d ttbr0=%s" % (
        sp, elr, npages_ok, ("0x%x" % ttbr0) if ttbr0 is not None else "NONE"))
except Exception:
    log("STACKWALK-PYTHON-EXCEPTION:\n" + traceback.format_exc())
    print("STACKWALK-PYTHON-FAILED (see stackwalk-python.log)")
