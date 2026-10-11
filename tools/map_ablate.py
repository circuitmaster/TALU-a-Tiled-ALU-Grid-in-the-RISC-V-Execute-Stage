#!/usr/bin/env python3
"""Compiled vs hand-written mappings, and where the cycles go (Sec. III-B).

  1. hand-written vs LLVM-compiled mappings: cycles, tiles, and a tile-by-tile
     configuration diff (not just "same cycle count")
  2. where the cycles go: setup, configuration, fill, steady state, drain
"""
import os, re, subprocess, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "compare"))
import suite as S

# simulator under test (default: the 1 GHz core in rtl/); e.g. the baseline:
#   TALU_SIM=build/run_base python3 map_ablate.py ...
SIM = os.environ.get("TALU_SIM", "build/run")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build/abl")
N = 4
# compiled kernel  ->  hand-written equivalent in compare/suite.py
PAIRS = [("vvadd", "add"), ("vmul", "mul"), ("dot", "dot"), ("vsum", "sum"),
         ("sumsq", "sumsq"), ("saxpy", "saxpy"), ("power8", "power")]

GCFG = re.compile(r'^\s*gcfg\s+(\d+)\s*,\s*(\d+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\d+)')
GCFGI = re.compile(r'^\s*gcfgi\s+(\d+)\s*,\s*(\d+)\s*,\s*(\w+)')
SETUP = re.compile(r'^\s*(addi|lui|li|mv|add|sub|slt|srai|slli|lw|sw)\b')


def parse(src):
    """-> (tile config dict, const tiles, #config instrs, #scalar instrs, #gflow)"""
    cfg, consts, ncfg, nscal, ngf = {}, {}, 0, 0, 0
    for ln in src.splitlines():
        ln = ln.split('#')[0]
        m = GCFG.match(ln)
        if m:
            r, c, op, sa, sb, dr = m.groups()
            cfg[(int(r), int(c))] = (op, sa.upper(), sb.upper(), int(dr)); ncfg += 1; continue
        m = GCFGI.match(ln)
        if m:
            r, c, _ = m.groups(); consts[(int(r), int(c))] = True; ncfg += 1; continue
        if ln.strip().startswith('gflow'): ngf += 1; continue
        if SETUP.match(ln): nscal += 1
    return cfg, consts, ncfg, nscal, ngf


def run(src, name, util=False):
    os.makedirs(BUILD, exist_ok=True)
    s, h = f"{BUILD}/{name}.s", f"{BUILD}/{name}.hex"
    open(s, "w").write(src if src.endswith("\n") else src + "\n")
    r = subprocess.run([sys.executable, "tools/asm.py", s, "-o", h], cwd=ROOT,
                       capture_output=True, text=True)
    if r.returncode:
        return None, None
    cmd = ["vvp", SIM, f"+PROG={h}", "+MAXCYC=400000"] + (["+UTIL=1"] if util else [])
    out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True).stdout
    cyc = re.search(r"HALT at cycle (\d+)", out)
    u = re.search(r"UTIL total=(\d+) busy=(\d+) run=(\d+) tilecyc=(\d+) tiles=(\d+) t0=(\d+) t1=(\d+)", out)
    return (int(cyc.group(1)) if cyc else None,
            tuple(int(x) for x in u.groups()) if u else None)


def compiled(kernel, avl):
    out = f"{BUILD}/c_{kernel}.s"
    r = subprocess.run([os.path.join(ROOT, "compiler/taluc"),
                        os.path.join(ROOT, "compiler/kernels/suite.c"),
                        "--kernel", kernel, "--avl", str(avl), "-o", out],
                       cwd=ROOT, capture_output=True, text=True)
    return open(out).read() if os.path.exists(out) else None


def main():
    avl = int(sys.argv[1]) if len(sys.argv) > 1 else 1024
    print(f"=== 1. hand-written vs LLVM-compiled mapping (AVL={avl}) ===\n")
    print(f"{'kernel':<9}{'hand cyc':>9}{'auto cyc':>9}{'Δ':>4}"
          f"{'hand tiles':>11}{'auto tiles':>11}{'cfg instr':>11}{'config diff':>13}")
    for comp, hand in PAIRS:
        hs = S.kernel(hand, avl)
        cs = compiled(comp, avl)
        if cs is None:
            print(f"{comp:<9} compiler produced nothing"); continue
        hc, _ = run(hs, f"h_{hand}")
        cc, _ = run(cs, f"a_{comp}")
        hcfg, hco, hn, _, _ = parse(hs)
        ccfg, cco, cn, _, _ = parse(cs)
        same = "identical" if (hcfg == ccfg and set(hco) == set(cco)) else "DIFFERS"
        if same == "DIFFERS":
            d = set(hcfg.items()) ^ set(ccfg.items())
            same = f"{len(d)} tile(s)"
        d = (cc - hc) if (hc and cc) else None
        print(f"{comp:<9}{str(hc):>9}{str(cc):>9}{str(d):>4}"
              f"{len(hcfg):>11}{len(ccfg):>11}{f'{hn}/{cn}':>11}{same:>13}")

    print(f"\n=== 2. where the cycles go (AVL={avl}) ===\n")
    print(f"{'kernel':<9}{'total':>7}{'setup+cfg':>10}{'stream':>8}{'drain':>7}"
          f"{'  cfg instr':>11}{'overhead%':>10}")
    for comp, hand in PAIRS:
        src = S.kernel(hand, avl)
        cyc, u = run(src, f"p_{hand}", util=True)
        if not u:
            continue
        tot, busy, runc, tc, tiles, t0, t1 = u
        _, _, ncfg, nscal, ngf = parse(src)
        stream = t1 - t0 + 1
        print(f"{hand:<9}{cyc:>7}{t0:>10}{stream:>8}{cyc - t1 - 1:>7}"
              f"{f'{nscal}+{ncfg}':>11}{100*(cyc-stream)/cyc:>9.1f}%")

    print(f"\n=== 2b. configuration overhead amortization (array add) ===\n")
    print(f"{'AVL':>6}{'total':>7}{'setup+cfg':>10}{'stream':>8}{'overhead%':>10}"
          f"{'cyc/elem':>9}")
    for a in (8, 32, 128, 512, 1024, 4096):
        cyc, u = run(S.kernel("add", a), f"am_{a}", util=True)
        if not u:
            continue
        tot, busy, runc, tc, tiles, t0, t1 = u
        stream = t1 - t0 + 1
        print(f"{a:>6}{cyc:>7}{t0:>10}{stream:>8}{100*(cyc-stream)/cyc:>9.1f}%{cyc/a:>9.3f}")


if __name__ == "__main__":
    main()
