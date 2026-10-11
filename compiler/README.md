# TALU auto-mapping compiler

Compiles ordinary C loops to TALU grid configurations, so kernels no longer
have to be hand-written as `GCFG`/`GFLOW` assembly.

```
   C source            LLVM IR              kernel descriptor        TALU program
 ┌──────────┐  clang  ┌────────┐  TALUMap  ┌─────────────────┐ mapc ┌───────────┐
 │ for (i)  │────────>│  loop  │──────────>│ expression DAG, │─────>│ GCFGI     │
 │  d[i]=…  │   -O1   │  + IR  │   pass    │ streams, consts │  .py │ GCFG ×k   │
 └──────────┘         └────────┘           └─────────────────┘      │ GFLOW     │
                                                                    └───────────┘
```

* **`TALUMap.cpp`** — an out-of-tree LLVM pass (new PM plugin). Finds functions
  marked `__attribute__((annotate("talu")))`, locates the innermost loop,
  extracts the loop-body expression DAG over the streamed loads and constants,
  classifies it as a *map* (stores to an array) or a *reduction* (accumulator
  phi), and writes a JSON kernel descriptor.
* **`mapc.py`** — the mapper. Schedules the DAG onto tiles, picks operand
  sources, materializes the reduction tree, and emits TALU assembly.
* **`taluc`** — driver that chains clang → `opt` → `mapc.py`.
* **`verify.py`** — end-to-end verification (below).

## Quick start

```sh
make                                   # build TALUMap.so (needs LLVM 20 dev)
./taluc kernels/suite.c --list         # what maps, and how many tiles it uses
./taluc kernels/suite.c --kernel dot --avl 1024 -o dot.s
python3 verify.py                      # correctness + cycle parity
```

## How the mapping works

A tile is one operation plus two operand sources, and every tile is registered,
so **DAG depth becomes grid columns**:

* each internal DAG node is scheduled to `column = depth(node) - 1`, which turns
  a dependent expression chain into a column pipeline (one result/cycle/row);
* an operand that is an inner node comes from the **West** neighbour;
* a constant leaf is written into the tile's constant register with `GCFGI`
  and selected as source **C**;
* a stream leaf is a column-0 West injection, or — when the consuming tile sits
  in a later column — the delayed stream-B tap, source **E** (the hardware
  derives the tap column from the configuration and delays the fetch to match);
* a **reduction** appends the anti-diagonal `W+SW` collapse to tile `(0,N-1)`
  in the columns after the compute, and runs `GFLOW` in accumulate mode;
* element-wise results are routed with `COPYA` to a drainable perimeter tile.

Example — `s += a[i] * b[i]` compiles to exactly the hand-written dot product:
column 0 multiplies lane-wise, `(2,1)`/`(1,2)`/`(0,3)` form the diagonal tree,
copies carry the untouched rows, and `(0,3)` drains.

## What is supported

| form | example | result |
|------|---------|--------|
| element-wise, two streams | `d[i] = a[i] + b[i]` | col 0, drain |
| element-wise, min/max | `d[i] = a[i] < b[i] ? a[i] : b[i]` | col 0, drain |
| constant operand | `d[i] = a[i] * 5` | `MUL(W,C)` |
| fused MAC | `d[i] = 3*x[i] + y[i]` | `MUL(W,C)` → `ADD(W,E)` |
| deep chain | `s=a+b; s*=s; s*=s; s*=s;` | one op per column |
| reduction | `s += a[i] * b[i]` | compute + diagonal tree, accumulate |

Ops: `add sub mul and or xor shl min max`.

Kernels that do not fit are **rejected with a reason**, never mis-compiled:

```
  median3      UNSUPPORTED: 3 input streams; GFLOW provides 2
                            (multi-pass lowering is future work)
```

Other rejections: expression deeper than `N` columns, a reduction whose compute
does not leave room for the tree, stream B tapped in more than one column.

## Verification

`verify.py` never uses the compiler as its own reference. It compiles the same
C natively (`gcc -fwrapv`), runs both on identical data, and compares every
output word — so a mis-extracted DAG or a mis-scheduled tile is a mismatch, not
a silent pass. It then re-runs at AVL=1024 and compares cycle counts against the
hand-written kernels of `compare/suite.py`, measured on the same simulator
(cycle counts below are for the 1 GHz core in `rtl/`).

```
=== correctness (AVL=64): host C vs TALU grid ===      === cycles at AVL=1024 ===
  vvadd  PASS    vmax    PASS    dot    PASS             kernel   compiled  hand
  vmul   PASS    scale   PASS    vsum   PASS             vvadd    273       273
  vsub   PASS    saxpy   PASS    sumsq  PASS             vmul     273       273
  vmin   PASS    power8  PASS    median3 rejected        saxpy    296       296
                                                         power8   291       291
ALL COMPILER TESTS PASS                                  dot      287       287
                                                         vsum     287       287
                                                         sumsq    287       287
```

**Every kernel with a hand-written counterpart compiles to the same cycle
count** — the compiled configurations are tile-for-tile identical to the
hand-written ones (`tools/map_ablate.py` diffs them tile by tile).
`vsub`/`vmin`/`vmax` (273) and `scale` (278) are new kernels
with no hand-written pair.

## Limitations (and what comes next)

* **Single streaming pass only.** Kernels needing several passes over memory
  (FIR with per-tap accumulation, the median min/max network, SAD) are
  rejected; they are still hand-written in `tests/`. Multi-pass lowering is the
  next step.
* **Annotation required.** Loops must be marked `talu`; recognizing the idioms
  in unannotated C (SCEV + pattern matching) is future work.
* **Canonical loop forms.** The pass matches the `-O1` shape: one innermost
  loop, unit stride, arrays addressed by the induction variable, `int` data.
* **Fixed layout.** `mapc.py` assigns each pointer argument its own
  4 KiB-aligned region; there is no allocator or calling convention yet, so the
  generated program is a standalone kernel rather than a callable function.

## Requirements

LLVM/clang 20 with development headers (`llvm-config` at
`/usr/lib/llvm-20/bin/`; override with `LLVM_CONFIG=`), Python 3, `gcc` for the
reference, and the TALU simulator (`iverilog`).
