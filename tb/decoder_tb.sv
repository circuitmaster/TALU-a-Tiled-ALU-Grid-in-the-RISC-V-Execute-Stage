// decoder_tb.sv -- self-checking testbench for decoder.sv + imm_gen.sv
`timescale 1ns/1ps
`include "talu_pkg.sv"

module decoder_tb;
  import talu_pkg::*;

  logic [31:0] instr;
  // decoder outputs
  logic [4:0]  rs1_addr, rs2_addr, rd_addr;
  logic        reg_we; logic [1:0] rd_src; alu_op_t alu_op;
  logic        alu_a_pc, alu_b_imm, mem_read, mem_write;
  logic [2:0]  mem_funct3; logic branch; logic [2:0] br_funct3;
  logic        jal, jalr, is_ecall;
  logic        is_gcfg; logic [2:0] g_row, g_col; alu_op_t g_op;
  src_sel_t    g_srca, g_srcb; logic g_drain;
  logic        is_gstart; logic [2:0] gs_vd, gs_vs1, gs_vs2; logic [4:0] gs_len; logic [3:0] gs_lanes;
  logic        is_vlw, is_vsw; logic [2:0] v_vd, v_vs;
  logic        is_gflow; logic [4:0] gf_dstreg, gf_cntreg; logic gf_mode;
  logic        is_gcfgi; logic [2:0] gi_row, gi_col;
  logic [31:0] imm;
  int errors = 0;

  decoder dut (.*);
  imm_gen ig (.instr(instr), .imm(imm));

  task automatic expect_eq(string nm, logic [31:0] got, logic [31:0] exp);
    if (got !== exp) begin $display("FAIL %-18s got=%0d(%08h) exp=%0d(%08h)", nm, got, got, exp, exp); errors++; end
    else $display("ok   %-18s = %0d", nm, got);
  endtask

  // instruction builders
  function automatic [31:0] rtype(logic [6:0] f7, logic [4:0] rs2, rs1, logic [2:0] f3, logic [4:0] rd, logic [6:0] op);
    return {f7, rs2, rs1, f3, rd, op};
  endfunction
  function automatic [31:0] itype(logic [11:0] imm12, logic [4:0] rs1, logic [2:0] f3, logic [4:0] rd, logic [6:0] op);
    return {imm12, rs1, f3, rd, op};
  endfunction
  function automatic [31:0] stype(logic [11:0] imm12, logic [4:0] rs2, rs1, logic [2:0] f3, logic [6:0] op);
    return {imm12[11:5], rs2, rs1, f3, imm12[4:0], op};
  endfunction
  // custom builders (field-OR, matches tools/asm.py)
  function automatic [31:0] gcfg(int row, int col, logic [4:0] op, logic [2:0] sa, logic [2:0] sb, logic dr);
    return OP_CUSTOM0 | (F3_GCFG<<12) | (row<<16) | (col<<19) | (op<<22)
           | (sa<<27) | (sb<<8) | (dr<<7);
  endfunction
  function automatic [31:0] gstart(int vd, int vs1, int vs2, logic [4:0] len, logic [3:0] lanes);
    return OP_CUSTOM0 | (F3_GSTART<<12) | (vd<<8) | (vs1<<16) | (vs2<<19)
           | (len<<22) | (lanes<<27);
  endfunction
  function automatic [31:0] vlw(int vd, int rs1, logic [11:0] imm12);
    return OP_CUSTOM1 | (F3_VLW<<12) | (vd<<8) | (rs1<<15) | (imm12<<20);
  endfunction
  function automatic [31:0] vsw(int vs, int rs1, logic [11:0] imm12);
    return OP_CUSTOM1 | (F3_VSW<<12) | (vs<<20) | (rs1<<15)
           | (imm12[4:0]<<7) | (imm12[11:5]<<25);
  endfunction

  initial begin
    // ADDI x1, x2, 5
    instr = itype(12'd5, 5'd2, 3'b000, 5'd1, OP_IMM); #1;
    expect_eq("ADDI rd", rd_addr, 1); expect_eq("ADDI rs1", rs1_addr, 2);
    expect_eq("ADDI imm", imm, 5); expect_eq("ADDI op", alu_op, ALU_ADD);
    expect_eq("ADDI we", reg_we, 1); expect_eq("ADDI b_imm", alu_b_imm, 1);

    // ADD x3, x4, x5
    instr = rtype(7'b0000000, 5'd5, 5'd4, 3'b000, 5'd3, OP_REG); #1;
    expect_eq("ADD op", alu_op, ALU_ADD); expect_eq("ADD b_imm", alu_b_imm, 0);
    expect_eq("ADD rs2", rs2_addr, 5);

    // SUB x3, x4, x5
    instr = rtype(7'b0100000, 5'd5, 5'd4, 3'b000, 5'd3, OP_REG); #1;
    expect_eq("SUB op", alu_op, ALU_SUB);

    // SRAI x1, x2, 3
    instr = itype({7'b0100000, 5'd3}, 5'd2, 3'b101, 5'd1, OP_IMM); #1;
    expect_eq("SRAI op", alu_op, ALU_SRA);

    // LW x6, 8(x7)
    instr = itype(12'd8, 5'd7, 3'b010, 5'd6, OP_LOAD); #1;
    expect_eq("LW memrd", mem_read, 1); expect_eq("LW rdsrc", rd_src, 1);
    expect_eq("LW imm", imm, 8); expect_eq("LW f3", mem_funct3, 3'b010);

    // SW x8, -4(x9)   (-4 = 12'hFFC)
    instr = stype(12'hFFC, 5'd8, 5'd9, 3'b010, OP_STORE); #1;
    expect_eq("SW memwr", mem_write, 1); expect_eq("SW imm", imm, 32'hFFFFFFFC);
    expect_eq("SW rs2", rs2_addr, 8);
    // SW x8, 12(x9)
    instr = stype(12'd12, 5'd8, 5'd9, 3'b010, OP_STORE); #1;
    expect_eq("SW imm+", imm, 12);

    // BEQ x1, x2, +16
    instr = {1'b0, 6'd0, 5'd2, 5'd1, 3'b000, 4'd8, 1'b0, OP_BRANCH}; #1; // imm=16
    expect_eq("BEQ branch", branch, 1); expect_eq("BEQ imm", imm, 16);

    // LUI x1, 0x12345
    instr = {20'h12345, 5'd1, OP_LUI}; #1;
    expect_eq("LUI we", reg_we, 1); expect_eq("LUI rdsrc", rd_src, 3);
    expect_eq("LUI imm", imm, 32'h12345000);

    // GCFG row=1 col=2 op=SUB srcA=W srcB=N drain=1
    instr = gcfg(1, 2, ALU_SUB, SRC_WEST, SRC_NORTH, 1'b1); #1;
    expect_eq("GCFG is",   is_gcfg, 1);  expect_eq("GCFG row", g_row, 1);
    expect_eq("GCFG col",  g_col, 2);    expect_eq("GCFG op", g_op, ALU_SUB);
    expect_eq("GCFG srca", g_srca, SRC_WEST); expect_eq("GCFG srcb", g_srcb, SRC_NORTH);
    expect_eq("GCFG drain",g_drain, 1);

    // GSTART vd=3 vs1=1 vs2=2 len=4 lanes=0011
    instr = gstart(3, 1, 2, 5'd4, 4'b0011); #1;
    expect_eq("GSTART is",  is_gstart, 1); expect_eq("GSTART vd", gs_vd, 3);
    expect_eq("GSTART vs1", gs_vs1, 1);    expect_eq("GSTART vs2", gs_vs2, 2);
    expect_eq("GSTART len", gs_len, 4);    expect_eq("GSTART lanes", gs_lanes, 4'b0011);

    // VLW v5, 16(x10)
    instr = vlw(5, 10, 12'd16); #1;
    expect_eq("VLW is", is_vlw, 1); expect_eq("VLW vd", v_vd, 5);
    expect_eq("VLW rs1", rs1_addr, 10); expect_eq("VLW imm", imm, 16);

    // VSW v6, 20(x11)
    instr = vsw(6, 11, 12'd20); #1;
    expect_eq("VSW is", is_vsw, 1); expect_eq("VSW vs", v_vs, 6);
    expect_eq("VSW rs1", rs1_addr, 11); expect_eq("VSW imm", imm, 20);

    // GFLOW src1=x10 src2=x11 dst=x12 count=x13 mode=1
    instr = OP_CUSTOM0 | (3<<12) | (12<<7) | (10<<15) | (11<<20) | (1<<26) | (13<<27);
    #1;
    expect_eq("GFLOW is", is_gflow, 1);  expect_eq("GFLOW src1", rs1_addr, 10);
    expect_eq("GFLOW src2", rs2_addr, 11); expect_eq("GFLOW dst", gf_dstreg, 12);
    expect_eq("GFLOW cnt", gf_cntreg, 13); expect_eq("GFLOW mode", gf_mode, 1);

    // GCFGI row=2 col=3 rs1=x14   (tile const := x14)
    instr = OP_CUSTOM0 | (F3_GCFGI<<12) | (2<<7) | (3<<22) | (14<<15); #1;
    expect_eq("GCFGI is", is_gcfgi, 1); expect_eq("GCFGI row", gi_row, 2);
    expect_eq("GCFGI col", gi_col, 3);  expect_eq("GCFGI rs1", rs1_addr, 14);
    expect_eq("GCFGI no-we", reg_we, 0);

    if (errors == 0) $display("\nDECODER_TB PASS");
    else             $display("\nDECODER_TB FAIL (%0d)", errors);
    $finish;
  end
endmodule
