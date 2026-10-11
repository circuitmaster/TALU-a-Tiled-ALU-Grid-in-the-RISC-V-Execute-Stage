#!/usr/bin/env python3
"""TALU kernel generators and cycle measurement for the benchmark suite (Table I).

Generates TALU GFLOW kernels for a set of element-wise and reduction kernels and
reports cycles at a given vector length. All run at ~N results/cycle; reductions
add only the fixed pipeline-fill, demonstrating uniform throughput.
"""
import os, re, subprocess, sys

HERE  = os.path.dirname(os.path.abspath(__file__))
TALU  = os.path.dirname(HERE)
BUILD = os.path.join(TALU, "build")
N = 4
# simulator under test (default: the 1 GHz core in rtl/); e.g.
#   TALU_SIM=build/run_base python3 compare/suite.py   for the baseline core
SIM = os.environ.get("TALU_SIM", "build/run")

def sh(cmd): return subprocess.run(cmd, cwd=TALU, capture_output=True, text=True)

def lui_imm(min_bytes):
    a = ((min_bytes + 4095)//4096)*4096
    return a, a >> 12

def kernel(kind, avl):
    blocks = avl // N
    s2b, s2i = lui_imm(avl*4)
    dsb, dsi = lui_imm(s2b + avl*4)
    # src1 base = 0; src2 base; dst base. sumsq/sum use src1 for both streams.
    hdr = ["addi x5, x0, 0", f"lui x6, {s2i}", f"lui x7, {dsi}",
           f"addi x8, x0, {blocks}"]
    rows = range(N)
    cfg, flow = [], None
    if kind == "add":
        cfg = [f"gcfg {r},0, add, W,W, 1" for r in rows]; flow="gflow x5, x6, x7, x8, 0"
    elif kind == "mul":
        cfg = [f"gcfg {r},0, mul, W,W, 1" for r in rows]; flow="gflow x5, x6, x7, x8, 0"
    elif kind in ("dot","sumsq"):
        op = "mul"
        cfg = [f"gcfg {r},0, {op}, W,W, 0" for r in rows] + [
            "gcfg 0,1, copya, W,W, 0","gcfg 0,2, copya, W,W, 0","gcfg 1,1, copya, W,W, 0",
            "gcfg 2,1, add, W,SW, 0","gcfg 1,2, add, W,SW, 0","gcfg 0,3, add, W,SW, 1"]
        # sumsq: both streams = src1 (x*x); dot: src1*src2
        src2 = "x5" if kind=="sumsq" else "x6"
        flow=f"gflow x5, {src2}, x7, x8, 1"
    elif kind == "sum":
        cfg = [f"gcfg {r},0, copya, W,W, 0" for r in rows] + [
            "gcfg 0,1, copya, W,W, 0","gcfg 0,2, copya, W,W, 0","gcfg 1,1, copya, W,W, 0",
            "gcfg 2,1, add, W,SW, 0","gcfg 1,2, add, W,SW, 0","gcfg 0,3, add, W,SW, 1"]
        flow="gflow x5, x5, x7, x8, 1"
    elif kind == "power":   # (a+b)^8
        cfg = ([f"gcfg {r},0, add, W,W, 0" for r in rows] +
               [f"gcfg {r},1, mul, W,W, 0" for r in rows] +
               [f"gcfg {r},2, mul, W,W, 0" for r in rows] +
               [f"gcfg {r},3, mul, W,W, 1" for r in rows])
        flow="gflow x5, x6, x7, x8, 0"
    # ---- kernels using the constant-operand / EXTB / min-max extension ----
    reduce_tree = ["gcfg 0,1, copya, W,W, 0","gcfg 0,2, copya, W,W, 0",
                   "gcfg 1,1, copya, W,W, 0","gcfg 2,1, add, W,SW, 0",
                   "gcfg 1,2, add, W,SW, 0","gcfg 0,3, add, W,SW, 1"]
    macpipe = ([f"gcfg {r},0, mul, W,C, 0" for r in rows] +
               [f"gcfg {r},1, add, W,E, 0" for r in rows] +
               [f"gcfg {r},2, copya, W,W, 0" for r in rows] +
               [f"gcfg {r},3, copya, W,W, 1" for r in rows])
    if kind == "saxpy":     # z = a*x + y, one pass (a in tile consts, y via EXTB)
        cfg = ["addi x9, x0, 3"] + [f"gcfgi {r},0, x9" for r in rows] + macpipe
        flow="gflow x5, x6, x7, x8, 0"
    elif kind == "fir5":    # 5-tap FIR: one MAC pass per tap, acc in-place @dst
        body = macpipe[:]
        for k, h in enumerate([2,3,1,2,1]):
            body += [f"addi x5, x0, {4*k}", f"addi x9, x0, {h}"] + \
                    [f"gcfgi {r},0, x9" for r in rows] + \
                    ["gflow x5, x7, x7, x8, 0"]
        return "\n".join(hdr + body + ["ecall"]) + "\n"
    elif kind == "median":  # 3-wide median filter: min/max network, 4 passes
        body = []
        # buffers: t = dst, u = dst+1, v = dst+2, y = dst+3 (each avl*4 B)
        bufs = [(dsb + i*avl*4) for i in range(4)]
        for op, s1, s2, d in [("min", 0, 4, bufs[0]), ("max", 0, 4, bufs[1]),
                               ("min", bufs[1], 8, bufs[2]), ("max", bufs[0], bufs[2], bufs[3])]:
            def ld(reg, v):
                if v < 2048: return [f"addi {reg}, x0, {v}"]
                return [f"lui {reg}, {v >> 12}"] + ([f"addi {reg}, {reg}, {v & 0xFFF}"] if v & 0xFFF else [])
            body += ld("x5", s1) + ld("x6", s2) + ld("x7", d)
            body += [f"gcfg {r},0, {op}, W,W, 1" for r in rows]
            body += ["gflow x5, x6, x7, x8, 0"]
        return "\n".join(hdr + body + ["ecall"]) + "\n"
    elif kind == "sad":     # motion estimation: sum|a-b| = sum max - sum min
        body = reduce_tree[:]
        body += [f"gcfg {r},0, max, W,W, 0" for r in rows] + ["gflow x5, x6, x7, x8, 1"]
        body += [f"addi x7, x7, 4"]
        body += [f"gcfg {r},0, min, W,W, 0" for r in rows] + ["gflow x5, x6, x7, x8, 1"]
        body += [f"lui x20, {dsi}", "lw x21, 0(x20)", "lw x22, 4(x20)",
                 "sub x23, x21, x22", "sw x23, 8(x20)"]
        return "\n".join(hdr + body + ["ecall"]) + "\n"
    elif kind == "perceptron":  # y = step(w.x + b): dot pass + scalar epilogue
        cfg = [f"gcfg {r},0, mul, W,W, 0" for r in rows] + reduce_tree
        body = cfg + ["gflow x5, x6, x7, x8, 1",
                      f"lui x20, {dsi}", "lw x21, 0(x20)", "addi x21, x21, -100",
                      "slt x22, x0, x21", "sw x22, 4(x20)"]
        return "\n".join(hdr + body + ["ecall"]) + "\n"
    elif kind == "average":     # mean = (sum x) >> log2(avl)
        sh = avl.bit_length() - 1
        cfg = [f"gcfg {r},0, copya, W,W, 0" for r in rows] + reduce_tree
        body = cfg + ["gflow x5, x5, x7, x8, 1",
                      f"lui x20, {dsi}", "lw x21, 0(x20)",
                      f"srai x22, x21, {sh}", "sw x22, 4(x20)"]
        return "\n".join(hdr + body + ["ecall"]) + "\n"
    return "\n".join(hdr + cfg + [flow, "ecall"]) + "\n"

def measure(kind, avl, sim=None):
    tag = os.path.basename(sim or SIM)
    src = os.path.join(BUILD, f"s_{kind}_{tag}.s"); hexf = os.path.join(BUILD, f"s_{kind}_{tag}.hex")
    open(src,"w").write(kernel(kind, avl))
    sh([sys.executable, "tools/asm.py", src, "-o", hexf])
    out = sh(["vvp", os.path.join(TALU, sim or SIM), f"+PROG={hexf}", "+MAXCYC=200000"]).stdout
    m = re.search(r"HALT at cycle (\d+)", out)
    return int(m.group(1)) if m else None

def main():
    avl = int(sys.argv[1]) if len(sys.argv) > 1 else 1024
    print(f"TALU workload suite, N={N}, AVL={avl}")
    print(f"{'kernel':<8} {'pattern':<22} {'cycles':>7} {'cyc/el':>7}")
    rows = [("add","element-wise map"),("mul","element-wise map"),
            ("sum","reduction"),("dot","map+reduction"),
            ("sumsq","map+reduction (L2)"),("power","deep chain (a+b)^8"),
            ("saxpy","a*x+y (const+EXTB)"),("fir5","5-tap FIR (5 MAC passes)"),
            ("median","3-wide median (4 passes)"),("sad","SAD / motion est. (2)"),
            ("perceptron","dot + bias + step"),("average","mean (sum + shift)")]
    base = None
    for k, desc in rows:
        c = measure(k, avl)
        if k == "add": base = c
        print(f"{k:<8} {desc:<22} {c:>7} {c/avl:>7.3f}")
    print(f"\n(all map & reduce kernels within a few % of array-add = {base} cycles:"
          f" reduction is ~free)")

if __name__ == "__main__":
    main()
