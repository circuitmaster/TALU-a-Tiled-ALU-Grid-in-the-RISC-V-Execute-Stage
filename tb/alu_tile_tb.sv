// alu_tile_tb.sv -- self-checking testbench for alu_tile.sv
`timescale 1ns/1ps
`include "talu_pkg.sv"

module alu_tile_tb;
  import talu_pkg::*;

  logic        clk = 0, rst_n = 0, step = 0;
  logic [31:0] wa_in = 0, wb_in = 0, n_in = 0, s_in = 0, nw_in = 0, sw_in = 0, comb_y, reg_y;
  logic [31:0] const_in = 0, extb_in = 0;
  alu_op_t     op = ALU_ADD;
  src_sel_t    src_a = SRC_WEST, src_b = SRC_WEST;
  int errors = 0;

  alu_tile dut (.clk, .rst_n, .step, .wa_in, .wb_in, .n_in, .s_in, .nw_in, .sw_in,
                .const_in, .extb_in, .op, .src_a, .src_b, .comb_y, .reg_y);

  always #5 clk = ~clk;

  task automatic chk(string nm, logic [31:0] got, logic [31:0] exp);
    if (got !== exp) begin $display("FAIL %-16s got=%08h exp=%08h", nm, got, exp); errors++; end
    else $display("ok   %-16s -> %08h", nm, got);
  endtask

  initial begin
    repeat (2) @(negedge clk); rst_n = 1;

    // Combinational: West+West ADD
    wa_in = 32'd3; wb_in = 32'd3; n_in = 32'd100; s_in = 32'd200;
    src_a = SRC_WEST; src_b = SRC_WEST; op = ALU_ADD; #1;
    chk("W+W add", comb_y, 32'd6);

    // operand A = North, operand B = South, SUB -> 100-200
    src_a = SRC_NORTH; src_b = SRC_SOUTH; op = ALU_SUB; #1;
    chk("N-S sub", comb_y, 32'(32'd100 - 32'd200));

    // operand A = West, B = North, AND
    src_a = SRC_WEST; src_b = SRC_NORTH; op = ALU_COPYA; #1;
    chk("copyA=W", comb_y, 32'd3);

    // register capture: when step, reg_y takes comb_y on next edge
    op = ALU_ADD; src_a = SRC_WEST; src_b = SRC_SOUTH; wa_in = 32'd10; s_in = 32'd5; #1;
    @(negedge clk); step = 1; @(negedge clk); step = 0; #1;
    chk("reg capt", reg_y, 32'd15);

    // when step low, reg_y holds even if inputs change
    wa_in = 32'd999; #1;
    chk("reg hold", reg_y, 32'd15);

    // constant-operand extension: A = West, B = tile const, MUL
    wa_in = 32'd7; const_in = 32'd3;
    src_a = SRC_WEST; src_b = SRC_CONST; op = ALU_MUL; #1;
    chk("W*C mul", comb_y, 32'd21);

    // EXTB bus: A = EXTB, B = const, ADD
    extb_in = 32'd40; src_a = SRC_EXTB; op = ALU_ADD; #1;
    chk("E+C add", comb_y, 32'd43);

    // MIN / MAX (signed)
    wa_in = 32'hFFFFFFFE; wb_in = 32'd5;      // -2 vs 5
    src_a = SRC_WEST; src_b = SRC_WEST; wb_in = 32'd5;
    n_in = 32'd5;
    src_b = SRC_NORTH; op = ALU_MIN; #1;
    chk("min(-2,5)", comb_y, 32'hFFFFFFFE);
    op = ALU_MAX; #1;
    chk("max(-2,5)", comb_y, 32'd5);

    if (errors == 0) $display("\nALU_TILE_TB PASS");
    else             $display("\nALU_TILE_TB FAIL (%0d)", errors);
    $finish;
  end
endmodule
