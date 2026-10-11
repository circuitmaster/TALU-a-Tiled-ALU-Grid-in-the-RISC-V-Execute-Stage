// talu_top.sv
// Simulation top: core + instruction memory + data memory.
`include "talu_pkg.sv"

module talu_top
  import talu_pkg::*;
#(
  parameter int  N      = GRID_N,
  parameter int  IWORDS = 1024,
  parameter int  DWORDS = 1024,
  parameter      IMEM_INIT = "",
  parameter      DMEM_INIT = ""
) (
  input  logic clk,
  input  logic rst_n,
  output logic halt
);
  // instruction memory
  logic [31:0] imem_addr, imem_rdata;
  imem #(.WORDS(IWORDS), .INIT(IMEM_INIT)) u_imem (.addr(imem_addr), .rdata(imem_rdata));

  // data memory scalar port
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic        dmem_we, dmem_re; logic [2:0] dmem_funct3;
  // data memory vector ports (2 wide reads + 1 wide write)
  logic [31:0]      vA_addr, vB_addr, vW_addr;
  logic             vW_we;
  logic [N*32-1:0]  vA_rdata, vB_rdata, vW_wdata;
  logic [N-1:0]     vW_wmask;

  dmem #(.N(N), .WORDS(DWORDS), .INIT(DMEM_INIT)) u_dmem (
    .clk,
    .s_addr(dmem_addr), .s_we(dmem_we), .s_re(dmem_re),
    .s_funct3(dmem_funct3), .s_wdata(dmem_wdata), .s_rdata(dmem_rdata),
    .vA_addr, .vA_rdata, .vB_addr, .vB_rdata,
    .vW_addr, .vW_we, .vW_wdata, .vW_wmask
  );

  core #(.N(N)) u_core (
    .clk, .rst_n,
    .imem_addr, .imem_rdata,
    .dmem_addr, .dmem_we, .dmem_re, .dmem_funct3, .dmem_wdata, .dmem_rdata,
    .vA_addr, .vA_rdata, .vB_addr, .vB_rdata,
    .vW_addr, .vW_we, .vW_wdata, .vW_wmask,
    .halt
  );
endmodule
