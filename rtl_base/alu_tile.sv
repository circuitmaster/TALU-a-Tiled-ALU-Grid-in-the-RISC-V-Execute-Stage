// alu_tile.sv
// One cell of the ALU grid: operand-source muxes + ALU + output register.
//
// Operand sources (per the no-backward-flow rule):
//   West  = wa_in / wb_in  (registered output of the (r,c-1) "before" neighbour;
//                  for interior tiles wa_in==wb_in==neighbour, but column-0 tiles
//                  inject two distinct operands so operand A and B have separate
//                  West feeds)
//   North = n_in  (registered output of the (r-1,c) neighbour)
//   South = s_in  (registered output of the (r+1,c) neighbour)
//
// comb_y : combinational ALU result  (used by the scalar tap at tile 0,0)
// reg_y  : registered ALU result     (used to feed downstream tiles, systolic)
`include "talu_pkg.sv"

module alu_tile
  import talu_pkg::*;
#(
  parameter int W = XLEN,
  parameter bit HAS_MUL = 1'b1
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         step,      // advance the output register (systolic clock-enable)
  // neighbour inputs (West split into per-operand feeds for column-0 injection)
  input  logic [W-1:0] wa_in,
  input  logic [W-1:0] wb_in,
  input  logic [W-1:0] n_in,
  input  logic [W-1:0] s_in,
  input  logic [W-1:0] nw_in,   // diagonal: (r-1, c-1)
  input  logic [W-1:0] sw_in,   // diagonal: (r+1, c-1)
  input  logic [W-1:0] const_in, // tile's private constant register (GCFGI)
  input  logic [W-1:0] extb_in,  // external stream-B injection bus (GFLOW)
  // per-tile configuration
  input  alu_op_t      op,
  input  src_sel_t     src_a,
  input  src_sel_t     src_b,
  // outputs
  output logic [W-1:0] comb_y,
  output logic [W-1:0] reg_y
);

  logic [W-1:0] a, b;

  always_comb begin
    unique case (src_a)
      SRC_NORTH: a = n_in;
      SRC_SOUTH: a = s_in;
      SRC_NW   : a = nw_in;
      SRC_SW   : a = sw_in;
      SRC_CONST: a = const_in;
      SRC_EXTB : a = extb_in;
      default  : a = wa_in;    // SRC_WEST
    endcase
    unique case (src_b)
      SRC_NORTH: b = n_in;
      SRC_SOUTH: b = s_in;
      SRC_NW   : b = nw_in;
      SRC_SW   : b = sw_in;
      SRC_CONST: b = const_in;
      SRC_EXTB : b = extb_in;
      default  : b = wb_in;    // SRC_WEST
    endcase
  end

  alu #(.W(W), .HAS_MUL(HAS_MUL)) u_alu (.op(op), .a(a), .b(b), .y(comb_y));

  always_ff @(posedge clk) begin
    if (!rst_n)      reg_y <= '0;
    else if (step)   reg_y <= comb_y;
  end

endmodule
