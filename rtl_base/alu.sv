// alu.sv
// Combinational RV32I ALU.  Used both by the scalar datapath (tile 0,0) and by
// every grid tile.
`include "talu_pkg.sv"

module alu
  import talu_pkg::*;
#(
  parameter int W = XLEN,
  parameter bit HAS_MUL = 1'b1   // 0: strip the multiplier (cheap-grid tiles)
) (
  input  alu_op_t       op,
  input  logic [W-1:0]  a,
  input  logic [W-1:0]  b,
  output logic [W-1:0]  y
);

  localparam int SHW = $clog2(W);          // shift-amount width (5 for W=32)
  logic [SHW-1:0] shamt;
  assign shamt = b[SHW-1:0];

  always_comb begin
    unique case (op)
      ALU_ADD  : y = a + b;
      ALU_SUB  : y = a - b;
      ALU_SLL  : y = a << shamt;
      ALU_SLT  : y = ($signed(a) < $signed(b)) ? {{(W-1){1'b0}}, 1'b1} : '0;
      ALU_SLTU : y = (a < b)                   ? {{(W-1){1'b0}}, 1'b1} : '0;
      ALU_XOR  : y = a ^ b;
      ALU_SRL  : y = a >> shamt;
      ALU_SRA  : y = $signed(a) >>> shamt;
      ALU_OR   : y = a | b;
      ALU_AND  : y = a & b;
      ALU_COPYA: y = a;
      ALU_COPYB: y = b;
      ALU_MUL  : y = HAS_MUL ? a * b : '0;   // low XLEN bits (RV32 MUL)
      ALU_MIN  : y = ($signed(a) < $signed(b)) ? a : b;
      ALU_MAX  : y = ($signed(a) > $signed(b)) ? a : b;
      default  : y = '0;                    // ALU_NOP and unused codes
    endcase
  end

endmodule
