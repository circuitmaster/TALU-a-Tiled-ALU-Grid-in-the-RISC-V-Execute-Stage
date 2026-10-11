// dmem_tb.sv -- self-checking testbench for dmem.sv (scalar + wide ports)
`timescale 1ns/1ps
`include "talu_pkg.sv"

module dmem_tb;
  import talu_pkg::*;
  localparam int N = 4;

  logic clk = 0;
  logic [31:0] s_addr=0, s_wdata=0, s_rdata;
  logic        s_we=0, s_re=0;
  logic [2:0]  s_funct3=3'b010;
  logic [31:0] vA_addr=0, vB_addr=0, vW_addr=0;
  logic        vW_we=0;
  logic [N*32-1:0] vW_wdata=0, vA_rdata, vB_rdata;
  logic [N-1:0]    vW_wmask=0;
  int errors=0;

  dmem #(.N(N), .WORDS(256)) dut (.*);
  always #5 clk=~clk;

  task automatic sstore(int a, logic [31:0] d, logic [2:0] f3);
    @(negedge clk); s_we=1; s_addr=a; s_wdata=d; s_funct3=f3;
    @(negedge clk); s_we=0;
  endtask
  task automatic chk(string nm, logic [31:0] got, logic [31:0] exp);
    if (got!==exp) begin $display("FAIL %-14s got=%08h exp=%08h",nm,got,exp); errors++; end
    else $display("ok   %-14s -> %08h",nm,got);
  endtask

  initial begin
    // SW then LW
    sstore(16, 32'hDEADBEEF, 3'b010);
    s_addr=16; s_funct3=3'b010; #1; chk("LW", s_rdata, 32'hDEADBEEF);

    // SB at byte 1 of word @ addr20
    sstore(20, 32'h000000AA, 3'b000); // write byte 0
    sstore(21, 32'h000000BB, 3'b000); // write byte 1
    s_addr=20; s_funct3=3'b010; #1; chk("after 2 SB", s_rdata, 32'h0000BBAA);
    s_addr=21; s_funct3=3'b000; #1; chk("LB signext", s_rdata, 32'hFFFFFFBB); // 0xBB sign
    s_addr=21; s_funct3=3'b100; #1; chk("LBU", s_rdata, 32'h000000BB);

    // SH at half 1
    sstore(24, 32'h00001234, 3'b001);
    sstore(26, 32'h00005678, 3'b001);
    s_addr=24; s_funct3=3'b010; #1; chk("SH word", s_rdata, 32'h56781234);

    // wide vector write 4 words at base 64, then wide read (port A)
    @(negedge clk); vW_we=1; vW_addr=64;
    vW_wdata={32'd400,32'd300,32'd200,32'd100}; vW_wmask=4'b1111;
    @(negedge clk); vW_we=0; #1;
    vA_addr=64; #1;
    chk("vread lane0", vA_rdata[31:0],   32'd100);
    chk("vread lane3", vA_rdata[127:96], 32'd400);
    // second read port B reads a different base simultaneously (base 16 word)
    vB_addr=16; #1; chk("vB reads", vB_rdata[31:0], 32'hDEADBEEF);
    // scalar read of lane2 word (base 64 + 2*4 = 72)
    s_addr=72; s_funct3=3'b010; #1; chk("scalar sees v", s_rdata, 32'd300);

    // partial vector write (lanes 0,2) at base 64
    @(negedge clk); vW_we=1; vW_addr=64; vW_wdata={32'd9,32'd9,32'd9,32'd9}; vW_wmask=4'b0101;
    @(negedge clk); vW_we=0; #1; vA_addr=64; #1;
    chk("vpart lane0", vA_rdata[31:0],   32'd9);
    chk("vpart lane1", vA_rdata[63:32],  32'd200); // unchanged
    chk("vpart lane2", vA_rdata[95:64],  32'd9);
    chk("vpart lane3", vA_rdata[127:96], 32'd400); // unchanged

    if (errors==0) $display("\nDMEM_TB PASS");
    else           $display("\nDMEM_TB FAIL (%0d)", errors);
    $finish;
  end
endmodule
