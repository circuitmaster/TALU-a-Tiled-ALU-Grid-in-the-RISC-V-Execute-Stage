// talu_mul_tb.sv -- self-checking testbench for the 1 GHz tile multiplier
// (rtl/ only): radix-4 Booth rows -> stage-1 3:2 tree -> stage-2 sum, checked
// against a*b (low 32 bits) on
//   * every pair in 0..63 x 0..63,
//   * all (2^i, 2^j) and (2^i-1, 2^j-1) corner pairs, signed extremes,
//   * 20k random pairs.
// The pipeline register between the two stages is left out: it does not
// change the arithmetic, and the tile testbench checks the timing.
`timescale 1ns/1ps
`include "talu_pkg.sv"
`include "talu_mul_pkg.sv"

module talu_mul_tb;
  import talu_mul_pkg::*;

  localparam int W   = 32;
  localparam int NPP = W/2 + 1;
  localparam int MR1 = csa_rows(NPP, MUL_S1_LV);

  logic [W-1:0]       a, b, y;
  logic [NPP*W-1:0]   pp;
  logic [MR1*W-1:0]   rows;

  booth_pp #(.W(W)) u_pp (.a(a), .b(b), .rows(pp));
  csa_tree #(.W(W), .NIN(NPP), .LV(MUL_S1_LV), .NOUT(MR1))
    u_s1 (.in_rows(pp), .out_rows(rows));
  csa_sum  #(.W(W), .NIN(MR1)) u_s2 (.rows(rows), .y(y));

  int errors = 0, checks = 0;

  task automatic chk(logic [W-1:0] x, logic [W-1:0] z);
    logic [W-1:0] exp;
    a = x; b = z; #1;
    exp = x * z;
    checks++;
    if (y !== exp) begin
      if (errors < 10) $display("FAIL %08h * %08h = %08h exp %08h", x, z, y, exp);
      errors++;
    end
  endtask

  initial begin
    for (int i = 0; i < 64; i++)
      for (int j = 0; j < 64; j++) chk(i, j);
    for (int i = 0; i < W; i++)
      for (int j = 0; j < W; j++) begin
        chk(32'd1 << i, 32'd1 << j);
        chk((32'd1 << i) - 1, (32'd1 << j) - 1);
      end
    chk(32'h8000_0000, 32'h8000_0000);
    chk(32'h8000_0000, 32'hFFFF_FFFF);
    chk(32'hFFFF_FFFF, 32'hFFFF_FFFF);
    chk(32'h7FFF_FFFF, 32'h7FFF_FFFF);
    chk(32'h7FFF_FFFF, 32'h8000_0000);
    for (int k = 0; k < 20000; k++) chk($urandom, $urandom);

    if (errors == 0) $display("TALU_MUL_TB PASS (%0d vectors)", checks);
    else             $display("TALU_MUL_TB FAIL (%0d of %0d)", errors, checks);
    $finish;
  end
endmodule
