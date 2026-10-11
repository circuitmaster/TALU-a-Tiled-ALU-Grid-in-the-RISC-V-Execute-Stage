// alu_grid_tb.sv -- self-checking testbench for alu_grid.sv (N=4)
`timescale 1ns/1ps
`include "talu_pkg.sv"

module alu_grid_tb;
  import talu_pkg::*;

  localparam int N = 4;
  localparam int W = 32;

  logic clk = 0, rst_n = 0, step = 0;
  logic [N*N*5-1:0] op_flat;
  logic [N*N*3-1:0] srca_flat, srcb_flat;
  logic [N*N-1:0]   drain_flat;
  logic [N*N*W-1:0] const_flat = '0;
  logic [N*W-1:0]   inj_a_flat, inj_b_flat;
  logic [N*W-1:0]   extb_flat = '0;
  logic [W-1:0]     scalar_y;
  logic [N*W-1:0]   drain_val_flat;
  logic [N-1:0]     drain_act;
  int errors = 0;

  alu_grid #(.N(N), .W(W)) dut (.*);

  always #5 clk = ~clk;

  // configure one tile
  task automatic setcfg(int r, int c, alu_op_t o, src_sel_t sa, src_sel_t sb, bit dr);
    op_flat  [(r*N+c)*5 +: 5] = o;
    srca_flat[(r*N+c)*3 +: 3] = sa;
    srcb_flat[(r*N+c)*3 +: 3] = sb;
    drain_flat[r*N+c]         = dr;
  endtask

  task automatic clear_grid;
    op_flat = '0; srca_flat = '0; srcb_flat = '0; drain_flat = '0;
    inj_a_flat = '0; inj_b_flat = '0;
    for (int i = 0; i < N*N; i++) op_flat[i*5 +: 5] = ALU_NOP;
  endtask

  task automatic inj(int r, logic [31:0] a, logic [31:0] b);
    inj_a_flat[r*W +: W] = a; inj_b_flat[r*W +: W] = b;
  endtask

  task automatic run_steps(int n);
    for (int i = 0; i < n; i++) begin @(negedge clk); step = 1; end
    @(negedge clk); step = 0; #1;
  endtask

  task automatic chk(string nm, logic [31:0] got, logic [31:0] exp);
    if (got !== exp) begin $display("FAIL %-18s got=%08h exp=%08h", nm, got, exp); errors++; end
    else $display("ok   %-18s -> %08h", nm, got);
  endtask

  // reset the tile registers between scenarios
  task automatic grst;
    rst_n = 0; @(negedge clk); @(negedge clk); rst_n = 1; #1;
  endtask

  initial begin
    clear_grid;
    repeat (2) @(negedge clk); rst_n = 1; #1;

    // --- 1. scalar tap: tile(0,0) = ADD(injA0, injB0), combinational ---
    inj(0, 32'd5, 32'd7);
    setcfg(0,0, ALU_ADD, SRC_WEST, SRC_WEST, 1'b0);
    #1; chk("scalar 5+7", scalar_y, 32'd12);
    inj(0, 32'hFFFF_FFF0, 32'd16);
    #1; chk("scalar wrap", scalar_y, 32'd0);

    // --- 2. single forward path, row 0: (a+b) then pass to (0,3), drain lane0 ---
    grst; clear_grid;
    inj(0, 32'd5, 32'd7);                                   // a=5,b=7
    setcfg(0,0, ALU_ADD,   SRC_WEST, SRC_WEST, 1'b0);       // 12
    setcfg(0,1, ALU_COPYA, SRC_WEST, SRC_WEST, 1'b0);
    setcfg(0,2, ALU_COPYA, SRC_WEST, SRC_WEST, 1'b0);
    setcfg(0,3, ALU_COPYA, SRC_WEST, SRC_WEST, 1'b1);       // drain at edge -> lane0
    run_steps(8);
    chk("path lane0=12", drain_val_flat[0*W +: W], 32'd12);
    if (drain_act[0] !== 1'b1) begin $display("FAIL drain_act[0]"); errors++; end

    // --- 3. multi-path, equal length: row0 a0+b0, row1 a1+b1 ---
    grst; clear_grid;
    inj(0, 32'd10, 32'd20);   // ->30
    inj(1, 32'd3,  32'd4);    // ->7
    for (int cc = 0; cc < N; cc++) begin
      setcfg(0, cc, (cc==0)?ALU_ADD:ALU_COPYA, SRC_WEST, SRC_WEST, (cc==N-1));
      setcfg(1, cc, (cc==0)?ALU_ADD:ALU_COPYA, SRC_WEST, SRC_WEST, (cc==N-1));
    end
    run_steps(8);
    chk("mpath lane0=30", drain_val_flat[0*W +: W], 32'd30);
    chk("mpath lane1=7",  drain_val_flat[1*W +: W], 32'd7);

    // --- 4. vertical (North) routing: row1 carries a, row0 carries b,
    //        they meet at tile(1,3): West(a) + North(reg[0][3]=b), drain lane1 ---
    grst; clear_grid;
    inj(1, 32'd100, 32'd0);   // a travels along row1
    inj(0, 32'd25,  32'd0);   // b travels along row0
    setcfg(1,0, ALU_COPYA, SRC_WEST, SRC_WEST, 1'b0);
    setcfg(1,1, ALU_COPYA, SRC_WEST, SRC_WEST, 1'b0);
    setcfg(1,2, ALU_COPYA, SRC_WEST, SRC_WEST, 1'b0);
    setcfg(1,3, ALU_ADD,   SRC_WEST, SRC_NORTH, 1'b1); // a + b -> lane1
    setcfg(0,0, ALU_COPYA, SRC_WEST, SRC_WEST, 1'b0);
    setcfg(0,1, ALU_COPYA, SRC_WEST, SRC_WEST, 1'b0);
    setcfg(0,2, ALU_COPYA, SRC_WEST, SRC_WEST, 1'b0);
    setcfg(0,3, ALU_COPYA, SRC_WEST, SRC_WEST, 1'b0);
    run_steps(8);
    chk("vmeet lane1=125", drain_val_flat[1*W +: W], 32'd125);

    // --- 5. diagonal reduction: sum v0..v3 along an anti-diagonal (SW chain),
    //        result lands at top-right (0,3) -> lane 0 ---
    grst; clear_grid;
    inj(0, 32'd1, 0); inj(1, 32'd2, 0); inj(2, 32'd3, 0); inj(3, 32'd4, 0);
    setcfg(0,0, ALU_COPYA, SRC_WEST, SRC_WEST, 0);
    setcfg(0,1, ALU_COPYA, SRC_WEST, SRC_WEST, 0);
    setcfg(0,2, ALU_COPYA, SRC_WEST, SRC_WEST, 0);
    setcfg(1,0, ALU_COPYA, SRC_WEST, SRC_WEST, 0);
    setcfg(1,1, ALU_COPYA, SRC_WEST, SRC_WEST, 0);
    setcfg(2,0, ALU_COPYA, SRC_WEST, SRC_WEST, 0);
    setcfg(3,0, ALU_COPYA, SRC_WEST, SRC_WEST, 0);
    setcfg(2,1, ALU_ADD, SRC_WEST, SRC_SW, 0);   // v2+v3
    setcfg(1,2, ALU_ADD, SRC_WEST, SRC_SW, 0);   // v1+(v2+v3)
    setcfg(0,3, ALU_ADD, SRC_WEST, SRC_SW, 1);   // v0+... -> drain lane0
    run_steps(10);
    chk("diag reduce=10", drain_val_flat[0*W +: W], 32'd10);

    // --- 6. MUL op sanity through a tile ---
    grst; clear_grid;
    inj(0, 32'd6, 32'd7);
    setcfg(0,0, ALU_MUL, SRC_WEST, SRC_WEST, 1);
    run_steps(3);
    chk("mul 6*7=42", drain_val_flat[0*W +: W], 32'd42);

    if (errors == 0) $display("\nALU_GRID_TB PASS");
    else             $display("\nALU_GRID_TB FAIL (%0d)", errors);
    $finish;
  end
endmodule
