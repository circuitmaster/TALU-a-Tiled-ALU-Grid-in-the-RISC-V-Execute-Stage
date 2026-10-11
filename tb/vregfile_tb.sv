// vregfile_tb.sv -- self-checking testbench for vregfile.sv
`timescale 1ns/1ps
`include "talu_pkg.sv"

module vregfile_tb;
  import talu_pkg::*;
  localparam int N = 4, W = 32, NREGS = 8;

  logic clk = 0, rst_n = 0, we = 0;
  logic [2:0] waddr = 0, raddr1 = 0, raddr2 = 0;
  logic [N*W-1:0] wdata = 0, rdata1, rdata2;
  logic [N-1:0]   wmask = '0;
  int errors = 0;

  vregfile #(.N(N), .W(W), .NREGS(NREGS)) dut (.*);
  always #5 clk = ~clk;

  task automatic wr(int a, logic [N*W-1:0] d, logic [N-1:0] m);
    @(negedge clk); we = 1; waddr = a[2:0]; wdata = d; wmask = m;
    @(negedge clk); we = 0;
  endtask

  task automatic chk(string nm, logic [N*W-1:0] got, logic [N*W-1:0] exp);
    if (got !== exp) begin $display("FAIL %-16s got=%032h exp=%032h", nm, got, exp); errors++; end
    else $display("ok   %-16s -> %032h", nm, got);
  endtask

  initial begin
    repeat (2) @(negedge clk); rst_n = 1;

    // full write all lanes
    wr(2, {32'd44, 32'd33, 32'd22, 32'd11}, 4'b1111); // lane3..0 = 44,33,22,11
    raddr1 = 2; #1;
    chk("v2 full", rdata1, {32'd44, 32'd33, 32'd22, 32'd11});

    // lane slicing: lane 0 (scalar slice) is lowest 32 bits
    if (rdata1[31:0] !== 32'd11) begin $display("FAIL lane0 slice"); errors++; end
    else $display("ok   lane0 slice = %0d", rdata1[31:0]);

    // partial write: only lanes 0 and 2 of v3
    wr(3, {32'hAAAA, 32'hBBBB, 32'hCCCC, 32'hDDDD}, 4'b0101);
    raddr2 = 3; #1;
    // lanes 1,3 stay 0 (reset); lanes 0,2 updated
    chk("v3 partial", rdata2, {32'h0, 32'hBBBB, 32'h0, 32'hDDDD});

    // masked write with mask 0 changes nothing
    wr(2, '1, 4'b0000);
    raddr1 = 2; #1;
    chk("v2 unchanged", rdata1, {32'd44, 32'd33, 32'd22, 32'd11});

    if (errors == 0) $display("\nVREGFILE_TB PASS");
    else             $display("\nVREGFILE_TB FAIL (%0d)", errors);
    $finish;
  end
endmodule
