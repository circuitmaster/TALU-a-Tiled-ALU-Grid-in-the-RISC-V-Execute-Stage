# The 1 GHz core (`rtl/`) and how it differs from the baseline (`rtl_base/`)

`rtl/` is the core every result in the paper uses. It is the baseline core
retimed for a 1.0 ns clock on FreePDK45/NanGate, without changing what TALU
is: the N×N grid is still the execute stage, tile (0,0) is still the scalar
ALU (scalar MUL included), the grid still advances one systolic step per
clock, and the ISA, encodings, assembler, kernels and compiler output are
unchanged.

Only `core.sv`, `alu_tile.sv` and `alu_grid.sv` differ from `rtl_base/`, plus
two new files for the multiplier (`talu_mul_pkg.sv`, `talu_mul.sv`).
`talu_pkg.sv` is identical, which is why the 45 nm builds could swap it per
configuration (grid size, multiplier mask, diagonals, drain adder).

## Changes

| # | change |
|---|---|
| T1 | **Two-stage tiles, multiplier cut inside its carry-save tree.** Stage 1: operand muxes, every non-multiply ALU op, radix-4 Booth (17 rows) and 4 levels of 3:2 compression down to 4 rows. Stage 2: 2 more 3:2 levels, one 32-bit CPA, result select. Cutting after 4 levels (not 3) balances the two stages. |
| T2 | **Forwarding decided in ID**, registered one-hot; in EX it is a single AND-OR in front of tile (0,0)'s ALU. LUI and link values (pc+4) are produced by the ALU, so there is no result mux after it. |
| T3 | **Scalar MUL in 3 cycles on tile (0,0)'s own multiplier**: operands go to the row-0 injection registers, then through the tile's two stages. |
| T4 | **Registered branch redirect**: resolved in EX, applied the next cycle; ECALL halts from EX. |
| T5 | **GFLOW control flags precomputed into flops** (inject / B-fetch / output / last), down-counters, registered injection. |
| T6 | **Carry-save GFLOW accumulator**: drained lanes registered, accumulator kept as two rows, one CPA only at write-back. |
| T7 | **Path latency / EXTB column derived per column** (OR over rows, N-input priority scan) instead of a running maximum over N² tiles. |

## Behavioural differences

Every program in `tests/` and every kernel in the paper computes identical
results on both cores (`make programs`). Two-stage tiles change exactly two
corner cases of the streaming semantics, which no kernel and no compiler
output uses (`compiler/mapc.py` cannot emit N/S sources):

1. Inside `GFLOW`, an N/S operand reads the neighbour **two** blocks back
   instead of one.
2. EXTB taps or drains in more than one column are skewed by 2 steps per
   column instead of 1.

## Cycle cost of the retiming

| | baseline | 1 GHz | |
|---|---:|---:|---:|
| all ten Table I kernels, AVL=1024 | 4954 | 5041 | +1.8 % |
| same, AVL=64 | 639 | 726 | +13.6 % |
| same, AVL=4096 | 18778 | 18865 | +0.5 % |

Grid code pays the deeper fill once per `GFLOW` pass, so the cost vanishes
with vector length (`make table1`, `make numbers`). Scalar code
pays +1 cycle per taken branch (T4) and +2 per MUL (T3).

Post-route, the baseline closes 424 MHz at a relaxed 2.5 ns target (a lower
bound, the run was not pushed) and the 1 GHz core 1032 MHz at 1.0 ns, for
4474 → 6898 flops, +54 % (Sec. V of the paper).
