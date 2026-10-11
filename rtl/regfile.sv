// regfile.sv
// Scalar RV32I register file: 32 x 32-bit.
//  - 2 combinational read ports, 1 synchronous write port
//  - x0 hard-wired to 0 (writes ignored)
//  - write-first bypass: a read sees a same-cycle write
`include "talu_pkg.sv"

module regfile
  import talu_pkg::*;
(
  input  logic            clk,
  input  logic            rst_n,
  input  logic            we,
  input  logic [4:0]      waddr,
  input  logic [XLEN-1:0] wdata,
  input  logic [4:0]      raddr1,
  output logic [XLEN-1:0] rdata1,
  input  logic [4:0]      raddr2,
  output logic [XLEN-1:0] rdata2,
  // extra read ports (used by the GFLOW streaming engine: dst base, count)
  input  logic [4:0]      raddr3,
  output logic [XLEN-1:0] rdata3,
  input  logic [4:0]      raddr4,
  output logic [XLEN-1:0] rdata4
);

  // Flat packed registers (explicit flops, not a memory) -> clean synthesis.
  // Slot 0 (x0) exists but is never written and reads as 0.
  logic [32*XLEN-1:0] rf;

  // synchronous reset (clock runs during reset in all testbenches)
  always_ff @(posedge clk) begin
    if (!rst_n) rf <= '0;
    else if (we && waddr != 5'd0)
      for (int r = 1; r < 32; r++) if (waddr == r) rf[r*XLEN +: XLEN] <= wdata;
  end

  // write-first bypass
  wire hit1 = we && (waddr == raddr1) && (waddr != 5'd0);
  wire hit2 = we && (waddr == raddr2) && (waddr != 5'd0);
  wire hit3 = we && (waddr == raddr3) && (waddr != 5'd0);
  wire hit4 = we && (waddr == raddr4) && (waddr != 5'd0);

  assign rdata1 = (raddr1 == 5'd0) ? '0 : (hit1 ? wdata : rf[raddr1*XLEN +: XLEN]);
  assign rdata2 = (raddr2 == 5'd0) ? '0 : (hit2 ? wdata : rf[raddr2*XLEN +: XLEN]);
  assign rdata3 = (raddr3 == 5'd0) ? '0 : (hit3 ? wdata : rf[raddr3*XLEN +: XLEN]);
  assign rdata4 = (raddr4 == 5'd0) ? '0 : (hit4 ? wdata : rf[raddr4*XLEN +: XLEN]);

endmodule
