// decoder.sv
// Instruction decoder for RV32I + TALU custom extensions.
// Pure combinational. Produces scalar control signals and extracts the field
// values for the custom grid/vector instructions.
//
// Custom encodings (must match tools/asm.py):
//   GCFG   : opcode=0x0B funct3=000
//            row=[18:16] col=[21:19] aluop=[26:22] srcA=[29:27](3b) srcB=[10:8](3b) drain=[7]
//   GSTART : opcode=0x0B funct3=001
//            vd=[10:8] vs1=[18:16] vs2=[21:19] len=[26:22] lanes=[30:27]
//   GCFGI  : opcode=0x0B funct3=010
//            row=[9:7] col=[24:22] rs1=[19:15] (tile const := rs1 value)
//   VLW    : opcode=0x2B funct3=000  vd=[10:8]  rs1=[19:15] imm=I-type
//   VSW    : opcode=0x2B funct3=001  vs=[22:20] rs1=[19:15] imm=S-type
`include "talu_pkg.sv"

module decoder
  import talu_pkg::*;
(
  input  logic [31:0] instr,

  // register addresses
  output logic [4:0]  rs1_addr,
  output logic [4:0]  rs2_addr,
  output logic [4:0]  rd_addr,

  // scalar datapath control
  output logic        reg_we,       // scalar regfile write
  output logic [1:0]  rd_src,       // RD_ALU/RD_MEM/RD_PC4/RD_IMM
  output alu_op_t     alu_op,
  output logic        alu_a_pc,     // ALU operand A = PC (auipc)
  output logic        alu_b_imm,    // ALU operand B = imm (else rs2)
  output logic        mem_read,
  output logic        mem_write,
  output logic [2:0]  mem_funct3,
  output logic        branch,
  output logic [2:0]  br_funct3,
  output logic        jal,
  output logic        jalr,
  output logic        is_ecall,

  // custom: grid config (GCFG)
  output logic        is_gcfg,
  output logic [2:0]  g_row,
  output logic [2:0]  g_col,
  output alu_op_t     g_op,
  output src_sel_t    g_srca,
  output src_sel_t    g_srcb,
  output logic        g_drain,

  // custom: tile constant write (GCFGI); row/col on gi_row/gi_col, value = rs1
  output logic        is_gcfgi,
  output logic [2:0]  gi_row,
  output logic [2:0]  gi_col,

  // custom: grid start (GSTART)
  output logic        is_gstart,
  output logic [2:0]  gs_vd,
  output logic [2:0]  gs_vs1,
  output logic [2:0]  gs_vs2,
  output logic [4:0]  gs_len,
  output logic [3:0]  gs_lanes,

  // custom: vector memory
  output logic        is_vlw,
  output logic        is_vsw,
  output logic [2:0]  v_vd,         // VLW dest vreg
  output logic [2:0]  v_vs,         // VSW source vreg

  // custom: streaming grid (GFLOW). Path latency is derived in hardware from
  // the drain configuration, so it is not encoded here.
  output logic        is_gflow,
  output logic [4:0]  gf_dstreg,    // scalar reg holding dst base address
  output logic [4:0]  gf_cntreg,    // scalar reg holding block count
  output logic        gf_mode       // 0=stream elementwise, 1=reduce/accumulate
);

  // RD source select encoding
  localparam logic [1:0] RD_ALU = 2'd0, RD_MEM = 2'd1, RD_PC4 = 2'd2, RD_IMM = 2'd3;

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  assign opcode = instr[6:0];
  assign funct3 = instr[14:12];
  assign funct7 = instr[31:25];

  assign rs1_addr = instr[19:15];
  assign rs2_addr = instr[24:20];
  assign rd_addr  = instr[11:7];
  assign mem_funct3 = funct3;
  assign br_funct3  = funct3;

  // ----- ALU op selection for OP_IMM / OP_REG -----
  function automatic alu_op_t rtype_op(logic [2:0] f3, logic f7b5, logic is_reg);
    unique case (f3)
      3'b000: rtype_op = (is_reg && f7b5) ? ALU_SUB : ALU_ADD; // SUB only for reg-reg
      3'b001: rtype_op = ALU_SLL;
      3'b010: rtype_op = ALU_SLT;
      3'b011: rtype_op = ALU_SLTU;
      3'b100: rtype_op = ALU_XOR;
      3'b101: rtype_op = f7b5 ? ALU_SRA : ALU_SRL;
      3'b110: rtype_op = ALU_OR;
      3'b111: rtype_op = ALU_AND;
    endcase
  endfunction

  // ----- custom field extraction -----
  assign is_gcfg   = (opcode == OP_CUSTOM0) && (funct3 == F3_GCFG);
  assign is_gcfgi  = (opcode == OP_CUSTOM0) && (funct3 == F3_GCFGI);
  assign is_gstart = (opcode == OP_CUSTOM0) && (funct3 == F3_GSTART);
  assign is_vlw    = (opcode == OP_CUSTOM1) && (funct3 == F3_VLW);
  assign is_vsw    = (opcode == OP_CUSTOM1) && (funct3 == F3_VSW);
  assign is_gflow  = (opcode == OP_CUSTOM0) && (funct3 == F3_GFLOW);

  // GFLOW: src1=rs1, src2=rs2; dst-base & count come from scalar regs
  assign gf_dstreg = instr[11:7];
  assign gf_cntreg = instr[31:27];
  assign gf_mode   = instr[26];

  assign gi_row = instr[9:7];
  assign gi_col = instr[24:22];

  assign g_row  = instr[18:16];
  assign g_col  = instr[21:19];
  assign g_op   = alu_op_t'(instr[26:22]);
  assign g_srca = src_sel_t'(instr[29:27]);
  assign g_srcb = src_sel_t'(instr[10:8]);
  assign g_drain= instr[7];

  assign gs_vd   = instr[10:8];
  assign gs_vs1  = instr[18:16];
  assign gs_vs2  = instr[21:19];
  assign gs_len  = instr[26:22];
  assign gs_lanes= instr[30:27];

  assign v_vd = instr[10:8];
  assign v_vs = instr[22:20];

  // ----- main control -----
  always_comb begin
    reg_we    = 1'b0;
    rd_src    = RD_ALU;
    alu_op    = ALU_ADD;
    alu_a_pc  = 1'b0;
    alu_b_imm = 1'b0;
    mem_read  = 1'b0;
    mem_write = 1'b0;
    branch    = 1'b0;
    jal       = 1'b0;
    jalr      = 1'b0;
    is_ecall  = 1'b0;

    unique case (opcode)
      OP_LUI: begin
        reg_we = 1'b1; rd_src = RD_IMM;
      end
      OP_AUIPC: begin
        reg_we = 1'b1; rd_src = RD_ALU; alu_a_pc = 1'b1; alu_b_imm = 1'b1; alu_op = ALU_ADD;
      end
      OP_JAL: begin
        reg_we = 1'b1; rd_src = RD_PC4; jal = 1'b1;
      end
      OP_JALR: begin
        reg_we = 1'b1; rd_src = RD_PC4; jalr = 1'b1;
      end
      OP_BRANCH: begin
        branch = 1'b1;
      end
      OP_LOAD: begin
        reg_we = 1'b1; rd_src = RD_MEM; mem_read = 1'b1; alu_b_imm = 1'b1; alu_op = ALU_ADD;
      end
      OP_STORE: begin
        mem_write = 1'b1; alu_b_imm = 1'b1; alu_op = ALU_ADD;
      end
      OP_IMM: begin
        reg_we = 1'b1; rd_src = RD_ALU; alu_b_imm = 1'b1;
        alu_op = rtype_op(funct3, instr[30], 1'b0);
      end
      OP_REG: begin
        reg_we = 1'b1; rd_src = RD_ALU; alu_b_imm = 1'b0;
        // RV32M: MUL (funct7=0000001, funct3=000). Other M ops not implemented.
        if (funct7 == 7'b0000001 && funct3 == 3'b000) alu_op = ALU_MUL;
        else                                          alu_op = rtype_op(funct3, instr[30], 1'b1);
      end
      OP_SYSTEM: begin
        is_ecall = 1'b1;
      end
      default: ; // custom ops handled via dedicated is_* signals
    endcase
  end
endmodule
