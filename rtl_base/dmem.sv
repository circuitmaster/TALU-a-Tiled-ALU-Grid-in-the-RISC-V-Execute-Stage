// dmem.sv
// Data memory with two access ports sharing one word array:
//   - scalar port : RV32I LB/LH/LW/LBU/LHU + SB/SH/SW (sub-word via byte enables)
//   - vector port : wide N-word read and write (for VLW/VSW and grid drain)
// Asynchronous read, synchronous write.  Scalar and vector writes never collide
// (different instructions); scalar write takes priority if both asserted.
`include "talu_pkg.sv"

module dmem
  import talu_pkg::*;
#(
  parameter int N     = GRID_N,
  parameter int WORDS = 1024,
  parameter      INIT = ""
) (
  input  logic              clk,

  // scalar port
  input  logic [31:0]       s_addr,     // byte address
  input  logic              s_we,
  input  logic              s_re,
  input  logic [2:0]        s_funct3,   // size/sign for load, size for store
  input  logic [31:0]       s_wdata,
  output logic [31:0]       s_rdata,

  // wide vector ports (word-aligned base addresses):
  //   two independent read streams (A,B) + one write stream
  input  logic [31:0]       vA_addr,
  output logic [N*32-1:0]   vA_rdata,
  input  logic [31:0]       vB_addr,
  output logic [N*32-1:0]   vB_rdata,
  input  logic [31:0]       vW_addr,
  input  logic              vW_we,
  input  logic [N*32-1:0]   vW_wdata,
  input  logic [N-1:0]      vW_wmask
);
  logic [31:0] mem [WORDS];

  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h0;
    if (INIT != "") $readmemh(INIT, mem);
  end

  // ---------------- scalar read (combinational, sign/zero-extended) ----------
  logic [31:0] s_word;
  logic [1:0]  s_boff;
  assign s_word = mem[s_addr[31:2] % WORDS];
  assign s_boff = s_addr[1:0];

  logic [7:0]  s_byte;
  logic [15:0] s_half;
  assign s_byte = s_word[s_boff*8 +: 8];
  assign s_half = s_boff[1] ? s_word[31:16] : s_word[15:0];

  always_comb begin
    unique case (s_funct3)
      3'b000:  s_rdata = {{24{s_byte[7]}},  s_byte};   // LB
      3'b001:  s_rdata = {{16{s_half[15]}}, s_half};   // LH
      3'b010:  s_rdata = s_word;                       // LW
      3'b100:  s_rdata = {24'b0, s_byte};              // LBU
      3'b101:  s_rdata = {16'b0, s_half};              // LHU
      default: s_rdata = s_word;
    endcase
  end

  // ---------------- wide vector reads (combinational) ------------------------
  always_comb begin
    for (int l = 0; l < N; l++) begin
      vA_rdata[l*32 +: 32] = mem[(vA_addr[31:2] + l) % WORDS];
      vB_rdata[l*32 +: 32] = mem[(vB_addr[31:2] + l) % WORDS];
    end
  end

  // ---------------- writes (synchronous) -------------------------------------
  logic [31:0] s_widx;
  assign s_widx = s_addr[31:2] % WORDS;

  always_ff @(posedge clk) begin
    if (s_we) begin
      unique case (s_funct3)
        3'b000: mem[s_widx][s_boff*8 +: 8] <= s_wdata[7:0];      // SB
        3'b001: begin                                            // SH
          if (s_boff[1]) mem[s_widx][31:16] <= s_wdata[15:0];
          else           mem[s_widx][15:0]  <= s_wdata[15:0];
        end
        default: mem[s_widx] <= s_wdata;                         // SW
      endcase
    end else if (vW_we) begin
      for (int l = 0; l < N; l++)
        if (vW_wmask[l]) mem[(vW_addr[31:2] + l) % WORDS] <= vW_wdata[l*32 +: 32];
    end
  end
endmodule
