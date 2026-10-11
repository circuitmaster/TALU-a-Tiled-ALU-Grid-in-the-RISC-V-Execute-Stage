#!/usr/bin/env python3
"""Vector-length, chain-depth and issue-bound sweeps (Sec. IV of the paper).

  avl       AVL sweep 8..4096 for map, reduction and segmented reduction
  chain     dependency-depth sweep 1..32 (grid vs scalar issue)
  redwidth  active reduction width 2..N
  issue     where the speedup comes from: scalar loop vs streaming on a
            single ALU (N=1) vs the N=4 grid (Sec. IV "Deep chaining")
All run on the current build (build/run); `issue` also builds an N=1 core.
"""
import math, os, re, subprocess, sys

# simulator under test (default: the 1 GHz core in rtl/); e.g. the baseline:
#   TALU_SIM=build/run_base python3 abl_scaling.py ...
SIM = os.environ.get("TALU_SIM", "build/run")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build/abl")
MAXCYC = 4_000_000


def grid_n():
    m = re.search(r"GRID_N\s*=\s*(\d+)", open(os.path.join(ROOT, "rtl/talu_pkg.sv")).read())
    return int(m.group(1))


def region(avl):                      # 4 KiB-aligned region per array, in bytes
    return ((avl * 4 + 4095) // 4096) * 4096


def li(reg, val):
    if -2048 <= val < 2048:
        return [f"addi {reg}, x0, {val}"]
    hi, lo = (val + 0x800) >> 12, ((val & 0xFFF) ^ 0x800) - 0x800
    return [f"lui {reg}, {hi}"] + ([f"addi {reg}, {reg}, {lo}"] if lo else [])


def emit(cfg, drain_rule=None):
    """Config block, padded so >=3 instructions separate the scalar setup from
    GFLOW -- its four register operands are read in ID without forwarding."""
    out = [f"gcfg {r},{c}, {op}, {sa},{sb}, {dr}" for (r, c), (op, sa, sb, dr)
           in sorted(cfg.items(), key=lambda t: (t[0][1], t[0][0]))]
    return out + ["nop"] * max(0, 3 - len(out))


def run(lines, name):
    os.makedirs(BUILD, exist_ok=True)
    s, h = f"{BUILD}/{name}.s", f"{BUILD}/{name}.hex"
    open(s, "w").write("\n".join(lines) + "\n")
    r = subprocess.run([sys.executable, "tools/asm.py", s, "-o", h],
                       cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        return None
    out = subprocess.run(["vvp", SIM, f"+PROG={h}", f"+MAXCYC={MAXCYC}"],
                         cwd=ROOT, capture_output=True, text=True).stdout
    m = re.search(r"HALT at cycle (\d+)", out)
    return int(m.group(1)) if m else None


# ----------------------------------------------------------------- AVL sweep
def k_map(avl, N):
    rg = region(avl)
    return (li("x5", 0) + li("x6", rg) + li("x7", 2 * rg) + li("x8", avl // N)
            + [f"gcfg {r},0, add, W,W, 1" for r in range(N)]
            + ["nop"] * max(0, 3 - N)
            + ["gflow x5, x6, x7, x8, 0", "ecall"])


def diag_tree(N, width=None):
    """anti-diagonal collapse of `width` rows (default all N) -> row 0."""
    w = width or N
    cfg = {}
    for k in range(1, w):
        cfg[(w - 1 - k, k)] = ("add", "W", "SW", 1 if k == w - 1 else 0)
        for r in range(0, w - 1 - k):
            cfg[(r, k)] = ("copya", "W", "W", 0)
    if w == 1:
        cfg[(0, 0)] = None                      # handled by caller
    return cfg


def k_reduce(avl, N, segmented=False, width=None):
    w = width or N
    rg = region(avl)
    cfg = {(r, 0): ("mul", "W", "W", 0) for r in range(w)}
    cfg.update({k: v for k, v in diag_tree(N, w).items() if v})
    if w == 1:
        cfg[(0, 0)] = ("mul", "W", "W", 1)
    return (li("x5", 0) + li("x6", rg) + li("x7", 2 * rg) + li("x8", avl // N)
            + emit(cfg) + [f"gflow x5, x6, x7, x8, {0 if segmented else 1}", "ecall"])


# -------------------------------------------------------------- chain sweep
def k_chain(depth, avl, N):
    """`depth` dependent ops: s=a+b then depth-1 squarings, split over passes."""
    rg = region(avl)
    lines = li("x8", avl // N)
    passes = math.ceil(depth / N)
    for p in range(passes):
        k = min(N, depth - p * N)
        cfg = {}
        op0 = "add" if p == 0 else "mul"
        for r in range(N):
            cfg[(r, 0)] = (op0, "W", "W", 0)
        for c in range(1, k):
            for r in range(N):
                cfg[(r, c)] = ("mul", "W", "W", 0)
        if k == 1:
            for r in range(N):
                cfg[(r, 0)] = (op0, "W", "W", 1)
        else:
            for c in range(k, N):               # route to a drainable perimeter
                for r in range(N):
                    cfg[(r, c)] = ("copya", "W", "W", 0)
            for r in range(N):
                o, sa, sb, _ = cfg[(r, N - 1)]
                cfg[(r, N - 1)] = (o, sa, sb, 1)
        src = 0 if p == 0 else (2 * rg if p % 2 == 1 else 3 * rg)
        src2 = rg if p == 0 else src
        dst = 2 * rg if p % 2 == 0 else 3 * rg
        lines += li("x5", src) + li("x6", src2) + li("x7", dst) + emit(cfg)
        lines += ["gflow x5, x6, x7, x8, 0"]
    return lines + ["ecall"]


def k_chain_scalar(depth, avl, N):
    rg = region(avl)
    body = (li("x10", 0) + li("x11", rg) + li("x12", 2 * rg) + li("x20", avl)
            + ["L:", "lw x13, 0(x10)", "lw x14, 0(x11)", "add x15, x13, x14"]
            + ["mul x15, x15, x15"] * (depth - 1)
            + ["sw x15, 0(x12)", "addi x10, x10, 4", "addi x11, x11, 4",
               "addi x12, x12, 4", "addi x20, x20, -1", "bne x20, x0, L"])
    return body + ["ecall"]


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "avl"
    N = grid_n()
    if what == "avl":
        print(f"AVL sweep, N={N}   (cycles, and cycles/element)")
        print(f"{'AVL':>6} {'map':>8} {'c/el':>7} {'reduce':>8} {'c/el':>7} {'segred':>8} {'c/el':>7}")
        for avl in (8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096):
            m = run(k_map(avl, N), f"avl_map_{avl}")
            d = run(k_reduce(avl, N), f"avl_red_{avl}")
            s = run(k_reduce(avl, N, segmented=True), f"avl_seg_{avl}")
            f = lambda c: f"{c/avl:.3f}" if c else "-"
            print(f"{avl:>6} {str(m):>8} {f(m):>7} {str(d):>8} {f(d):>7} {str(s):>8} {f(s):>7}")
    elif what == "chain":
        avl = 1024
        print(f"chain-depth sweep, N={N}, AVL={avl}")
        print(f"{'depth':>6} {'passes':>7} {'grid':>8} {'scalar':>9} {'speedup':>8} {'c/el':>7}")
        for d in (1, 2, 4, 8, 12, 16, 24, 32):
            g = run(k_chain(d, avl, N), f"chain_g{d}")
            s = run(k_chain_scalar(d, avl, N), f"chain_s{d}")
            sp = f"{s/g:.1f}x" if (g and s) else "-"
            print(f"{d:>6} {math.ceil(d/N):>7} {str(g):>8} {str(s):>9} {sp:>8} "
                  f"{(g/avl if g else 0):>7.3f}")
    elif what == "issue":
        avl = 1024
        sys.path.insert(0, os.path.join(ROOT, "compare"))
        import scaling                                # N=1 build, rtl/ untouched
        scalar = run(k_chain_scalar(1, avl, N), "issue_scalar")
        grid = run(k_map(avl, N), "issue_grid")
        scaling.set_N(1)
        assert scaling.build(), "N=1 build failed"
        one = scaling.cyc(scaling.asm_run(scaling.add_kernel(1, avl), "issue_n1"))
        print(f"vvadd, AVL={avl}: where the speedup over the scalar loop comes from")
        print(f"  scalar RV32IM loop (same core)   {scalar:>7} cycles  "
              f"(the loop of the chain sweep)")
        print(f"  streaming, one ALU (N=1)          {one:>7} cycles  "
              f"{scalar/one:>5.1f}x  <- removing the per-element issue bound")
        print(f"  streaming, N={N} grid              {grid:>7} cycles  "
              f"{one/grid:>5.1f}x more from width  ({scalar/grid:.1f}x total)")
    elif what == "redwidth":
        avl = 1024
        print(f"reduction-width sweep, N={N}, AVL={avl}")
        print(f"{'width':>6} {'cols':>5} {'tiles':>6} {'cycles':>8} {'elem/cyc':>9}")
        for w in range(2, N + 1):
            c = run(k_reduce(avl, N, width=w), f"redw_{w}")
            tiles = w + sum(1 for k in diag_tree(N, w).values() if k)
            useful = (avl // N) * w
            print(f"{w:>6} {max(w-1,0)+1:>5} {tiles:>6} {str(c):>8} "
                  f"{(useful/c if c else 0):>9.2f}")


if __name__ == "__main__":
    main()
