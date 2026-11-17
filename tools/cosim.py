#!/usr/bin/env python3
"""Differential test: cpu_core (Icarus Verilog) vs. the Unicorn x86 emulator.

For each seed a random program is generated from the instructions cpu_core
implements. The program is run on the RTL (sim/tb_cpu_cosim.v) and on Unicorn
(16-bit real mode); the register state after every instruction, every memory
write and every I/O access are then compared.

Requirements: iverilog, Python 3, `pip install unicorn`

Usage:
    python3 tools/cosim.py                 # 200 seeds
    python3 tools/cosim.py -n 1000         # more seeds
    python3 tools/cosim.py --seed 42       # reproduce one seed
    python3 tools/cosim.py --stall         # also insert random memory wait cycles
"""

import argparse
import multiprocessing
import os
import random
import shutil
import subprocess
import sys
import tempfile

try:
    from unicorn import Uc, UcError, UC_ARCH_X86, UC_MODE_16
    from unicorn import UC_HOOK_MEM_WRITE, UC_HOOK_INSN
    from unicorn.x86_const import (
        UC_X86_REG_AX, UC_X86_REG_CX, UC_X86_REG_DX, UC_X86_REG_BX,
        UC_X86_REG_SP, UC_X86_REG_BP, UC_X86_REG_SI, UC_X86_REG_DI,
        UC_X86_REG_IP, UC_X86_REG_EFLAGS, UC_X86_REG_ES, UC_X86_REG_CS,
        UC_X86_REG_SS, UC_X86_REG_DS, UC_X86_INS_IN, UC_X86_INS_OUT)
except ImportError:
    sys.exit("The 'unicorn' package is required:  pip install unicorn")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTL = ["sim/tb_cpu_cosim.v", "src/cpu_core.v", "src/alu.v",
       "src/register_file.v", "src/memory_controller.v"]

CODE_BASE = 0x0100          # program is placed at 0000:0100
DATA_SEGS = {"ds": 0x1000, "es": 0x2000, "ss": 0x3000}
DATA_LO, DATA_HI = 0x10000, 0x40100     # area pre-filled with random bytes
RESET_VECTOR = 0xFFFF0

REG_NAMES = ["ip", "ax", "cx", "dx", "bx", "sp", "bp", "si", "di",
             "flags", "es", "cs", "ss", "ds"]
UC_REGS = [UC_X86_REG_IP, UC_X86_REG_AX, UC_X86_REG_CX, UC_X86_REG_DX,
           UC_X86_REG_BX, UC_X86_REG_SP, UC_X86_REG_BP, UC_X86_REG_SI,
           UC_X86_REG_DI, UC_X86_REG_EFLAGS, UC_X86_REG_ES, UC_X86_REG_CS,
           UC_X86_REG_SS, UC_X86_REG_DS]


def le16(v):
    return bytes([v & 0xFF, (v >> 8) & 0xFF])


# =============================================================================
# Random program generator
# =============================================================================
class Item:
    """One generated instruction (or short fixed-size instruction sequence).

    `enc(target)` returns the bytes; `target` is the absolute offset of the
    instruction `skip` items further down (used by jumps and calls)."""

    def __init__(self, size, enc, skip=0):
        self.size, self.enc, self.skip = size, enc, skip


class ProgramGenerator:
    def __init__(self, rng):
        self.rng = rng

    # -- operand helpers ------------------------------------------------------
    def imm(self, word):
        r = self.rng
        v = r.choice([0, 1, 0x7F, 0x80, 0xFF, 0x7FFF, 0x8000, 0xFFFF,
                      r.getrandbits(16), r.getrandbits(16)])
        return le16(v) if word else bytes([v & 0xFF])

    def modrm(self, reg, mem=None, write=False):
        """Return (prefix, modrm+disp, is_mem) for a random r/m operand."""
        r = self.rng
        if mem is None:
            mem = r.random() < 0.6
        if not mem:
            return b"", bytes([0xC0 | (reg << 3) | r.randrange(8)]), False
        mod, rm = r.randrange(3), r.randrange(8)
        out = bytes([(mod << 6) | (reg << 3) | rm])
        if mod == 1:
            out += bytes([r.getrandbits(8)])
        elif mod == 2 or (mod == 0 and rm == 6):
            out += le16(r.getrandbits(16))
        prefix = b""
        if r.random() < 0.2:
            # CS: is only used for reads so the program never modifies itself
            prefix = bytes([r.choice([0x26, 0x36, 0x3E] if write
                                     else [0x26, 0x2E, 0x36, 0x3E])])
        return prefix, out, True

    def raw(self, data):
        data = bytes(data)
        return Item(len(data), lambda target: data)

    # -- instruction generators -----------------------------------------------
    def g_alu_rm_r(self):
        r = self.rng
        op, d, w = r.randrange(8), r.randrange(2), r.randrange(2)
        pfx, m, _ = self.modrm(r.randrange(8), write=(d == 0 and op != 7))
        return self.raw(pfx + bytes([(op << 3) | (d << 1) | w]) + m)

    def g_alu_acc_imm(self):
        r = self.rng
        op, w = r.randrange(8), r.randrange(2)
        return self.raw(bytes([(op << 3) | 4 | w]) + self.imm(w))

    def g_alu_rm_imm(self):
        r = self.rng
        opc = r.choice([0x80, 0x81, 0x83])
        op = r.randrange(8)
        pfx, m, _ = self.modrm(op, write=(op != 7))
        return self.raw(pfx + bytes([opc]) + m + self.imm(opc == 0x81))

    def g_test(self):
        r = self.rng
        kind, w = r.randrange(3), r.randrange(2)
        if kind == 0:
            pfx, m, _ = self.modrm(r.randrange(8))
            return self.raw(pfx + bytes([0x84 | w]) + m)
        if kind == 1:
            return self.raw(bytes([0xA8 | w]) + self.imm(w))
        pfx, m, _ = self.modrm(0)
        return self.raw(pfx + bytes([0xF6 | w]) + m + self.imm(w))

    def g_mov_rm_r(self):
        r = self.rng
        d, w = r.randrange(2), r.randrange(2)
        pfx, m, _ = self.modrm(r.randrange(8), write=(d == 0))
        return self.raw(pfx + bytes([0x88 | (d << 1) | w]) + m)

    def g_mov_r_imm(self):
        r = self.rng
        w = r.randrange(2)
        return self.raw(bytes([0xB0 | (w << 3) | r.randrange(8)]) + self.imm(w))

    def g_mov_rm_imm(self):
        w = self.rng.randrange(2)
        pfx, m, _ = self.modrm(0, write=True)
        return self.raw(pfx + bytes([0xC6 | w]) + m + self.imm(w))

    def g_mov_moffs(self):
        r = self.rng
        opc = 0xA0 | r.randrange(4)
        pfx = b""
        if r.random() < 0.2:
            pfx = bytes([r.choice([0x26, 0x36, 0x3E])])
        return self.raw(pfx + bytes([opc]) + le16(r.getrandbits(16)))

    def g_mov_rm_sreg(self):
        pfx, m, _ = self.modrm(self.rng.randrange(6), write=True)
        return self.raw(pfx + b"\x8C" + m)

    def g_mov_sreg_rm(self):
        """Load a segment register (DS/ES/SS keep their fixed test values)."""
        r = self.rng
        sreg = r.choice([0, 2, 3, 4, 5])
        value = {0: DATA_SEGS["es"], 2: DATA_SEGS["ss"],
                 3: DATA_SEGS["ds"]}.get(sreg, r.getrandbits(16))
        if r.randrange(2):  # MOV r16,value ; MOV sreg,r16
            reg = r.randrange(8)
            return self.raw(bytes([0xB8 | reg]) + le16(value) +
                            bytes([0x8E, 0xC0 | (sreg << 3) | reg]))
        addr = le16(r.getrandbits(16))  # MOV [addr],value ; MOV sreg,[addr]
        return self.raw(b"\xC7\x06" + addr + le16(value) +
                        bytes([0x8E, 0x06 | (sreg << 3)]) + addr)

    def g_lea(self):
        pfx, m, _ = self.modrm(self.rng.randrange(8), mem=True)
        return self.raw(pfx + b"\x8D" + m)

    def g_incdec_r16(self):
        return self.raw([0x40 | self.rng.randrange(16)])

    def g_incdec_rm(self):
        r = self.rng
        pfx, m, _ = self.modrm(r.randrange(2), write=True)
        return self.raw(pfx + bytes([0xFE | r.randrange(2)]) + m)

    def g_not_neg(self):
        r = self.rng
        pfx, m, _ = self.modrm(r.choice([2, 3]), write=True)
        return self.raw(pfx + bytes([0xF6 | r.randrange(2)]) + m)

    def g_push_pop(self):
        r = self.rng
        kind = r.randrange(3)
        if kind == 0:
            return self.raw([0x50 | r.randrange(8)])
        if kind == 1:
            return self.raw([0x58 | r.randrange(8)])
        pfx, m, _ = self.modrm(6)
        return self.raw(pfx + b"\xFF" + m)

    def g_flag(self):
        return self.raw([self.rng.choice([0xF5, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD])])

    def g_io(self):
        r = self.rng
        opc = r.choice([0xE4, 0xE5, 0xE6, 0xE7, 0xEC, 0xED, 0xEE, 0xEF])
        return self.raw([opc] + ([r.getrandbits(8)] if opc < 0xE8 else []))

    def g_nop(self):
        return self.raw([0x90])

    # -- control flow (targets are always further down the program) -----------
    def g_jcc(self):
        opc = 0x70 | self.rng.randrange(16)
        it = Item(2, None, self.rng.randrange(1, 4))
        it.enc = lambda t, it=it: bytes([opc, (t - it.addr - 2) & 0xFF])
        return it

    def g_loop(self):
        opc = 0xE0 | self.rng.randrange(4)
        it = Item(2, None, self.rng.randrange(1, 4))
        it.enc = lambda t, it=it: bytes([opc, (t - it.addr - 2) & 0xFF])
        return it

    def g_jmp(self):
        r = self.rng
        kind = r.randrange(6)
        skip = r.randrange(4)
        if kind == 0:       # JMP rel8
            it = Item(2, None, skip)
            it.enc = lambda t: bytes([0xEB, (t - it.addr - 2) & 0xFF])
        elif kind == 1:     # JMP rel16
            it = Item(3, None, skip)
            it.enc = lambda t: b"\xE9" + le16(t - it.addr - 3)
        elif kind == 2:     # JMP far 0000:target
            it = Item(5, None, skip)
            it.enc = lambda t: b"\xEA" + le16(t) + le16(0)
        elif kind == 3:     # MOV r16,target ; JMP r16
            reg = r.randrange(8)
            it = Item(5, None, skip)
            it.enc = lambda t: bytes([0xB8 | reg]) + le16(t) + bytes([0xFF, 0xE0 | reg])
        elif kind == 4:     # MOV [addr],target ; JMP [addr]
            addr = le16(r.getrandbits(16))
            it = Item(10, None, skip)
            it.enc = lambda t: (b"\xC7\x06" + addr + le16(t) + b"\xFF\x26" + addr)
        else:               # MOV AX,target ; PUSH AX ; RET
            it = Item(5, None, skip)
            it.enc = lambda t: b"\xB8" + le16(t) + b"\x50\xC3"
        return it

    def g_call(self):
        r = self.rng
        skip = r.randrange(4)
        kind = r.randrange(3)
        if kind == 0:       # CALL rel16
            it = Item(3, None, skip)
            it.enc = lambda t: b"\xE8" + le16(t - it.addr - 3)
        elif kind == 1:     # MOV [addr],target ; CALL [addr]
            addr = le16(r.getrandbits(16))
            it = Item(10, None, skip)
            it.enc = lambda t: (b"\xC7\x06" + addr + le16(t) + b"\xFF\x16" + addr)
        else:               # MOV r16,target ; CALL r16
            reg = r.randrange(8)
            it = Item(5, None, skip)
            it.enc = lambda t: bytes([0xB8 | reg]) + le16(t) + bytes([0xFF, 0xD0 | reg])
        return it

    def g_backward_loop(self):
        """MOV CX,n ; body ; LOOP body   (body never changes CX)"""
        r = self.rng
        body = r.choice([b"\x40", b"\x4A", b"\x81\xC3" + le16(r.getrandbits(16)),
                         b"\x00\xC4", b"\xFF\x07", b"\x53", b"\x18\x07"])
        opc = r.choice([0xE2, 0xE2, 0xE0, 0xE1])
        code = (b"\xB9" + le16(r.randrange(1, 6)) + body +
                bytes([opc, (-(len(body) + 2)) & 0xFF]))
        return self.raw(code)

    # -- whole program --------------------------------------------------------
    def generate(self, n_items):
        r = self.rng
        gens = [
            (self.g_alu_rm_r, 20), (self.g_alu_acc_imm, 5), (self.g_alu_rm_imm, 10),
            (self.g_test, 4), (self.g_mov_rm_r, 8), (self.g_mov_r_imm, 6),
            (self.g_mov_rm_imm, 4), (self.g_mov_moffs, 3), (self.g_mov_rm_sreg, 2),
            (self.g_mov_sreg_rm, 2),
            (self.g_lea, 3), (self.g_incdec_r16, 4), (self.g_incdec_rm, 4),
            (self.g_not_neg, 4), (self.g_push_pop, 8), (self.g_flag, 3),
            (self.g_io, 3), (self.g_nop, 1), (self.g_jcc, 10), (self.g_loop, 3),
            (self.g_jmp, 4), (self.g_call, 3), (self.g_backward_loop, 2),
        ]
        funcs = [g for g, _ in gens]
        weights = [wt for _, wt in gens]

        # Preamble: data segments and random initial register values
        pre = b""
        for seg_reg, name in ((0xD8, "ds"), (0xC0, "es"), (0xD0, "ss")):
            pre += b"\xB8" + le16(DATA_SEGS[name]) + bytes([0x8E, seg_reg])
        for reg in range(8):
            pre += bytes([0xB8 | reg]) + le16(r.getrandbits(16))

        items = [self.raw(pre)]
        items += [r.choices(funcs, weights)[0]() for _ in range(n_items)]

        addr = CODE_BASE
        for it in items:
            it.addr = addr
            addr += it.size
        end_addr = addr                 # HLT

        code = b""
        for i, it in enumerate(items):
            j = i + 1 + it.skip
            target = items[j].addr if j < len(items) else end_addr
            chunk = it.enc(target)
            assert len(chunk) == it.size
            code += chunk
        return code + b"\xF4"


def build_image(seed, n_items):
    """Return {address: byte} for the whole memory image of one test."""
    rng = random.Random(seed)
    code = ProgramGenerator(rng).generate(n_items)
    image = {}
    data = random.Random(seed ^ 0x5EED).randbytes(DATA_HI - DATA_LO)
    for i, b in enumerate(data):
        image[DATA_LO + i] = b
    for i, b in enumerate(code):
        image[CODE_BASE + i] = b
    # Reset vector: JMP FAR 0000:0100
    for i, b in enumerate(b"\xEA" + le16(CODE_BASE) + le16(0)):
        image[RESET_VECTOR + i] = b
    return image, code


def write_hex(image, path):
    with open(path, "w") as f:
        prev = None
        for addr in sorted(image):
            if prev is None or addr != prev + 1:
                f.write("@%x\n" % addr)
            f.write("%02x\n" % image[addr])
            prev = addr


# =============================================================================
# Trace records: (regs tuple, {addr: byte} memory writes, [io events])
# =============================================================================
def run_unicorn(image, max_insts):
    uc = Uc(UC_ARCH_X86, UC_MODE_16)
    uc.mem_map(0, 0x110000)
    addrs = sorted(image)
    start = 0
    for i in range(1, len(addrs) + 1):      # write contiguous runs
        if i == len(addrs) or addrs[i] != addrs[i - 1] + 1:
            uc.mem_write(addrs[start], bytes(image[a] for a in addrs[start:i]))
            start = i

    for reg in UC_REGS:
        uc.reg_write(reg, 0)
    uc.reg_write(UC_X86_REG_EFLAGS, 0x0002)
    uc.reg_write(UC_X86_REG_CS, 0xF000)

    trace = []
    cur = {"mem": {}, "io": []}

    def on_write(uc, access, address, size, value, user):
        for i in range(size):
            cur["mem"][(address + i) & 0xFFFFF] = (value >> (8 * i)) & 0xFF

    def on_in(uc, port, size, user):
        cur["io"].append(("I", port, size))
        return (~port) & ((1 << (8 * size)) - 1)

    def on_out(uc, port, size, value, user):
        cur["io"].append(("O", port, size, value & ((1 << (8 * size)) - 1)))

    uc.hook_add(UC_HOOK_MEM_WRITE, on_write)
    uc.hook_add(UC_HOOK_INSN, on_in, None, 1, 0, UC_X86_INS_IN)
    uc.hook_add(UC_HOOK_INSN, on_out, None, 1, 0, UC_X86_INS_OUT)

    # Single-step so that the flags are fully evaluated after every
    # instruction. (Running freely with a UC_HOOK_CODE hook is faster, but
    # Unicorn 2.1 then reports wrong flags after LOOPE/LOOPNE.)
    pc = RESET_VECTOR
    try:
        for _ in range(max_insts):
            is_hlt = uc.mem_read(pc, 1)[0] == 0xF4
            uc.emu_start(pc, 0x10FFFF, count=1)
            regs = tuple(uc.reg_read(r) & 0xFFFF for r in UC_REGS)
            trace.append((regs, cur["mem"], cur["io"]))
            cur["mem"], cur["io"] = {}, []
            if is_hlt:
                break
            pc = (uc.reg_read(UC_X86_REG_CS) << 4) + uc.reg_read(UC_X86_REG_IP)
    except UcError as e:
        return trace, str(e)
    return trace, None


def run_rtl(sim, image, workdir, stall_seed, max_cycles):
    hex_path = os.path.join(workdir, "prog.hex")
    trace_path = os.path.join(workdir, "rtl.trace")
    write_hex(image, hex_path)
    cmd = ["vvp", "-n", sim, "+hex=" + hex_path, "+trace=" + trace_path,
           "+maxcycles=%d" % max_cycles]
    if stall_seed is not None:
        cmd.append("+stall=%d" % stall_seed)
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, timeout=300)

    trace, end = [], "?"
    mem, io = {}, []
    with open(trace_path) as f:
        for line in f:
            p = line.split()
            if p[0] == "W":
                addr, size, data = int(p[1], 16), int(p[2]), int(p[3], 16)
                for i in range(size):
                    mem[(addr + i) & 0xFFFFF] = (data >> (8 * i)) & 0xFF
            elif p[0] == "O":
                io.append(("O", int(p[1], 16), int(p[2]), int(p[3], 16)))
            elif p[0] == "I":
                io.append(("I", int(p[1], 16), int(p[2])))
            elif p[0] == "R":
                trace.append((tuple(int(x, 16) for x in p[1:]), mem, io))
                mem, io = {}, []
            else:
                end = line.strip()
    return trace, end


def fmt_regs(regs):
    return " ".join("%s=%04x" % (n, v) for n, v in zip(REG_NAMES, regs))


def compare(image, rtl, rtl_end, ref, ref_error):
    """Return None when the traces match, otherwise a description."""
    def code_at(regs):
        base = (regs[REG_NAMES.index("cs")] << 4) + regs[0]
        return " ".join("%02x" % image.get((base + i) & 0xFFFFF, 0) for i in range(8))

    prev = None
    for i in range(max(len(rtl), len(ref))):
        msg = None
        if i >= len(rtl):
            msg = "RTL stopped early (%s)" % rtl_end
        elif i >= len(ref):
            msg = "RTL executed extra instructions"
        else:
            for what, k in (("registers", 0), ("memory writes", 1), ("I/O", 2)):
                if rtl[i][k] != ref[i][k]:
                    msg = "%s differ" % what
                    break
        if msg:
            out = ["instruction #%d: %s" % (i, msg)]
            if prev is not None:
                out.append("  before : %s" % fmt_regs(prev))
                out.append("  code   : %s" % code_at(prev))
            for name, tr in (("RTL    ", rtl), ("Unicorn", ref)):
                if i < len(tr):
                    out.append("  %s: %s" % (name, fmt_regs(tr[i][0])))
                    if tr[i][1] or tr[i][2]:
                        out.append("           mem=%s io=%s" % (
                            {("%05x" % a): ("%02x" % b) for a, b in sorted(tr[i][1].items())},
                            tr[i][2]))
            return "\n".join(out)
        prev = ref[i][0]

    if ref_error:
        return "Unicorn error: %s (generator produced a bad program?)" % ref_error
    if rtl_end != "H":
        return "RTL did not stop with HLT (%s)" % rtl_end
    return None


def run_seed(job):
    """Run one seed on both models. Returns (seed, instructions, error or None)."""
    seed, insts, stall, sim, work = job
    max_insts = insts * 12 + 100
    workdir = os.path.join(work, "seed%d" % seed)
    os.mkdir(workdir)
    image, _ = build_image(seed, insts)
    ref, ref_error = run_unicorn(image, max_insts)
    rtl, rtl_end = run_rtl(sim, image, workdir, seed if stall else None,
                           max_cycles=max_insts * 40)
    shutil.rmtree(workdir)
    return seed, len(ref), compare(image, rtl, rtl_end, ref, ref_error)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("-n", "--num", type=int, default=200, help="number of seeds")
    ap.add_argument("--seed", type=int, help="run only this seed")
    ap.add_argument("--start", type=int, default=1, help="first seed")
    ap.add_argument("--insts", type=int, default=150, help="instructions per program")
    ap.add_argument("--stall", action="store_true",
                    help="insert random memory wait cycles in the RTL simulation")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count(),
                    help="parallel simulations (default: number of CPUs)")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="also list the seeds that passed")
    args = ap.parse_args()

    seeds = [args.seed] if args.seed is not None else range(args.start, args.start + args.num)

    with tempfile.TemporaryDirectory() as work:
        sim = os.path.join(work, "tb_cpu_cosim.out")
        subprocess.run(["iverilog", "-I", "src", "-o", sim] + RTL, cwd=ROOT, check=True)

        jobs = [(seed, args.insts, args.stall, sim, work) for seed in seeds]
        with multiprocessing.Pool(args.jobs) as pool:
            failed, total_insts = [], 0
            for seed, n_insts, result in pool.imap(run_seed, jobs):
                total_insts += n_insts
                if result:
                    failed.append(seed)
                    print("FAIL seed %d\n%s" % (seed, result))
                elif args.verbose:
                    print("PASS seed %d (%d instructions)" % (seed, n_insts))

    print("=" * 60)
    print("cosim: %d seeds, %d instructions compared, %d failed%s" % (
        len(seeds), total_insts, len(failed), " [stall]" if args.stall else ""))
    if failed:
        print("failed seeds: %s" % " ".join(map(str, failed[:20])))
        sys.exit(1)
    print("*** ALL TESTS PASSED ***")


if __name__ == "__main__":
    main()
