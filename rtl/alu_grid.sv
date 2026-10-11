// alu_grid.sv
// N x N grid of ALU tiles forming the configurable execute fabric.
//
// Geometry: rows r = 0..N-1 (top..bottom), cols c = 0..N-1 (input..output).
// Forward pipeline direction = increasing column (left -> right).
//   - West  source of tile (r,c) : reg_y(r,c-1), or injected operand at c==0
//   - North source                : reg_y(r-1,c)   (0 at r==0)
//   - South source                : reg_y(r+1,c)   (0 at r==N-1)
//   Backward (from c+1) is never a source -> no backward flow.
//
// Outputs:
//   scalar_y       : stage-1 ALU result of tile (0,0)  -- the RV32I scalar tap
//   scalar_rows    : stage-1 multiplier rows of tile (0,0) -- scalar MUL tap
//   drain_val[r]   : registered result drained from row r's edge tile
//   drain_act[r]   : 1 if row r has an (enabled, perimeter) drain tile
//
// Drain is permitted only on perimeter tiles + the input column (c==0); the
// per-row drain output lane equals the row of the draining tile.  At most one
// drain tile per row is expected (programmer's responsibility); if several are
// enabled, the furthest-forward (highest column) wins.
//
// will_go_to_ASIC: identical to src/ except that tile (0,0) receives the
// scalar operand port (see alu_tile.sv) and exports its multiplier rows.
`include "talu_pkg.sv"
`include "talu_mul_pkg.sv"

module alu_grid
  import talu_pkg::*;
  import talu_mul_pkg::*;
#(
  parameter int N = GRID_N,
  parameter int W = XLEN,
  parameter logic [N*N-1:0] MULS = MUL_MASK,  // per-tile multiplier presence
  parameter bit DIAG = DIAG_EN,               // 0 = no NW/SW diagonal links
  parameter int MR1  = csa_rows(W/2 + 1, MUL_S1_LV)
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               step,                 // advance all tile registers

  // flattened per-tile configuration, index = r*N + c
  input  logic [N*N*5-1:0]   op_flat,
  input  logic [N*N*3-1:0]   srca_flat,
  input  logic [N*N*3-1:0]   srcb_flat,
  input  logic [N*N-1:0]     drain_flat,
  input  logic [N*N*W-1:0]   const_flat,   // per-tile constants (GCFGI)

  // column-0 injected operands, one per row
  input  logic [N*W-1:0]     inj_a_flat,
  input  logic [N*W-1:0]     inj_b_flat,
  // external stream-B bus, one word per row, selectable by any tile (SRC_EXTB)
  input  logic [N*W-1:0]     extb_flat,

  // scalar port of tile (0,0)
  input  logic               sc_grid,
  input  logic [2:0]         sc_asel,
  input  logic [2:0]         sc_bsel,
  input  logic [W-1:0]       sc_mem,
  input  logic [W-1:0]       sc_wb,
  input  logic [W-1:0]       sc_ra,
  input  logic [W-1:0]       sc_rb,

  // outputs
  output logic [W-1:0]       scalar_y,
  output logic [MR1*W-1:0]   scalar_rows,
  output logic [N*W-1:0]     drain_val_flat,
  output logic [N-1:0]       drain_act
);

  logic [W-1:0]     reg_y  [N][N];
  logic [W-1:0]     comb_y [N][N];
  logic [MR1*W-1:0] comb_r [N][N];

  genvar r, c;
  generate
    for (r = 0; r < N; r++) begin : g_row
      for (c = 0; c < N; c++) begin : g_col
        // neighbour wiring (boundaries guarded so unused indices never elaborate)
        logic [W-1:0] wa, wb, nn, ss, nw, sw;
        if (c == 0) begin : g_winj
          assign wa = inj_a_flat[r*W +: W];
          assign wb = inj_b_flat[r*W +: W];
        end else begin : g_wnbr
          assign wa = reg_y[r][c-1];
          assign wb = reg_y[r][c-1];
        end
        if (r == 0)   assign nn = '0; else assign nn = reg_y[r-1][c];
        if (r == N-1) assign ss = '0; else assign ss = reg_y[r+1][c];
        // diagonal forwards from previous column (0 at left/top/bottom edges)
        if (r == 0   || c == 0 || !DIAG) assign nw = '0; else assign nw = reg_y[r-1][c-1];
        if (r == N-1 || c == 0 || !DIAG) assign sw = '0; else assign sw = reg_y[r+1][c-1];

        alu_tile #(.W(W), .HAS_MUL(MULS[r*N+c]), .SCALAR(r == 0 && c == 0), .MR1(MR1)) u_tile (
          .clk, .rst_n, .step,
          .wa_in (wa), .wb_in (wb), .n_in (nn), .s_in (ss), .nw_in (nw), .sw_in (sw),
          .const_in(const_flat[(r*N+c)*W +: W]),
          .extb_in (extb_flat[r*W +: W]),
          .op    (alu_op_t' (op_flat [(r*N+c)*5 +: 5])),
          .src_a (src_sel_t'(srca_flat[(r*N+c)*3 +: 3])),
          .src_b (src_sel_t'(srcb_flat[(r*N+c)*3 +: 3])),
          .sc_grid, .sc_asel, .sc_bsel, .sc_mem, .sc_wb, .sc_ra, .sc_rb,
          .comb_y   (comb_y[r][c]),
          .comb_rows(comb_r[r][c]),
          .reg_y    (reg_y [r][c])
        );
      end
    end
  endgenerate

  // scalar taps
  assign scalar_y    = comb_y[0][0];
  assign scalar_rows = comb_r[0][0];

  // per-row drain mux (perimeter + input column only), highest column wins
  function automatic logic is_perimeter(input int rr, input int cc);
    return (rr == 0) || (rr == N-1) || (cc == 0) || (cc == N-1);
  endfunction

  always_comb begin
    for (int rr = 0; rr < N; rr++) begin
      drain_act[rr]                = 1'b0;
      drain_val_flat[rr*W +: W]    = '0;
      for (int cc = 0; cc < N; cc++) begin
        if (drain_flat[rr*N+cc] && is_perimeter(rr, cc)) begin
          drain_act[rr]             = 1'b1;
          drain_val_flat[rr*W +: W] = reg_y[rr][cc];
        end
      end
    end
  end

endmodule
