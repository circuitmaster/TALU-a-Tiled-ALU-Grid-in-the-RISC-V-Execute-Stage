#!/usr/bin/env python3
"""Grid-size scaling: sweep N in {1,2,4,8}, measure add & dot throughput
(Table II, "add el/cyc" and "dot/add" columns).

For each N it copies the RTL to build/scal_src/, sets talu_pkg::GRID_N there,
rebuilds the simulator, verifies a small dot product, then measures array-add
and dot at the given AVL. The RTL in rtl/ is never modified.

  python3 compare/scaling.py [AVL] [--variant full|mulcol0|nomul]
    full     every tile has a multiplier (default)
    mulcol0  multipliers in column 0 only    (Table II "col-0 MUL only")
    nomul    no tile multipliers             (Table II "no MUL"; dot is n/a)
Writes results/scaling_<variant>.csv.
"""
import argparse, os, re, shutil, subprocess, sys

HERE  = os.path.dirname(os.path.abspath(__file__))
TALU  = os.path.dirname(HERE)
BUILD = os.path.join(TALU, "build")
# source dir under test; override to sweep a different core, e.g.
#   TALU_SRC=rtl_base python3 compare/scaling.py 1024
SRC   = os.environ.get("TALU_SRC", "rtl")
WORK  = os.path.join("build", "scal_src")          # private copy of the RTL
# per-tile multiplier mask; bit r*N+c is tile (r, c)
MASKS = {"full":    "'1",
         "mulcol0": "{GRID_N{ {(GRID_N-1){1'b0}}, 1'b1 }}",
         "nomul":   "'0"}

def sh(cmd): return subprocess.run(cmd, cwd=TALU, capture_output=True, text=True)

def set_N(n, variant="full"):
    shutil.rmtree(os.path.join(TALU, WORK), ignore_errors=True)
    shutil.copytree(os.path.join(TALU, SRC), os.path.join(TALU, WORK))
    pkg = os.path.join(TALU, WORK, "talu_pkg.sv")
    s = open(pkg).read()
    s, k = re.subn(r"parameter int GRID_N = \d+;", f"parameter int GRID_N = {n};", s)
    assert k == 1, "GRID_N not found in talu_pkg.sv"
    if variant != "full":
        s, k = re.subn(r"(MUL_MASK\s*=\s*)[^;]+;", rf"\g<1>{MASKS[variant]};", s)
        assert k == 1, "MUL_MASK not found in talu_pkg.sv"
    open(pkg, "w").write(s)

def build():
    r = sh(["bash","-c",f"iverilog -g2012 -I {WORK} -o build/run_scal tb/run_tb.sv "
                        f"{WORK}/*.sv 2>&1 | grep -v sorry"])
    return "error" not in r.stdout.lower()

def lui_imm(min_bytes):
    a = ((min_bytes + 4095)//4096)*4096
    return a >> 12

def add_kernel(N, avl):
    blocks = avl // N
    s2, ds = lui_imm(avl*4), lui_imm(2*avl*4)
    cfg = [f"gcfg {r},0, add, W,W, 1" for r in range(N)]
    cfg += ["nop"] * max(0, 3 - len(cfg))   # GFLOW operands are read unforwarded
    return "\n".join([f"addi x5,x0,0", f"lui x6,{s2}", f"lui x7,{ds}",
                      f"addi x8,x0,{blocks}"] + cfg + ["gflow x5,x6,x7,x8,0","ecall"])+"\n"

def reduce_cfg(N, col0):
    if N == 1:                            # degenerate: nothing to reduce
        return [f"gcfg 0,0, {col0}, W,W, 1", "nop", "nop"]
    cfg = [f"gcfg {r},0, {col0}, W,W, 0" for r in range(N)]
    for r in range(N-2):                  # carries
        for c in range(1, N-1-r):
            cfg.append(f"gcfg {r},{c}, copya, W,W, 0")
    for k in range(1, N):                 # diagonal reduce -> corner (0,N-1)
        cfg.append(f"gcfg {N-1-k},{k}, add, W,SW, {1 if k==N-1 else 0}")
    return cfg

def dot_kernel(N, avl, dst_word_addr):
    blocks = avl // N
    s2, ds = lui_imm(avl*4), lui_imm(2*avl*4)
    cfg = reduce_cfg(N, "mul")
    return "\n".join([f"addi x5,x0,0", f"lui x6,{s2}", f"lui x7,{ds}",
                      f"addi x8,x0,{blocks}"] + cfg + ["gflow x5,x6,x7,x8,1","ecall"])+"\n"

def asm_run(src_txt, name, dmem=None, maxc=50000):
    src = os.path.join(BUILD, f"{name}.s"); hexf = os.path.join(BUILD, f"{name}.hex")
    open(src,"w").write(src_txt)
    sh([sys.executable, "tools/asm.py", src, "-o", hexf])
    cmd = ["vvp", os.path.join(BUILD,"run_scal"), f"+PROG={hexf}", f"+MAXCYC={maxc}"]
    if dmem: cmd.append(f"+DMEM={dmem}")
    return sh(cmd).stdout

def verify_dot(N):
    # src1=src2=[1..2N] (2 blocks); dot = sum(i^2, i=1..2N). dst @ small addr.
    data = os.path.join(BUILD, "scale_data.hex")
    open(data,"w").write("\n".join(f"{i:08x}" for i in range(1,2*N+1))*1 + "\n")
    # write 2N words twice (src1 then src2 both = same array starting at 0): just one copy, src2=src1
    open(data,"w").write("\n".join(f"{i:08x}" for i in range(1,2*N+1)) + "\n")
    blocks = 2
    cfg = reduce_cfg(N, "mul")
    dstw = 4*N  # bytes -> word N
    txt = "\n".join([f"addi x5,x0,0", f"addi x7,x0,{dstw*4}", f"addi x8,x0,{blocks}"]
                    + cfg + ["gflow x5,x5,x7,x8,1","ecall"])+"\n"
    out = asm_run(txt, f"vdot{N}", dmem=data, maxc=2000)
    exp = sum(i*i for i in range(1, 2*N+1))
    m = re.search(rf"mem\[{dstw}\]=([0-9a-f]+)", out)
    got = int(m.group(1),16) if m else None
    return got, exp

def cyc(out):
    m = re.search(r"HALT at cycle (\d+)", out); return int(m.group(1)) if m else None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("avl", nargs="?", type=int, default=1024)
    ap.add_argument("--variant", choices=sorted(MASKS), default="full")
    a = ap.parse_args()
    avl, variant = a.avl, a.variant
    os.makedirs(BUILD, exist_ok=True)
    print(f"grid-size sweep, AVL={avl}, variant={variant}")
    print(f"{'N':>2} {'add':>7} {'dot':>7} {'add el/cyc':>10} {'dot/add':>8} {'dot ok':>8}")
    rows = []
    for N in ((1, 2, 4, 8) if variant == "full" else (4,)):
        set_N(N, variant)
        assert build(), f"build failed N={N}"
        got, exp = verify_dot(N)
        a = cyc(asm_run(add_kernel(N,avl), f"add{N}"))
        d = cyc(asm_run(dot_kernel(N,avl,0), f"dot{N}"))
        ok = got == exp
        okt = "yes" if ok else f"NO({got}!={exp})"
        print(f"{N:>2} {a:>7} {d:>7} {avl/a:>10.2f} {d/a:>7.2f}x {okt:>8}")
        # a dot product on a fabric without the needed multipliers is not a result
        rows.append([N, a, d if ok else "", f"{avl/a:.2f}", f"{d/a:.2f}" if ok else ""])
    out = os.path.join(TALU, "results", f"scaling_{variant}.csv")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as fh:
        fh.write("N,add_cycles,dot_cycles,add_el_per_cyc,dot_div_add\n")
        fh.writelines(",".join(map(str, r)) + "\n" for r in rows)
    print(f"wrote {os.path.relpath(out, TALU)}")

if __name__ == "__main__":
    main()
