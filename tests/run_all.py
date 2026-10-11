#!/usr/bin/env python3
"""End-to-end self-checking harness for the TALU core.

Assembles each test program, runs it on the Verilog model (build/run), parses the
state dump, and checks expected scalar registers / data memory / vector registers.
"""
import os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")
# simulator binary; override with --sim <path> (e.g. build/run_base for rtl_base/)
RUN   = os.path.join(BUILD, "run")
if "--sim" in sys.argv:
    RUN = os.path.abspath(sys.argv[sys.argv.index("--sim") + 1])

def sh(cmd):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)

def write_hex(name, words):
    with open(os.path.join(BUILD, name), "w") as f:
        f.write("\n".join(f"{w & 0xffffffff:08x}" for w in words) + "\n")

def gen_data():
    os.makedirs(BUILD, exist_ok=True)
    # grid1/grid3 : v1=[1,2,3,4] @0, v2=[10,20,30,40] @16
    write_hex("grid1_data.hex", [1,2,3,4,10,20,30,40])
    # grid2 : a=100,c=5 @0 ; b=7 @16
    write_hex("grid2_data.hex", [100,5,0,0,7,0,0,0])
    # stream_add : src1=[1..16]@0, src2=[100..1600]@64(word16)
    write_hex("stream_add_data.hex", list(range(1,17)) + [100*i for i in range(1,17)])
    # stream_dot : src1=[1..8]@0, src2=[1..8]@32(word8)
    write_hex("stream_dot_data.hex", list(range(1,9)) + list(range(1,9)))
    # power : src1=[1,1,1,2]@0, src2=[1,2,3,2]@16(word4) -> s=[2,3,4,4]
    write_hex("power_data.hex", [1,1,1,2, 1,2,3,2])
    # suite : src1=[1..8]@0, src2=[1..8]@32(word8)
    write_hex("suite_data.hex", list(range(1,9)) + list(range(1,9)))
    # saxpy : x=[1..8]@0, y=[100..800]@32(word8)
    write_hex("saxpy_data.hex", list(range(1,9)) + [100*i for i in range(1,9)])
    # fir : x=[1..8]@0 (x[8..]=0)
    write_hex("fir_data.hex", list(range(1,9)))
    # median : x=[5,1,4,2,8,3,7,6]@0
    write_hex("median_data.hex", [5,1,4,2,8,3,7,6])
    # sad : a=[1..8]@0, b=[8,6,4,2,9,1,5,3]@32(word8)
    write_hex("sad_data.hex", list(range(1,9)) + [8,6,4,2,9,1,5,3])

def asm(src, hexout):
    r = sh([sys.executable, "tools/asm.py", f"tests/{src}", "-o", f"build/{hexout}"])
    if r.returncode: raise RuntimeError(f"asm failed for {src}:\n{r.stderr}")

def run(hexfile, dmem=None, maxcyc=2000):
    args = [RUN, f"+PROG=build/{hexfile}", f"+MAXCYC={maxcyc}"]
    if dmem: args.append(f"+DMEM=build/{dmem}")
    out = sh(["vvp"] + args).stdout
    st = {}
    for m in re.finditer(r'(x\d+|mem\[\d+\]|v\d+\[\d+\])=([0-9a-fA-F]+)', out):
        st[m.group(1)] = int(m.group(2), 16)
    st["_halt"] = "HALT" in out
    return st

TESTS = [
    # (name, src, dmem, expected dict)
    ("scalar1", "scalar1.s", None, {
        "x1":10,"x2":20,"x3":30,"x4":10,"x5":40,"x6":0,"x7":30,"x8":40,
        "x9":15,"x10":6,"x11":6,"x12":0xFFFFFFF5,"x13":8,
        "mem[0]":30,"mem[1]":15}),
    ("scalar2", "scalar2.s", None, {
        "x1":0x12345678,"x2":8,"x5":0x18,"x10":123,"x11":100,"x12":23,
        "x20":1,"x21":7,"x22":5}),
    ("grid1 (multi-path add)", "grid1.s", "grid1_data.hex", {
        "v1[0]":1,"v1[3]":4,"v2[0]":10,"v2[3]":40,
        "v3[0]":11,"v3[1]":22,"v3[2]":33,"v3[3]":44,
        "mem[8]":11,"mem[9]":22,"mem[10]":33,"mem[11]":44}),
    ("grid2 (vertical path)", "grid2.s", "grid2_data.hex", {
        "v3[0]":102,"v3[1]":0,"v3[2]":0,"v3[3]":0,"mem[8]":102}),
    ("grid3 (vertical reduction)", "grid3.s", "grid1_data.hex", {
        "v3[0]":10,"mem[8]":10}),
    # streaming kernels (GFLOW)
    ("stream_add (16 el)", "stream_add_small.s", "stream_add_data.hex", {
        "mem[32]":101,"mem[33]":202,"mem[35]":404,"mem[47]":1616}),
    ("stream_dot (8 el)", "stream_dot_small.s", "stream_dot_data.hex", {
        "mem[16]":204}),
    ("power (a+b)^8 grid", "power_grid_small.s", "power_data.hex", {
        "mem[8]":256, "mem[9]":6561, "mem[10]":65536, "mem[11]":65536}),
    ("suite sum", "suite_sum.s", "suite_data.hex", {"mem[16]":36}),
    ("suite sumsq (L2)", "suite_sumsq.s", "suite_data.hex", {"mem[16]":204}),
    ("suite mul", "suite_mul.s", "suite_data.hex", {
        "mem[16]":1, "mem[17]":4, "mem[23]":64}),
    # constant-operand / EXTB / min-max extension kernels
    ("stream_saxpy (a*x+y, 8 el)", "stream_saxpy_small.s", "saxpy_data.hex", {
        "mem[16]":103,"mem[17]":206,"mem[18]":309,"mem[19]":412,
        "mem[20]":515,"mem[21]":618,"mem[22]":721,"mem[23]":824}),
    ("stream_fir (5-tap, 8 el)", "stream_fir_small.s", "fir_data.hex", {
        "mem[16]":24,"mem[17]":33,"mem[18]":42,"mem[19]":51,
        "mem[20]":51,"mem[21]":41,"mem[22]":38,"mem[23]":16}),
    ("stream_median (3-wide, 8 el)", "stream_median_small.s", "median_data.hex", {
        "mem[56]":4,"mem[57]":2,"mem[58]":4,"mem[59]":3,
        "mem[60]":7,"mem[61]":6,"mem[62]":6,"mem[63]":0}),
    ("stream_sad (motion est., 8 el)", "stream_sad_small.s", "sad_data.hex", {
        "mem[16]":52,"mem[17]":22,"mem[18]":30}),
    ("stream_perceptron (8-in)", "stream_perceptron_small.s", "suite_data.hex", {
        "mem[16]":4,"mem[17]":1}),
]

def main():
    gen_data()
    fails = 0
    for name, src, dmem, exp in TESTS:
        hexf = src.replace(".s", ".hex")
        asm(src, hexf)
        st = run(hexf, dmem)
        bad = []
        if not st.get("_halt"): bad.append("did not HALT")
        for k, v in exp.items():
            if st.get(k) != v:
                bad.append(f"{k}={st.get(k):#x} exp={v:#x}" if st.get(k) is not None
                           else f"{k} missing")
        if bad:
            fails += 1
            print(f"FAIL  {name}")
            for b in bad: print(f"        {b}")
        else:
            print(f"PASS  {name}  ({len(exp)} checks)")
    print()
    print("ALL PROGRAM TESTS PASS" if fails == 0 else f"{fails} PROGRAM TEST(S) FAILED")
    sys.exit(1 if fails else 0)

if __name__ == "__main__":
    main()
