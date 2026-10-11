// alu_tile.sv  -- will_go_to_ASIC: two-stage tile for a 1.0 ns cycle.
//
// Same contract as src_opt/alu_tile.sv: EVERY tile is two pipeline stages,
// whatever its configured op, so all tiles in a column keep equal latency and
// the feed-forward / diagonal dataflow is unchanged (only the fill deepens).
//
// What is different is WHERE the multiplier is cut. src_opt splits the 32x32
// product into two 32x16 products and adds them in stage 2; at 45 nm a single
// 32x16 product is still ~1.14 ns (report section 11), longer than the cycle.
// Here the cut is inside the carry-save tree:
//
//   stage 1 : operand muxes + every non-multiply ALU op
//             + radix-4 Booth rows (17) + 4 levels of 3:2 compression -> 4 rows
//   stage 2 : 2 more 3:2 levels -> 2 rows -> one 32-bit CPA, or the ALU result
//
// Tile (0,0) (SCALAR=1) is also the scalar ALU, exactly as in the baseline.
// Its ALU operands come from a one-hot AND-OR that merges the grid operand with
// the three scalar forwarding sources (MEM result, WB result, ID/EX register),
// so scalar forwarding costs one gate level in front of the ALU and the
// forwarding *decision* is made a stage earlier (core.sv). Its multiplier
// always takes the ordinary grid operands: for a scalar MUL, core.sv loads
// the operands into the column-0 injection registers and selects West, so
// scalar forwarding never reaches the multiplier in the same cycle and the
// multiplier inputs carry no extra mux.
`include "talu_pkg.sv"
`include "talu_mul_pkg.sv"

module alu_tile
  import talu_pkg::*;
  import talu_mul_pkg::*;
#(
  parameter int W       = XLEN,
  parameter bit HAS_MUL = 1'b1,
  parameter bit SCALAR  = 1'b0,                      // 1 only for tile (0,0)
  parameter int MR1     = csa_rows(W/2 + 1, MUL_S1_LV)  // stage-1 rows (4)
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         step,      // advance both stages (systolic clock-enable)
  input  logic [W-1:0] wa_in,
  input  logic [W-1:0] wb_in,
  input  logic [W-1:0] n_in,
  input  logic [W-1:0] s_in,
  input  logic [W-1:0] nw_in,
  input  logic [W-1:0] sw_in,
  input  logic [W-1:0] const_in,
  input  logic [W-1:0] extb_in,
  input  alu_op_t      op,
  input  src_sel_t     src_a,
  input  src_sel_t     src_b,
  // scalar port: used only when SCALAR=1. All selects are flop outputs.
  input  logic         sc_grid,   // 1 = grid operands (grid mode, EX bubble)
  input  logic [2:0]   sc_asel,   // one-hot {reg, wb, mem} for operand A
  input  logic [2:0]   sc_bsel,   // one-hot {reg, wb, mem} for operand B
  input  logic [W-1:0] sc_mem,    // forwarding source: EX/MEM result
  input  logic [W-1:0] sc_wb,     // forwarding source: MEM/WB result
  input  logic [W-1:0] sc_ra,     // ID/EX operand A (rs1 / pc / 0)
  input  logic [W-1:0] sc_rb,     // ID/EX operand B (rs2 / imm / 4)
  // outputs
  output logic [W-1:0]     comb_y,     // stage-1 ALU result (scalar tap; 0 for MUL)
  output logic [MR1*W-1:0] comb_rows,  // stage-1 multiplier rows (scalar MUL tap)
  output logic [W-1:0]     reg_y
);

  // ---------------- grid operand muxes (unchanged) ----------------
  logic [W-1:0] ag, bg;
  always_comb begin
    unique case (src_a)
      SRC_NORTH: ag = n_in;
      SRC_SOUTH: ag = s_in;
      SRC_NW   : ag = nw_in;
      SRC_SW   : ag = sw_in;
      SRC_CONST: ag = const_in;
      SRC_EXTB : ag = extb_in;
      default  : ag = wa_in;    // SRC_WEST
    endcase
    unique case (src_b)
      SRC_NORTH: bg = n_in;
      SRC_SOUTH: bg = s_in;
      SRC_NW   : bg = nw_in;
      SRC_SW   : bg = sw_in;
      SRC_CONST: bg = const_in;
      SRC_EXTB : bg = extb_in;
      default  : bg = wb_in;    // SRC_WEST
    endcase
  end

  // ---------------- scalar override of the ALU operands (tile (0,0)) -------
  logic [W-1:0] a, b;
  generate
    if (SCALAR) begin : g_sc
      assign a = ({W{sc_grid}}    & ag)     | ({W{sc_asel[0]}} & sc_mem) |
                 ({W{sc_asel[1]}} & sc_wb)  | ({W{sc_asel[2]}} & sc_ra);
      assign b = ({W{sc_grid}}    & bg)     | ({W{sc_bsel[0]}} & sc_mem) |
                 ({W{sc_bsel[1]}} & sc_wb)  | ({W{sc_bsel[2]}} & sc_rb);
    end else begin : g_grid
      assign a = ag;
      assign b = bg;
    end
  endgenerate

  // ---------------- stage 1 ----------------
  logic [W-1:0] s1_alu;
  alu #(.W(W), .HAS_MUL(1'b0)) u_alu (.op(op), .a(a), .b(b), .y(s1_alu));
  assign comb_y = s1_alu;

  wire is_mul = HAS_MUL && (op == ALU_MUL);

  logic [W-1:0] q_alu;
  logic         q_mul;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      q_alu <= '0; q_mul <= 1'b0;
    end else if (step) begin
      q_alu <= s1_alu; q_mul <= is_mul;
    end
  end

  logic [W-1:0] mul_y;
  generate
    if (HAS_MUL) begin : g_mul
      logic [(W/2+1)*W-1:0] pp;
      logic [MR1*W-1:0]     q_rows;
      booth_pp #(.W(W)) u_pp (.a(ag), .b(bg), .rows(pp));
      csa_tree #(.W(W), .NIN(W/2+1), .LV(MUL_S1_LV), .NOUT(MR1))
        u_s1 (.in_rows(pp), .out_rows(comb_rows));
      // No reset: q_rows is only read when q_mul (which is reset) is set, and
      // both are loaded together. Keeps the reset gate off the stage-1 path.
      always_ff @(posedge clk) if (step) q_rows <= comb_rows;
      // ---------------- stage 2 (multiply) ----------------
      csa_sum #(.W(W), .NIN(MR1)) u_s2 (.rows(q_rows), .y(mul_y));
    end else begin : g_nomul
      assign comb_rows = '0;
      assign mul_y     = '0;
    end
  endgenerate

  // ---------------- stage 2 ----------------
  wire [W-1:0] s2_y = q_mul ? mul_y : q_alu;

  always_ff @(posedge clk) begin
    if (!rst_n)    reg_y <= '0;
    else if (step) reg_y <= s2_y;
  end

endmodule
