#!/usr/bin/env python3
"""verify.py -- end-to-end check of the TALU auto-mapping compiler.

For every kernel the compiler maps, this compares two independent executions of
the *same C source*:

  reference : the C compiled natively (gcc -fwrapv) and run on the host
  TALU      : the LLVM pass + mapc.py configuration, assembled and simulated
              cycle-accurately on the TALU RTL

A kernel passes only if every output word matches. The compiler is never its
own reference: the expected values come from the C semantics, so a mis-extracted
DAG or a mis-scheduled tile shows up as a mismatch.

Finally, cycle counts at AVL=1024 are compared against the hand-written kernels
of compare/suite.py, measured on the same simulator -- the compiler should not
cost cycles.

usage: python3 verify.py [--avl 64] [--keep]
"""
import argparse, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(HERE, "build")
N = 4

# compiled kernel -> its hand-written equivalent in compare/suite.py
HANDWRITTEN = {"vvadd": "add", "vmul": "mul", "vsum": "sum", "dot": "dot",
               "sumsq": "sumsq", "power8": "power", "saxpy": "saxpy"}
sys.path.insert(0, os.path.join(ROOT, "compare"))
import suite  # noqa: E402  (hand-written kernel generators)


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def datum(arg, i):
    """Deterministic test data, identical on both sides."""
    return ((i * 7 + arg * 13) % 61) - 30


def region_words(avl):
    return (((avl * 4 + 4095) // 4096) * 4096) // 4


# ------------------------------------------------------------------ reference
def build_reference(kernels, avl):
    """Generate + build a host driver that runs the same C on the same data."""
    src = ['#include <stdio.h>', '#include <string.h>', '#include <stdlib.h>',
           f'#define MAXN {avl}',
           '#include "kernels/suite.c"',
           'static int R[8][MAXN];',
           'int main(int argc, char **argv) {',
           '  const char *k = argv[1]; int n = atoi(argv[2]);',
           '  for (int a = 0; a < 8; a++) for (int i = 0; i < n; i++)',
           '    R[a][i] = ((i * 7 + a * 13) % 61) - 30;',
           '  int s = 0, have_s = 0, dst = -1;']
    for k in kernels:
        ptrs = ", ".join(f"R[{i}]" for i in range(k["nargs_ptr"]))
        call = f'{k["name"]}({ptrs}, n)'
        if k["pattern"] == "reduce":
            body = f'{{ s = {call}; have_s = 1; }}'
        else:
            body = f'{{ {call}; dst = {k["dst_arg"]}; }}'
        src.append(f'  if (!strcmp(k, "{k["name"]}")) {body} else')
    src += ['  { fprintf(stderr, "unknown kernel %s\\n", k); return 2; }',
            '  if (have_s) printf("%d\\n", s);',
            '  else for (int i = 0; i < n; i++) printf("%d\\n", R[dst][i]);',
            '  return 0;', '}']
    path = os.path.join(BUILD, "ref.c")
    open(path, "w").write("\n".join(src) + "\n")
    r = sh(["gcc", "-O1", "-fwrapv", "-I", HERE, path, "-o",
            os.path.join(BUILD, "ref")], cwd=HERE)
    if r.returncode:
        sys.exit("reference build failed:\n" + r.stderr)


def reference(name, avl):
    r = sh([os.path.join(BUILD, "ref"), name, str(avl)])
    if r.returncode:
        sys.exit(f"reference run failed for {name}:\n{r.stderr}")
    return [int(x) for x in r.stdout.split()]


# ----------------------------------------------------------------- TALU side
def write_dmem(path, k, avl):
    """Lay the input arrays out exactly as mapc.py addresses them."""
    rw = region_words(avl)
    words = []
    for arg in range(k["nargs_ptr"]):
        base = arg * rw
        while len(words) < base:
            words.append(0)
        if arg != k.get("dst_arg"):
            words += [datum(arg, i) & 0xFFFFFFFF for i in range(avl)]
    open(path, "w").write("\n".join(f"{w:08x}" for w in words) + "\n")


def run_talu(k, avl, maxcyc=200000):
    name = k["name"]
    s_path = os.path.join(BUILD, f"{name}.s")
    hex_path = os.path.join(BUILD, f"{name}.hex")
    dmem_path = os.path.join(BUILD, f"{name}_data.hex")

    r = sh([os.path.join(HERE, "taluc"), os.path.join(HERE, "kernels/suite.c"),
            "--kernel", name, "--avl", str(avl), "-o", s_path])
    if r.returncode or not os.path.exists(s_path):
        return None, None, f"taluc failed: {r.stderr.strip()}"
    r = sh([sys.executable, os.path.join(ROOT, "tools/asm.py"), s_path,
            "-o", hex_path])
    if r.returncode:
        return None, None, f"asm failed: {r.stderr.strip()}"
    write_dmem(dmem_path, k, avl)

    rw = region_words(avl)
    dst_word = (k["dst_arg"] if k["pattern"] == "map" else k["nargs_ptr"]) * rw
    n_dump = avl if k["pattern"] == "map" else 1
    r = sh(["vvp", os.path.join(ROOT, "build/run"), f"+PROG={hex_path}",
            f"+DMEM={dmem_path}", f"+MAXCYC={maxcyc}",
            f"+DUMPBASE={dst_word}", f"+DUMPN={n_dump}"], cwd=ROOT)
    out = r.stdout
    m = re.search(r"HALT at cycle (\d+)", out)
    if not m:
        return None, None, "simulation did not halt"
    mem = {}
    for mm in re.finditer(r"mem\[(\d+)\]=([0-9a-fA-F]+)", out):
        v = int(mm.group(2), 16)
        mem[int(mm.group(1))] = v - (1 << 32) if v >> 31 else v
    got = [mem.get(dst_word + i) for i in range(n_dump)]
    return got, int(m.group(1)), None


# ----------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--avl", type=int, default=64)
    ap.add_argument("--cycles-avl", type=int, default=1024)
    a = ap.parse_args()
    os.makedirs(BUILD, exist_ok=True)

    # always rebuild: a stale simulator silently invalidates every result
    print("building the TALU simulator ...")
    rb = sh(["iverilog", "-g2012", "-I", "rtl", "-o", "build/run", "tb/run_tb.sv"]
            + sorted("rtl/" + f for f in os.listdir(os.path.join(ROOT, "rtl"))),
            cwd=ROOT)
    if rb.returncode:
        sys.exit("simulator build failed:\n" + rb.stderr)

    # 1. compile the C -> kernel descriptors
    r = sh([os.path.join(HERE, "taluc"), os.path.join(HERE, "kernels/suite.c"),
            "--list"])
    rejected = [l.strip() for l in r.stderr.splitlines() if "UNSUPPORTED" in l]
    js = os.path.join(BUILD, "suite.talu.json")
    if not os.path.exists(js):
        sys.exit("compiler produced no kernel descriptors:\n" + r.stderr)
    kernels = json.load(open(js))["kernels"]

    build_reference(kernels, max(a.avl, a.cycles_avl))

    # 2. correctness: host C vs TALU simulation
    print(f"\n=== correctness (AVL={a.avl}): host C vs TALU grid ===")
    fails = 0
    ok_kernels = []
    for k in kernels:
        name = k["name"]
        got, cycles, err = run_talu(k, a.avl)
        if err:
            if any(name in l for l in rejected):
                print(f"  {name:<10} skipped (not mappable)")
            else:
                print(f"  {name:<10} FAIL  {err}")
                fails += 1
            continue
        exp = reference(name, a.avl)
        if k["pattern"] == "reduce":
            exp = [exp[0] & 0xFFFFFFFF]
            exp = [exp[0] - (1 << 32) if exp[0] >> 31 else exp[0]]
        if got == exp:
            print(f"  {name:<10} PASS  ({len(exp)} value(s), {cycles} cycles)")
            ok_kernels.append(k)
        else:
            bad = [(i, g, e) for i, (g, e) in enumerate(zip(got, exp)) if g != e]
            print(f"  {name:<10} FAIL  {len(bad)} mismatch(es), first: "
                  f"idx {bad[0][0]} got {bad[0][1]} exp {bad[0][2]}")
            fails += 1

    for l in rejected:
        print(f"  {l}")

    # 3. cycles vs the hand-written kernels
    print(f"\n=== cycles at AVL={a.cycles_avl}: compiled vs hand-written ===")
    print(f"  {'kernel':<10} {'compiled':>9} {'hand':>6} {'delta':>7}")
    for k in ok_kernels:
        name = k["name"]
        _, cyc, err = run_talu(k, a.cycles_avl)
        if err:
            print(f"  {name:<10} {'ERR':>9}  {err}")
            fails += 1
            continue
        if name in HANDWRITTEN:
            hn = HANDWRITTEN[name]
            hc = suite.measure(hn, a.cycles_avl, "build/run")
            d = cyc - hc
            tag = "same" if d == 0 else f"{d:+d}"
            print(f"  {name:<10} {cyc:>9} {hc:>6} {tag:>7}   (hand: {hn})")
            if d != 0:
                fails += 1
        else:
            print(f"  {name:<10} {cyc:>9} {'-':>6} {'-':>7}   (no hand-written pair)")

    print()
    print("ALL COMPILER TESTS PASS" if fails == 0 else f"{fails} FAILURE(S)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
