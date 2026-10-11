// vregfile.sv
// Vector register file: VREGS registers, each N lanes x XLEN bits wide.
//  - 2 wide combinational read ports (operand streams vs1, vs2 for the grid)
//  - 1 wide synchronous write port with per-lane write mask
//
// The same registers serve scalar (lane 0 slice) and multi-path (N lanes) use;
// slicing is done by the consumer.  The per-lane write mask lets a GSTART drain
// update only the lanes that actually produced a result.
`include "talu_pkg.sv"

module vregfile
  import talu_pkg::*;
#(
  parameter int N     = GRID_N,
  parameter int W     = XLEN,
  parameter int NREGS = VREGS
) (
  input  logic                 clk,
  input  logic                 rst_n,
  // wide write port
  input  logic                 we,
  input  logic [$clog2(NREGS)-1:0] waddr,
  input  logic [N*W-1:0]       wdata,
  input  logic [N-1:0]         wmask,     // per-lane enable
  // wide read ports
  input  logic [$clog2(NREGS)-1:0] raddr1,
  output logic [N*W-1:0]       rdata1,
  input  logic [$clog2(NREGS)-1:0] raddr2,
  output logic [N*W-1:0]       rdata2
);

  // Flat packed registers (explicit flops, not a memory) -> clean synthesis.
  localparam int VW = N*W;             // bits per vector register
  logic [NREGS*VW-1:0] vrf;

  // synchronous reset (clock runs during reset in all testbenches)
  always_ff @(posedge clk) begin
    if (!rst_n) vrf <= '0;
    else if (we)
      // single flat loop (rl = r*N + l); reg = rl/N, lane = rl%N
      for (int rl = 0; rl < NREGS*N; rl++)
        if ((waddr == rl/N) && wmask[rl%N])
          vrf[rl*W +: W] <= wdata[(rl%N)*W +: W];
  end

  assign rdata1 = vrf[raddr1*VW +: VW];
  assign rdata2 = vrf[raddr2*VW +: VW];

endmodule
