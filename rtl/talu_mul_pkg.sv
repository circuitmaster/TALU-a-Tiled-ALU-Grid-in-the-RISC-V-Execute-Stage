// talu_mul_pkg.sv
// Constant functions for the carry-save (3:2) trees used by the pipelined tile
// multiplier and the GFLOW accumulator. Kept out of talu_pkg.sv on purpose:
// the 45 nm flow swaps talu_pkg.sv per build configuration, this file is
// shared by all of them.
`ifndef TALU_MUL_PKG_SV
`define TALU_MUL_PKG_SV

`include "talu_pkg.sv"

package talu_mul_pkg;

  // Written Verilog-2001 style (integer, assign-to-name, no return / loop-
  // local declarations): the most portable form of constant function across
  // DC, synlig, iverilog and Verilator.

  // rows left after one level of 3:2 compressors (row-wise Wallace)
  function automatic integer csa_next(input integer n);
    csa_next = (n <= 2) ? n : 2*(n/3) + (n%3);
  endfunction

  // rows left after `lv` levels
  function automatic integer csa_rows(input integer n, input integer lv);
    integer i, m;
    begin
      m = n;
      for (i = 0; i < lv; i = i + 1) m = csa_next(m);
      csa_rows = m;
    end
  endfunction

  // levels needed to reach two rows (bounded loop)
  function automatic integer csa_levels(input integer n);
    integer i, m, l;
    begin
      m = n; l = 0;
      for (i = 0; i < 64; i = i + 1)
        if (m > 2) begin m = csa_next(m); l = l + 1; end
      csa_levels = l;
    end
  endfunction

  // Tile multiplier pipeline cut: number of 3:2 levels in stage 1.
  // Radix-4 Booth on 32 bits gives 16 partial-product rows + 1 negate-
  // correction row = 17 rows; 17 -> 12 -> 8 -> 6 -> 4 | 4 -> 3 -> 2 -> CPA.
  // Budget from the report's NanGate45 DC paths (clk->Q 0.10, operand mux
  // 0.08, Booth select 0.21, FA level 0.13, 32-bit CPA 0.38, setup +
  // uncertainty 0.08 ns):
  //   cut after 3 levels: stage 1 0.86 ns, stage 2 1.02 ns  (stage 2 fails)
  //   cut after 4 levels: stage 1 0.99 ns, stage 2 0.89 ns  <- chosen
  // and 4 rows (128 flops) are cheaper to stage than 6 (192).
  localparam int MUL_S1_LV = 4;

endpackage

`endif
