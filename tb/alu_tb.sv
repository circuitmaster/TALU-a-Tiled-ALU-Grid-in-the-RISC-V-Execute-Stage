// alu_tb.sv  --  self-checking testbench for alu.sv
`timescale 1ns/1ps
`include "talu_pkg.sv"

module alu_tb;
  import talu_pkg::*;

  logic [31:0] a, b, y;
  alu_op_t     op;
  int          errors = 0;

  alu #(.W(32)) dut (.op(op), .a(a), .b(b), .y(y));

  task automatic check(alu_op_t o, logic [31:0] ia, logic [31:0] ib,
                       logic [31:0] exp, string name);
    op = o; a = ia; b = ib;
    #1;
    if (y !== exp) begin
      $display("FAIL %-6s a=%08h b=%08h  got=%08h exp=%08h", name, ia, ib, y, exp);
      errors++;
    end else begin
      $display("ok   %-6s a=%08h b=%08h  -> %08h", name, ia, ib, y);
    end
  endtask

  initial begin
    check(ALU_ADD , 32'd5,        32'd7,        32'd12,       "ADD");
    check(ALU_ADD , 32'hFFFFFFFF, 32'd1,        32'd0,        "ADD.ov");
    check(ALU_SUB , 32'd10,       32'd3,        32'd7,        "SUB");
    check(ALU_SUB , 32'd3,        32'd10,       32'hFFFFFFF9, "SUB.neg");
    check(ALU_SLL , 32'h1,        32'd4,        32'h10,       "SLL");
    check(ALU_SLL , 32'h1,        32'd33,       32'h2,        "SLL.mod");  // shamt=1
    check(ALU_SLT , 32'hFFFFFFFF, 32'd1,        32'd1,        "SLT.neg");  // -1 < 1
    check(ALU_SLT , 32'd5,        32'd5,        32'd0,        "SLT.eq");
    check(ALU_SLTU, 32'hFFFFFFFF, 32'd1,        32'd0,        "SLTU");     // big >1
    check(ALU_XOR , 32'hF0F0F0F0, 32'h0FF00FF0, 32'hFF00FF00, "XOR");
    check(ALU_SRL , 32'h80000000, 32'd4,        32'h08000000, "SRL");
    check(ALU_SRA , 32'h80000000, 32'd4,        32'hF8000000, "SRA");
    check(ALU_OR  , 32'hF0F0F0F0, 32'h0F0F0F0F, 32'hFFFFFFFF, "OR");
    check(ALU_AND , 32'hF0F0F0F0, 32'h0FF00FF0, 32'h00F000F0, "AND");
    check(ALU_COPYA,32'hDEADBEEF, 32'h12345678, 32'hDEADBEEF, "COPYA");
    check(ALU_COPYB,32'hDEADBEEF, 32'h12345678, 32'h12345678, "COPYB");
    check(ALU_NOP , 32'hDEADBEEF, 32'h12345678, 32'h0,        "NOP");

    if (errors == 0) $display("\nALU_TB PASS (all checks ok)");
    else             $display("\nALU_TB FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
