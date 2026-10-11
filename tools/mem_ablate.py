#!/usr/bin/env python3
"""Memory-system realism ablations (Sec. IV "Memory model" of the paper).

Captures a real vector-memory access trace per kernel from cycle-accurate RTL
simulation (+MEMTRACE), then replays it through a banked-scratchpad timing
model: finite bandwidth, word-interleaved banks (plain or XOR-swizzled) and
access latency.
"""
import math, os, re, subprocess, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "compare"))
from mem_model import load, words_of

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build/abl")
N, AVL = 4, 1024
import suite as S                                   # compare/suite.py generators

# simulator under test (default: the 1 GHz core in rtl/); e.g. the baseline:
#   TALU_SIM=build/run_base python3 mem_ablate.py ...
SIM = os.environ.get("TALU_SIM", "build/run")

KERNELS = [("vvadd", "add"), ("dot", "dot"), ("saxpy", "saxpy"),
           ("fir5", "fir5"), ("sad", "sad"), ("segdot", None)]


def segdot_src(avl):
    rg = ((avl * 4 + 4095) // 4096) * 4096
    hi = lambda v: v >> 12
    return "\n".join(
        [f"addi x5, x0, 0", f"lui x6, {hi(rg)}", f"lui x7, {hi(2*rg)}",
         f"addi x8, x0, {avl//N}"] +
        [f"gcfg {r},0, mul, W,W, 0" for r in range(N)] +
        ["gcfg 0,1, copya, W,W, 0", "gcfg 0,2, copya, W,W, 0",
         "gcfg 1,1, copya, W,W, 0", "gcfg 2,1, add, W,SW, 0",
         "gcfg 1,2, add, W,SW, 0",  "gcfg 0,3, add, W,SW, 1"] +
        ["gflow x5, x6, x7, x8, 0", "ecall"]) + "\n"


def capture(name, kind):
    os.makedirs(BUILD, exist_ok=True)
    src = segdot_src(AVL) if kind is None else S.kernel(kind, AVL)
    s, h, t = f"{BUILD}/m_{name}.s", f"{BUILD}/m_{name}.hex", f"{BUILD}/m_{name}.trace"
    open(s, "w").write(src)
    subprocess.run([sys.executable, "tools/asm.py", s, "-o", h], cwd=ROOT,
                   capture_output=True)
    out = subprocess.run(["vvp", SIM, f"+PROG={h}", "+MAXCYC=400000",
                          f"+MEMTRACE={t}"], cwd=ROOT, capture_output=True,
                         text=True).stdout
    m = re.search(r"HALT at cycle (\d+)", out)
    return (int(m.group(1)) if m else None), load(t)


def bank_of(addr, banks, swizzle):
    if not swizzle:
        return addr % banks
    k = banks.bit_length() - 1
    return (addr ^ (addr >> k)) % banks


def sim(rows, ideal, bw=None, banks=None, lat=1, swizzle=False):
    stall = 0
    for r in rows:
        w = words_of(r, N)
        if not w:
            continue
        need = 1
        if bw:
            need = max(need, math.ceil(len(w) / bw))
        if banks:
            c = {}
            for a in w:
                b = bank_of(a, banks, swizzle)
                c[b] = c.get(b, 0) + 1
            need = max(need, max(c.values()))
        stall += need - 1
    return ideal + stall + max(0, lat - 1)


def words_off(row, n, offB, offW):
    """Word addresses in one GFLOW cycle, with stream-B and the write stream
    shifted by offB / offW WORDS -- i.e. staggered base addresses. Shifting a
    whole array's base is exactly a constant offset on every address it
    generates, so this models placement without regenerating the kernels."""
    _, aA, aAd, bA, bAd, wA, wAd, wM = row
    w = []
    if aA: w += [aAd // 4 + i for i in range(n)]
    if bA: w += [bAd // 4 + offB + i for i in range(n)]
    if wA: w += [wAd // 4 + offW + i for i in range(n) if (wM >> i) & 1]
    return w


def sim_off(rows, ideal, offB, offW, bw, banks, lat):
    stall = 0
    for r in rows:
        w = words_off(r, N, offB, offW)
        if not w:
            continue
        need = max(1, math.ceil(len(w) / bw)) if bw else 1
        cnt = {}
        for a in w:
            cnt[a % banks] = cnt.get(a % banks, 0) + 1
        need = max(need, max(cnt.values()))
        stall += need - 1
    return ideal + stall + max(0, lat - 1)


def stagger_study(traces, banks=16, bw=3*N, lat=4, span=8):
    """naive power-of-two-aligned placement vs the best base-address stagger."""
    print(f"\n=== 6. placement: naive vs staggered ({banks} banks, BW={bw}, "
          f"{lat}-cycle latency) ===")
    print(f"{'kernel':<9}{'ideal':>7}{'naive':>9}{'best':>9}{'offsets(B,W)':>15}")
    offs = [N * k for k in range(span)]
    for name, (ideal, rows) in traces.items():
        naive = sim_off(rows, ideal, 0, 0, bw, banks, lat)
        best, bo = None, None
        for ob in offs:
            for ow in offs:
                c = sim_off(rows, ideal, ob, ow, bw, banks, lat)
                if best is None or c < best:
                    best, bo = c, (ob, ow)
        print(f"{name:<9}{ideal:>7}{naive:>9} ({naive/ideal:.2f}x)"
              f"{best:>6} ({best/ideal:.2f}x){str(bo):>12}")


def main():
    data = {}
    print("capturing traces ...", flush=True)
    for name, kind in KERNELS:
        ideal, rows = capture(name, kind)
        wpc = max((len(words_of(r, N)) for r in rows), default=0)
        data[name] = (ideal, rows, wpc)
        print(f"  {name:<8} ideal={ideal:>6}  traced cycles={len(rows):>5}  peak words/cyc={wpc}")

    print(f"\n=== 1. bandwidth sweep (words/cycle; N={N}, peak demand 3N=12) ===")
    bws = [2, 4, 8, 12, 16]
    print(f"{'kernel':<8}" + "".join(f"{f'{b}w':>9}" for b in bws) + f"{'ideal':>9}")
    for name, (ideal, rows, _) in data.items():
        row = "".join(f"{sim(rows, ideal, bw=b):>9}" for b in bws)
        print(f"{name:<8}{row}{ideal:>9}")

    print(f"\n=== 2. bank-count sweep (unlimited bandwidth) ===")
    bks = [4, 8, 16, 32]
    print(f"{'kernel':<8}" + "".join(f"{f'{b}b':>8}" for b in bks)
          + "   |" + "".join(f"{f'{b}b^':>8}" for b in bks))
    for name, (ideal, rows, _) in data.items():
        a = "".join(f"{sim(rows, ideal, banks=b):>8}" for b in bks)
        x = "".join(f"{sim(rows, ideal, banks=b, swizzle=True):>8}" for b in bks)
        print(f"{name:<8}{a}   |{x}")

    print(f"\n=== 3. latency sweep (cycles; bandwidth and banks ideal) ===")
    lats = [1, 2, 4, 8, 16]
    print(f"{'kernel':<8}" + "".join(f"{f'{l}c':>8}" for l in lats))
    for name, (ideal, rows, _) in data.items():
        print(f"{name:<8}" + "".join(f"{sim(rows, ideal, lat=l):>8}" for l in lats))

    print(f"\n=== 4. ideal vs realistic banked TCDM (32 banks XOR, BW=3N, 4-cycle) ===")
    print(f"{'kernel':<8}{'ideal':>8}{'banked':>9}{'slowdown':>10}")
    for name, (ideal, rows, _) in data.items():
        b = sim(rows, ideal, bw=12, banks=32, lat=4, swizzle=True)
        print(f"{name:<8}{ideal:>8}{b:>9}{b/ideal:>9.2f}x")

    print(f"\n=== 5. roofline: achieved elements/cycle vs bandwidth ===")
    print(f"{'kernel':<8}{'w/elem':>7}" + "".join(f"{f'{b}w':>8}" for b in bws)
          + f"{'  peak':>8}")
    for name, (ideal, rows, _) in data.items():
        tot = sum(len(words_of(r, N)) for r in rows)
        wpe = tot / AVL
        cells = "".join(f"{AVL/sim(rows, ideal, bw=b):>8.2f}" for b in bws)
        print(f"{name:<8}{wpe:>7.1f}{cells}{AVL/ideal:>8.2f}")

    stagger_study({k: (v[0], v[1]) for k, v in data.items()})
    min_bandwidth({k: (v[0], v[1]) for k, v in data.items()})


# kernel -> its row in results/table1.csv (written by compare/table1.py)
TABLE1_ROW = {"vvadd": "vvadd", "dot": "dot product", "saxpy": "saxpy",
              "fir5": "FIR (5-tap)", "sad": "SAD"}


def min_bandwidth(traces):
    """Smallest memory bandwidth (words/cycle) at which TALU still beats the
    faster of the two vector baselines on each kernel."""
    path = os.path.join(ROOT, "results", "table1.csv")
    if not os.path.exists(path):
        print("\n(7. skipped: run compare/table1.py first for baseline cycles)")
        return
    import csv
    base = {}
    for r in csv.DictReader(open(path)):
        vals = [int(r[c]) for c in ("riscv2", "vicuna") if r[c]]
        if vals:
            base[r["kernel"]] = min(vals)
    print(f"\n=== 7. lowest bandwidth that still beats the best baseline ===")
    print(f"{'kernel':<8}{'baseline':>9}{'min BW':>8}{'= xN':>7}{'TALU cyc':>10}")
    worst = 0
    for name, (ideal, rows) in traces.items():
        b = base.get(TABLE1_ROW.get(name))
        if not b:
            continue
        bw = next(w for w in range(1, 3 * N + 1) if sim(rows, ideal, bw=w) < b)
        worst = max(worst, bw)
        print(f"{name:<8}{b:>9}{bw:>8}{bw/N:>7.2f}{sim(rows, ideal, bw=bw):>10}")
    print(f"every advantage holds down to {worst} words/cycle = {worst/N:.2f}N")


if __name__ == "__main__":
    main()
