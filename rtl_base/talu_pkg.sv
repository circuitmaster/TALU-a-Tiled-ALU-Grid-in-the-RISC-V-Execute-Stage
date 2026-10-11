// talu_pkg.sv
// Shared parameters, ALU op codes, and ISA encodings for the TALU core.
`ifndef TALU_PKG_SV
`define TALU_PKG_SV

package talu_pkg;

  // ----------------------------------------------------------------------
  // Global parameters
  // ----------------------------------------------------------------------
  parameter int XLEN = 32;          // data width
  parameter int GRID_N = 4;         // default grid dimension (N x N)
  parameter int VREGS = 8;          // number of vector registers
  // Per-tile multiplier mask (bit r*GRID_N+c): 1 = tile has a multiplier.
  // Default: all tiles. Cheap-grid variants (E7): column 0 only = one bit per
  // row (e.g. 16'h1111 at N=4); none = '0 (also removes the scalar MUL).
  parameter logic [GRID_N*GRID_N-1:0] MUL_MASK = '1;
  // Diagonal (NW/SW) forwarding enable. 0 = topology ablation: only West and
  // same-column North/South forwarding remain (docs/core_topology_res.md).
  parameter bit DIAG_EN = 1'b1;
  // Drain-path reduction adder enable. 1 = GFLOW accumulate sums ALL drained
  // lanes (a conventional N-input / log2(N) tree). 0 = ablation: accumulate
  // only the single drained lane, i.e. no reduction hardware at all.
  parameter bit RED_TREE = 1'b1;

  // ----------------------------------------------------------------------
  // ALU operation codes (shared by scalar ALU and grid tiles)
  // ----------------------------------------------------------------------
  typedef logic [4:0] alu_op_t;
  localparam alu_op_t ALU_ADD   = 5'd0;
  localparam alu_op_t ALU_SUB   = 5'd1;
  localparam alu_op_t ALU_SLL   = 5'd2;
  localparam alu_op_t ALU_SLT   = 5'd3;   // signed set-less-than
  localparam alu_op_t ALU_SLTU  = 5'd4;   // unsigned set-less-than
  localparam alu_op_t ALU_XOR   = 5'd5;
  localparam alu_op_t ALU_SRL   = 5'd6;
  localparam alu_op_t ALU_SRA   = 5'd7;
  localparam alu_op_t ALU_OR    = 5'd8;
  localparam alu_op_t ALU_AND   = 5'd9;
  localparam alu_op_t ALU_COPYA = 5'd10;  // pass operand A (routing)
  localparam alu_op_t ALU_COPYB = 5'd11;  // pass operand B (routing)
  localparam alu_op_t ALU_MUL   = 5'd12;  // low 32 bits of a*b (M-ext style)
  localparam alu_op_t ALU_MIN   = 5'd13;  // signed minimum (grid-only op)
  localparam alu_op_t ALU_MAX   = 5'd14;  // signed maximum (grid-only op)
  localparam alu_op_t ALU_NOP   = 5'd31;  // output 0

  // ----------------------------------------------------------------------
  // Grid tile operand source select. All sources are non-backward (never from
  // a higher column). NW/SW are diagonal forwards from the previous column,
  // which let a tile combine two adjacent rows of column c-1 in one step ->
  // single-pass spatial reduction trees (N -> N/2 -> ... per column).
  //   West  = reg_out(r,   c-1)
  //   North = reg_out(r-1, c)     (same column)
  //   South = reg_out(r+1, c)     (same column)
  //   NW    = reg_out(r-1, c-1)   (diagonal, previous column)
  //   SW    = reg_out(r+1, c-1)   (diagonal, previous column)
  // ----------------------------------------------------------------------
  typedef logic [2:0] src_sel_t;
  localparam src_sel_t SRC_WEST  = 3'd0;
  localparam src_sel_t SRC_NORTH = 3'd1;
  localparam src_sel_t SRC_SOUTH = 3'd2;
  localparam src_sel_t SRC_NW    = 3'd3;
  localparam src_sel_t SRC_SW    = 3'd4;
  // Extended operand sources (constant-operand extension):
  //   CONST = the tile's private constant register (written by GCFGI)
  //   EXTB  = the external stream-B injection bus. In GFLOW the hardware
  //           derives the EXTB column from the configuration and delays the
  //           stream-B fetch so blocks align with stream-A blocks in flight.
  localparam src_sel_t SRC_CONST = 3'd5;
  localparam src_sel_t SRC_EXTB  = 3'd6;

  // ----------------------------------------------------------------------
  // RV32I opcodes (instr[6:0])
  // ----------------------------------------------------------------------
  localparam logic [6:0] OP_LUI    = 7'b0110111;
  localparam logic [6:0] OP_AUIPC  = 7'b0010111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;
  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_LOAD   = 7'b0000011;
  localparam logic [6:0] OP_STORE  = 7'b0100011;
  localparam logic [6:0] OP_IMM    = 7'b0010011;  // ADDI etc.
  localparam logic [6:0] OP_REG    = 7'b0110011;  // ADD etc.
  localparam logic [6:0] OP_SYSTEM = 7'b1110011;  // ECALL
  // Custom extensions
  localparam logic [6:0] OP_CUSTOM0 = 7'b0001011;  // 0x0B : GCFG / GSTART
  localparam logic [6:0] OP_CUSTOM1 = 7'b0101011;  // 0x2B : VLW / VSW

  // custom-0 funct3
  localparam logic [2:0] F3_GCFG   = 3'b000;
  localparam logic [2:0] F3_GSTART = 3'b001;
  localparam logic [2:0] F3_GCFGI  = 3'b010;   // write a tile's constant register
  localparam logic [2:0] F3_GFLOW  = 3'b011;   // streaming grid execution
  // custom-1 funct3
  localparam logic [2:0] F3_VLW    = 3'b000;
  localparam logic [2:0] F3_VSW    = 3'b001;

endpackage

`endif
