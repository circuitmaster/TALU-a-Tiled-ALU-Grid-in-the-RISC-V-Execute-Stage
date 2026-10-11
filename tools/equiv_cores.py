#!/usr/bin/env python3
"""Architectural equivalence of the two cores on every paper kernel.

Runs each Table I kernel (compare/suite.py) and four scalar loops on both
rtl_base/ (build/run_base) and rtl/ (build/run) with the same seeded random
input data, and diffs the full architectural state: x1-x31, the output
region of data memory, and every vector register. Equal cycle counts are
never taken as evidence; only equal state is.

  usage: python3 tools/equiv_cores.py [--avl 64] [--seeds 3]
"""
import argparse, os, random, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build", "equiv")
sys.path.insert(0, os.path.join(ROOT, "compare"))
import suite  # noqa: E402

CORES = [("rtl_base", "build/run_base"), ("rtl", "build/run")]
KERNELS = ["add", "mul", "sum", "dot", "sumsq", "power", "saxpy", "fir5",
           "median", "sad", "perceptron", "average"]


def scalar_loop(kind, avl):
    """Scalar RV32IM loops over the same arrays (src1 @0, src2 @4K, dst @8K)."""
    op = {"sadd": ["add x20, x17, x19"],
          "smul": ["mul x20, x17, x19"],
          "spow": ["add x20, x17, x19"] + ["mul x20, x20, x20"] * 3}[kind]
    return "\n".join(["addi x10, x0, 0", f"addi x11, x0, {avl}", "lui x12, 1",
                      "lui x13, 2", "L:", "slli x15, x10, 2", "lw x17, 0(x15)",
                      "add x18, x15, x12", "lw x19, 0(x18)"] + op +
                     ["add x21, x15, x13", "sw x20, 0(x21)", "addi x10, x10, 1",
                      "blt x10, x11, L", "ecall"]) + "\n"


def run(sim, hexf, dmem, base, n):
    out = subprocess.run(["vvp", os.path.join(ROOT, sim), f"+PROG={hexf}",
                          f"+DMEM={dmem}", "+MAXCYC=400000", "+DUMP=1",
                          f"+DUMPBASE={base}", f"+DUMPN={n}"],
                         cwd=ROOT, capture_output=True, text=True).stdout
    if not re.search(r"HALT at cycle \d+", out):
        return None
    st = {}
    for line in out.splitlines():
        m = re.match(r"(x\d+|mem\[\d+\]|v\d+\[\d+\])=([0-9a-fA-F]+)$", line.strip())
        if m:
            st[m.group(1)] = m.group(2)
    return st


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--avl", type=int, default=64)
    ap.add_argument("--seeds", type=int, default=3)
    a = ap.parse_args()
    os.makedirs(BUILD, exist_ok=True)
    for _, sim in CORES:
        if not os.path.exists(os.path.join(ROOT, sim)):
            sys.exit(f"{sim} missing -- run `make sim` first")

    # suite.py layout: src1 at 0, src2 and dst on the next 4 KiB boundaries
    region = ((a.avl * 4 + 4095) // 4096) * 4096 // 4          # in words
    dst, ndump = 2 * region, 4 * a.avl          # covers median's 4 buffers
    progs = [(k, suite.kernel(k, a.avl)) for k in KERNELS] + \
            [(k, scalar_loop(k, a.avl)) for k in ("sadd", "smul", "spow")]
    fails = 0
    for seed in range(a.seeds):
        rng = random.Random(seed)
        dmem = os.path.join(BUILD, f"data_{seed}.hex")
        with open(dmem, "w") as f:      # small signed values in both sources
            f.writelines(f"{rng.randint(-50, 50) & 0xFFFFFFFF:08x}\n"
                         for _ in range(dst))
        for name, src in progs:
            s, h = os.path.join(BUILD, f"{name}.s"), os.path.join(BUILD, f"{name}.hex")
            open(s, "w").write(src)
            subprocess.run([sys.executable, "tools/asm.py", s, "-o", h],
                           cwd=ROOT, check=True, capture_output=True)
            st = {c: run(sim, h, dmem, dst, ndump) for c, sim in CORES}
            ref, new = st["rtl_base"], st["rtl"]
            if ref is None or new is None:
                print(f"  seed {seed}  {name:<11} DID NOT HALT"); fails += 1; continue
            diff = [k for k in sorted(set(ref) | set(new))
                    if k != "x0" and ref.get(k) != new.get(k)]
            nz = sum(1 for k, v in ref.items() if k.startswith("mem") and int(v, 16))
            tag = "identical" if not diff else f"DIFF at {len(diff)}: {diff[:6]}"
            print(f"  seed {seed}  {name:<11} {tag:<12} ({len(ref)} locations, "
                  f"{nz} non-zero output words)")
            fails += bool(diff)
    print(f"\n{'ALL KERNELS: IDENTICAL ARCHITECTURAL STATE' if not fails else f'{fails} MISMATCH(ES)'}"
          f" on rtl_base/ and rtl/ (AVL={a.avl}, {a.seeds} data seeds)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
