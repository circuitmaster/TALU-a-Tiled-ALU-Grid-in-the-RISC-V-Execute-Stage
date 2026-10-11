// talu_mul.sv
// Building blocks for the pipelined 32x32 -> low-32 multiplier and for the
// GFLOW accumulator:
//   booth_pp  : radix-4 Booth partial products, already truncated mod 2^W
//   csa_tree  : LV levels of row-wise 3:2 carry-save compression
//   csa_sum   : compress to two rows, then one carry-propagate add
//
// Everything is modulo 2^W (only the low W bits of a product are needed for
// RV32 MUL), so sign extension and the top carries simply drop out.
`include "talu_pkg.sv"
`include "talu_mul_pkg.sv"

// --------------------------------------------------------------------------
// Radix-4 Booth: digit d_i in {-2,-1,0,1,2} from b[2i+1], b[2i], b[2i-1].
//   row i     = ((neg_i ? ~mag_i : mag_i) << 2i)  mod 2^W
//   row W/2   = sum_i neg_i << 2i                 (the "+1" of each negation)
// sum(rows) == a*b mod 2^W, for signed or unsigned operands.
// --------------------------------------------------------------------------
module booth_pp #(
  parameter int W = 32
) (
  input  logic [W-1:0]         a,
  input  logic [W-1:0]         b,
  output logic [(W/2+1)*W-1:0] rows
);
  localparam int D = W/2;
  wire [W-1:0] corr;

  genvar i;
  generate
    for (i = 0; i < D; i++) begin : g_dig
      wire bm1;
      if (i == 0) begin : g_first
        assign bm1 = 1'b0;
      end else begin : g_rest
        assign bm1 = b[2*i-1];
      end
      wire b0  = b[2*i];
      wire b1  = b[2*i+1];
      wire one = b0 ^ bm1;
      wire two = (b1 & ~b0 & ~bm1) | (~b1 & b0 & bm1);
      wire neg = b1 & ~(b0 & bm1);
      wire [W-1:0] mag = ({W{one}} & a) | ({W{two}} & {a[W-2:0], 1'b0});
      wire [W-1:0] pp  = {W{neg}} ^ mag;
      assign rows[i*W +: W] = pp << (2*i);
      assign corr[2*i]      = neg;
      assign corr[2*i+1]    = 1'b0;
    end
  endgenerate
  assign rows[D*W +: W] = corr;
endmodule

// --------------------------------------------------------------------------
// LV levels of 3:2 compression. Each level groups rows in threes:
//   sum = x ^ y ^ z,  carry = maj(x,y,z) << 1   (mod 2^W)
// leftover rows pass through. NOUT must equal csa_rows(NIN, LV).
// --------------------------------------------------------------------------
module csa_tree
  import talu_mul_pkg::*;
#(
  parameter int W    = 32,
  parameter int NIN  = 3,
  parameter int LV   = 1,
  parameter int NOUT = csa_rows(NIN, LV)
) (
  input  logic [NIN*W-1:0]  in_rows,
  output logic [NOUT*W-1:0] out_rows
);
  wire [W-1:0] lv [0:LV][0:NIN-1] /*verilator split_var*/;

  genvar l, k;
  generate
    for (k = 0; k < NIN; k++) begin : g_in
      assign lv[0][k] = in_rows[k*W +: W];
    end
    for (l = 0; l < LV; l++) begin : g_lvl
      localparam int NR = csa_rows(NIN, l);      // rows entering this level
      localparam int NG = (NR > 2) ? NR/3 : 0;   // full adders per bit
      localparam int NM = csa_rows(NIN, l+1);    // rows leaving this level
      for (k = 0; k < NG; k++) begin : g_fa
        wire [W-1:0] x = lv[l][3*k];
        wire [W-1:0] y = lv[l][3*k+1];
        wire [W-1:0] z = lv[l][3*k+2];
        assign lv[l+1][2*k]   = x ^ y ^ z;
        assign lv[l+1][2*k+1] = ((x & y) | (x & z) | (y & z)) << 1;
      end
      for (k = 3*NG; k < NR; k++) begin : g_pass
        assign lv[l+1][2*NG + (k - 3*NG)] = lv[l][k];
      end
      for (k = NM; k < NIN; k++) begin : g_zero
        assign lv[l+1][k] = '0;
      end
    end
    for (k = 0; k < NOUT; k++) begin : g_out
      assign out_rows[k*W +: W] = lv[LV][k];
    end
  endgenerate
endmodule

// --------------------------------------------------------------------------
// Sum of NIN rows: carry-save down to two rows, then a single CPA.
// --------------------------------------------------------------------------
module csa_sum
  import talu_mul_pkg::*;
#(
  parameter int W   = 32,
  parameter int NIN = 2
) (
  input  logic [NIN*W-1:0] rows,
  output logic [W-1:0]     y
);
  localparam int LV = csa_levels(NIN);
  localparam int NO = csa_rows(NIN, LV);     // 2 (or 1 when NIN == 1)
  logic [NO*W-1:0] r2;

  csa_tree #(.W(W), .NIN(NIN), .LV(LV), .NOUT(NO)) u_tree (.in_rows(rows), .out_rows(r2));

  generate
    if (NO == 1) begin : g_one
      assign y = r2[W-1:0];
    end else begin : g_two
      assign y = r2[W-1:0] + r2[W +: W];
    end
  endgenerate
endmodule
