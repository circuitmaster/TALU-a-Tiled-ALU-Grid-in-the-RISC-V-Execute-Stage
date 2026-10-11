// imem.sv
// Instruction memory: word-addressable, asynchronous read.
// Loaded from a hex image ($readmemh) given by the INIT parameter.
`include "talu_pkg.sv"

module imem #(
  parameter int  WORDS = 1024,
  parameter      INIT  = ""
) (
  input  logic [31:0] addr,    // byte address (PC)
  output logic [31:0] rdata
);
  logic [31:0] mem [WORDS];

  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h00000013; // NOP (ADDI x0,x0,0)
    if (INIT != "") $readmemh(INIT, mem);
  end

  assign rdata = mem[addr[31:2] % WORDS];
endmodule
