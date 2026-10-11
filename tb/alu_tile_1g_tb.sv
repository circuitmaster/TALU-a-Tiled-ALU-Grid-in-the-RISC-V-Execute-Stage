// alu_tile_1g_tb.sv -- self-checking testbench for the two-stage tile of the
// 1 GHz core (rtl/alu_tile.sv). Every op, multiply included, takes exactly
// two `step`s from operands to reg_y; comb_y is the stage-1 ALU result
// (0 for MUL, whose product only exists after stage 2).
// The baseline single-stage tile is covered by alu_tile_tb.sv (rtl_base/).
`timescale 1ns/1ps
`include "talu_pkg.sv"
`include "talu_mul_pkg.sv"

module alu_tile_1g_tb;
  import talu_pkg::*;
  import talu_mul_pkg::*;

  localparam int MR1 = csa_rows(XLEN/2 + 1, MUL_S1_LV);

  logic        clk = 0, rst_n = 0, step = 0;
  logic [31:0] wa_in = 0, wb_in = 0, n_in = 0, s_in = 0, nw_in = 0, sw_in = 0;
  logic [31:0] const_in = 0, extb_in = 0, comb_y, reg_y;
  logic [MR1*32-1:0] comb_rows;
  alu_op_t     op = ALU_ADD;
  src_sel_t    src_a = SRC_WEST, src_b = SRC_WEST;
  int errors = 0;

  // grid tile (SCALAR=0): the scalar-forwarding port is unused
  alu_tile #(.HAS_MUL(1'b1), .SCALAR(1'b0)) dut (
    .clk, .rst_n, .step, .wa_in, .wb_in, .n_in, .s_in, .nw_in, .sw_in,
    .const_in, .extb_in, .op, .src_a, .src_b,
    .sc_grid(1'b0), .sc_asel(3'b0), .sc_bsel(3'b0),
    .sc_mem('0), .sc_wb('0), .sc_ra('0), .sc_rb('0),
    .comb_y, .comb_rows, .reg_y);

  always #5 clk = ~clk;

  task automatic chk(string nm, logic [31:0] got, logic [31:0] exp);
    if (got !== exp) begin $display("FAIL %-18s got=%08h exp=%08h", nm, got, exp); errors++; end
    else $display("ok   %-18s -> %08h", nm, got);
  endtask

  task automatic steps(int n);
    repeat (n) begin @(negedge clk); step = 1; @(negedge clk); step = 0; end
    #1;
  endtask

  // configure, advance two stages, check the registered output
  task automatic run(string nm, alu_op_t o, src_sel_t sa, src_sel_t sb, logic [31:0] exp);
    op = o; src_a = sa; src_b = sb; #1;
    steps(2);
    chk(nm, reg_y, exp);
  endtask

  initial begin
    repeat (2) @(negedge clk); rst_n = 1;
    wa_in = 32'd3; wb_in = 32'd3; n_in = 32'd100; s_in = 32'd200;
    nw_in = 32'd7; sw_in = 32'd9; const_in = 32'd3; extb_in = 32'd40;

    // stage-1 tap is combinational for non-multiply ops
    op = ALU_ADD; #1;
    chk("comb W+W", comb_y, 32'd6);

    // two-stage latency: one step is not enough, two are
    op = ALU_SUB; src_a = SRC_NORTH; src_b = SRC_SOUTH; #1;
    steps(1);
    chk("1 step: old value", reg_y, 32'd0);
    steps(1);
    chk("N-S sub (2 steps)", reg_y, 32'(32'd100 - 32'd200));

    run("W+W add",   ALU_ADD,   SRC_WEST,  SRC_WEST,  32'd6);
    run("NW+SW add", ALU_ADD,   SRC_NW,    SRC_SW,    32'd16);
    run("copyA=N",   ALU_COPYA, SRC_NORTH, SRC_WEST,  32'd100);
    run("E+C add",   ALU_ADD,   SRC_EXTB,  SRC_CONST, 32'd43);

    // multiply goes through the split carry-save tree
    wa_in = 32'd7;
    run("W*C mul",   ALU_MUL,   SRC_WEST,  SRC_CONST, 32'd21);
    chk("comb_y=0 on MUL", comb_y, 32'd0);
    wa_in = 32'hFFFF_FFF9; const_in = 32'd6;           // -7 * 6
    run("neg mul",   ALU_MUL,   SRC_WEST,  SRC_CONST, 32'(-42));
    wa_in = 32'h1234_5678; wb_in = 32'h9ABC_DEF0;
    run("big mul",   ALU_MUL,   SRC_WEST,  SRC_WEST,  32'h1234_5678 * 32'h9ABC_DEF0);

    // signed MIN / MAX
    wa_in = 32'hFFFF_FFFE; n_in = 32'd5;              // -2 vs 5
    run("min(-2,5)", ALU_MIN,   SRC_WEST,  SRC_NORTH, 32'hFFFF_FFFE);
    run("max(-2,5)", ALU_MAX,   SRC_WEST,  SRC_NORTH, 32'd5);

    // step low: both stages hold even if the inputs change
    wa_in = 32'd999; op = ALU_COPYA; src_a = SRC_WEST; #1;
    repeat (3) @(negedge clk); #1;
    chk("hold", reg_y, 32'd5);

    if (errors == 0) $display("\nALU_TILE_1G_TB PASS");
    else             $display("\nALU_TILE_1G_TB FAIL (%0d)", errors);
    $finish;
  end
endmodule
