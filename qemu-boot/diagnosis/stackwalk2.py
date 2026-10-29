import gdb
import re
import struct
import traceback

OUTDIR = "/home/hatch/workspace/gdb-ptregs/stackwalk-out"
# Offsets filled in from vmlinux DWARF (see stackwalk2-notes.txt).
TASK_MM_OFFSET = 1688   # struct task_struct.mm (vmlinux DWARF)
MM_PGD_OFFSET = 104    # struct mm_struct.pgd (vmlinux DWARF)

def log(msg):
    try:
        with open(OUTDIR + "/stackwalk2-python.log", "a") as f:
            f.write(msg + "\n")
    except Exception:
        pass

def kread(addr, n):
    return bytes(gdb.selected_inferior().read_memory(addr, n))

def u64(buf, off):
    return struct.unpack_from("<Q", buf, off)[0]

def read_phys(pa, count=1):
    out = gdb.execute("monitor xp /%dgx 0x%x" % (count, pa), to_string=True)
    vals = []
    for line in out.splitlines():
        if ":" in line:
            for tok in line.split(":", 1)[1].split():
                try:
                    vals.append(int(tok, 16))
                except ValueError:
                    pass
    if len(vals) < count:
        raise RuntimeError("monitor xp returned %d/%d words for pa 0x%x; raw=%r" % (len(vals), count, pa, out[:300]))
    return vals

try:
    summary = []
    # --- registers snapshot for TTBR0 cross-check ---
    try:
        regout = gdb.execute("info registers", to_string=True)
        with open(OUTDIR + "/info-registers.txt", "w") as f:
            f.write(regout)
        m = re.search(r"TTBR0_EL1\s+0x([0-9a-fA-F]+)", regout)
        summary.append("gdb info registers TTBR0_EL1 = %s" % (("0x" + m.group(1)) if m else "NOT-FOUND"))
    except Exception as e:
        summary.append("info registers failed: %r" % (e,))
    try:
        monout = gdb.execute("monitor info registers", to_string=True)
        with open(OUTDIR + "/monitor-registers.txt", "w") as f:
            f.write(monout)
        m2 = re.findall(r"TTBR0_EL1[=\s]+0x?([0-9a-fA-F]+)", monout)
        summary.append("monitor info registers TTBR0_EL1 values = %s" % (m2,))
    except Exception as e:
        summary.append("monitor info registers failed: %r" % (e,))

    # --- pt_regs (from $x0, proven in run 1) ---
    pregs_addr = int(gdb.parse_and_eval("$x0")) & 0xFFFFFFFFFFFFFFFF
    raw = kread(pregs_addr, 288)
    regs = [u64(raw, i * 8) for i in range(31)]
    sp = u64(raw, 248)
    elr = u64(raw, 256)
    sysno = struct.unpack_from("<i", raw, 280)[0]
    summary.append("pt_regs=0x%x syscallno=%d sig=%d SP=0x%x ELR=0x%x LR=0x%x" % (
        pregs_addr, sysno, regs[2], sp, elr, regs[30]))

    # --- current task_struct via SP_EL0 ---
    task_ptr = None
    sp_el0_err = None
    try:
        task_ptr = int(gdb.parse_and_eval("$sp_el0")) & 0xFFFFFFFFFFFFFFFF
        summary.append("SP_EL0 (current task_struct?) = 0x%x" % task_ptr)
    except Exception as e:
        sp_el0_err = repr(e)
        summary.append("sp_el0 register read failed: %s" % sp_el0_err)
    if task_ptr is None:
        try:
            out = gdb.execute("info registers", to_string=True)
            m = re.search(r"SP_EL0\s+0x([0-9a-fA-F]+)", out, re.IGNORECASE)
            if m:
                task_ptr = int(m.group(1), 16)
                summary.append("SP_EL0 from info registers = 0x%x" % task_ptr)
            else:
                summary.append("SP_EL0 not found in info registers output")
        except Exception as e2:
            summary.append("info registers failed: %r" % (e2,))
    if task_ptr is None or TASK_MM_OFFSET is None or MM_PGD_OFFSET is None:
        summary.append("ABORT-WALK: task_ptr=%s offsets mm=%s pgd=%s" % (task_ptr, TASK_MM_OFFSET, MM_PGD_OFFSET))
        raise RuntimeError("missing task/mm/pgd inputs")

    # sanity: task_struct starts with thread_info; check comm field? just log first words
    task_head = kread(task_ptr, 64)
    summary.append("task_struct head words: %s" % " ".join("0x%x" % u64(task_head, i * 8) for i in range(4)))
    try:
        comm = bytes(kread(task_ptr + 2328, 16)).split(b"\x00")[0].decode("ascii", "replace")
        summary.append("task comm (offset 2328) = %r (expect 'init')" % comm)
    except Exception as e:
        summary.append("comm read failed: %r" % (e,))
    mm_ptr = u64(kread(task_ptr + TASK_MM_OFFSET, 8), 0)
    summary.append("task->mm = 0x%x" % mm_ptr)
    pgd_va = u64(kread(mm_ptr + MM_PGD_OFFSET, 8), 0)
    summary.append("mm->pgd (VA) = 0x%x" % pgd_va)

    # --- walk: L1 via gdb (kernel VA), L2/L3 via monitor xp (physical) ---
    def va_to_pa(va):
        # L1 entry from pgd VA (gdb read works for kernel VA)
        l1 = u64(kread(pgd_va + ((va >> 30) & 0x1FF) * 8, 8), 0)
        if (l1 & 0x3) == 0b11:
            table_pa = l1 & 0x0000FFFFFFFFF000
            l2 = read_phys(table_pa + ((va >> 21) & 0x1FF) * 8, 1)[0]
            if (l2 & 0x3) == 0b11:
                table2_pa = l2 & 0x0000FFFFFFFFF000
                l3 = read_phys(table2_pa + ((va >> 12) & 0x1FF) * 8, 1)[0]
                if (l3 & 0x3) == 0b11:
                    return (l3 & 0x0000FFFFFFFFF000) + (va & 0xFFF), "page L1=0x%x L2=0x%x L3=0x%x" % (l1, l2, l3)
                return None, "invalid L3 desc 0x%x" % l3
            if (l2 & 0x3) == 0b01:
                return (l2 & ~0x1FFFFF) + (va & 0x1FFFFF), "2MB block L2=0x%x" % l2
            return None, "invalid L2 desc 0x%x" % l2
        if (l1 & 0x3) == 0b01:
            return (l1 & ~0x3FFFFFFF) + (va & 0x3FFFFFFF), "1GB block L1=0x%x" % l1
        return None, "invalid L1 desc 0x%x" % l1

    elr_pa, elr_info = va_to_pa(elr - 4)
    summary.append("ELR-4 walk: %s" % (("pa 0x%x (%s)" % (elr_pa, elr_info)) if elr_pa is not None else ("FAILED: %s" % elr_info)))
    if elr_pa is not None:
        w = read_phys(elr_pa & ~0x7, 2)
        buf = b"".join(struct.pack("<Q", x) for x in w)
        off = (elr - 4) - (elr_pa & ~0x7)
        summary.append("bytes at ELR-4: %s" % buf[off:off + 8].hex())

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
    print("STACKWALK2-DONE sp=0x%x elr=0x%x pages=%d pgd=0x%x" % (sp, elr, npages_ok, pgd_va))
except Exception:
    log("STACKWALK2-EXCEPTION:\n" + traceback.format_exc())
    print("STACKWALK2-FAILED (see stackwalk2-python.log)")
