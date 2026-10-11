// regfile_tb.sv -- self-checking testbench for regfile.sv
`timescale 1ns/1ps
`include "talu_pkg.sv"

module regfile_tb;
  import talu_pkg::*;

  logic        clk = 0, rst_n = 0, we = 0;
  logic [4:0]  waddr = 0, raddr1 = 0, raddr2 = 0;
  logic [31:0] wdata = 0, rdata1, rdata2;
  int errors = 0;

  regfile dut (.clk, .rst_n, .we, .waddr, .wdata, .raddr1, .rdata1, .raddr2, .rdata2);

  always #5 clk = ~clk;

  task automatic wr(int a, int d);
    @(negedge clk); we = 1; waddr = a[4:0]; wdata = d;
    @(negedge clk); we = 0;
  endtask

  task automatic chk(string nm, logic [31:0] got, logic [31:0] exp);
    if (got !== exp) begin
      $display("FAIL %-12s got=%08h exp=%08h", nm, got, exp); errors++;
    end else $display("ok   %-12s -> %08h", nm, got);
  endtask

  initial begin
    repeat (2) @(negedge clk); rst_n = 1;

    wr(5, 32'hAAAA_5555);
    wr(10, 32'h1234_5678);
    raddr1 = 5; raddr2 = 10; #1;
    chk("read x5",  rdata1, 32'hAAAA_5555);
    chk("read x10", rdata2, 32'h1234_5678);

    // x0 stays zero even after write
    wr(0, 32'hFFFF_FFFF);
    raddr1 = 0; #1; chk("x0 zero", rdata1, 32'h0);

    // write-first bypass: read same addr being written this cycle
    @(negedge clk); we = 1; waddr = 7; wdata = 32'hCAFEF00D; raddr1 = 7; #1;
    chk("bypass x7", rdata1, 32'hCAFEF00D);
    @(negedge clk); we = 0; #1;
    chk("committed x7", rdata1, 32'hCAFEF00D);

    if (errors == 0) $display("\nREGFILE_TB PASS");
    else             $display("\nREGFILE_TB FAIL (%0d)", errors);
    $finish;
  end
endmodule
