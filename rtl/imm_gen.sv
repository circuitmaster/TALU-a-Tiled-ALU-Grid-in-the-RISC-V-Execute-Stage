// imm_gen.sv
// RISC-V immediate generator. Selects I/S/B/U/J immediate by opcode and
// sign-extends to XLEN. Custom VLW uses I-type, VSW uses S-type.
`include "talu_pkg.sv"

module imm_gen
  import talu_pkg::*;
(
  input  logic [31:0]      instr,
  output logic [XLEN-1:0]  imm
);
  logic [6:0] opcode;
  assign opcode = instr[6:0];

  logic [XLEN-1:0] i_imm, s_imm, b_imm, u_imm, j_imm;
  assign i_imm = {{20{instr[31]}}, instr[31:20]};
  assign s_imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
  assign b_imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
  assign u_imm = {instr[31:12], 12'b0};
  assign j_imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

  always_comb begin
    unique case (opcode)
      OP_STORE   : imm = s_imm;
      OP_CUSTOM1 : imm = (instr[14:12] == F3_VSW) ? s_imm : i_imm; // VSW=S, VLW=I
      OP_BRANCH  : imm = b_imm;
      OP_LUI,
      OP_AUIPC   : imm = u_imm;
      OP_JAL     : imm = j_imm;
      default    : imm = i_imm;  // OP_IMM, OP_LOAD, OP_JALR, OP_CUSTOM0(unused)
    endcase
  end
endmodule
