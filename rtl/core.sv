// core.sv
// TALU 5-stage pipelined RV32IM core with an N x N ALU grid execute fabric.
//
// ===========================================================================
// will_go_to_ASIC variant: retimed for a 1.0 ns cycle (45 nm NanGate target)
// without changing what TALU is:
//   * the N x N grid still IS the execute stage, and tile (0,0) still IS the
//     scalar ALU (scalar ops and scalar MUL both run on tile (0,0)'s logic);
//   * the grid still advances ONE systolic step per clock;
//   * ISA, encodings, kernels and the drain/EXTB/diagonal dataflow unchanged.
//
// Timing changes (see will_go_to_ASIC/README.md for the path budget):
//  T1 two-stage tiles, multiplier cut inside its carry-save tree (alu_tile.sv)
//  T2 forwarding decisions made in ID and registered one-hot; EX does a single
//     AND-OR in front of tile (0,0)'s ALU. PC+4 / LUI values are produced by
//     the ALU (operands chosen in ID), so there is no result mux after it.
//  T3 scalar MUL: forwarded operands latched into tile (0,0)'s column-0
//     injection registers (cycle 1), tile (0,0)'s Booth + 4 CSA levels into
//     core registers (cycle 2), remaining CSA + CPA (cycle 3). Uses tile
//     (0,0)'s own multiplier through its normal West inputs; captures into
//     core registers so the grid's pipeline state is never disturbed.
//  T4 branch/jump resolved in EX, redirect registered and applied the next
//     cycle (taken branch = 3 flushed slots instead of 2). ECALL halts from EX.
//  T5 GFLOW control flags (inject / B-fetch / output / last) precomputed into
//     flops; stream counters are down-counters; injection registered.
//  T6 GFLOW accumulate: drained lanes registered; the accumulator is kept in
//     carry-save form (two registers), so the per-block loop is only 3:2
//     levels; the single CPA is taken once, when the result is written out.
//  T7 path latency / EXTB column derived per column (OR over rows, then an
//     N-input priority scan) instead of a running max over all N*N tiles.
//
// Architectural differences vs. the baseline core -- identical to the
// collaborator's src_opt core, because the tile depth (2) is the same:
//  1. N/S sources inside GFLOW read the neighbour two blocks back, not one.
//  2. EXTB in more than one column / drains in more than one column shift the
//     inter-column timing by 2 steps per column instead of 1.
// Scalar code, GSTART and well-formed GFLOW programs are bit-identical to the
// baseline; ALL programs are bit-identical to src_opt (verif/README).
// ===========================================================================
//
//  - GCFG  : writes the per-tile grid configuration registers (committed in EX).
//  - GSTART: multi-cycle. A small FSM stalls the front-end, injects the operand
//    vectors (vs1/vs2) into the grid's column-0 West feeds, steps the systolic
//    array 2*`len` cycles, then drains the perimeter tiles into vector reg vd.
//    (Grid mode assumes no inter-instruction data hazards.)
//  - VLW/VSW: wide N-word vector load/store via the data-memory vector port.
`include "talu_pkg.sv"
`include "talu_mul_pkg.sv"

module core
  import talu_pkg::*;
  import talu_mul_pkg::*;
#(
  parameter int N = GRID_N
) (
  input  logic        clk,
  input  logic        rst_n,
  // instruction memory
  output logic [31:0] imem_addr,
  input  logic [31:0] imem_rdata,
  // data memory scalar port
  output logic [31:0] dmem_addr,
  output logic        dmem_we,
  output logic        dmem_re,
  output logic [2:0]  dmem_funct3,
  output logic [31:0] dmem_wdata,
  input  logic [31:0] dmem_rdata,
  // data memory vector ports (2 wide reads + 1 wide write)
  output logic [31:0]      vA_addr,
  input  logic [N*32-1:0]  vA_rdata,
  output logic [31:0]      vB_addr,
  input  logic [N*32-1:0]  vB_rdata,
  output logic [31:0]      vW_addr,
  output logic             vW_we,
  output logic [N*32-1:0]  vW_wdata,
  output logic [N-1:0]     vW_wmask,
  // halt
  output logic        halt
);
  localparam logic [1:0] RD_ALU=2'd0, RD_MEM=2'd1, RD_PC4=2'd2, RD_IMM=2'd3;
  localparam bit SMUL_EN = MUL_MASK[0];               // tile (0,0) has a multiplier
  localparam int MR1     = csa_rows(XLEN/2 + 1, MUL_S1_LV);
  localparam int STW     = 8;                         // saturating GFLOW step counter

  // ======================================================================
  // Declarations (everything is declared before its first use)
  // ======================================================================
  // IF / ID
  logic [31:0] pc, id_pc, id_instr;
  logic        id_valid;
  logic        front_stall, load_use, grid_busy, mul_stall;
  // registered redirect (resolved in EX, applied the next cycle)
  logic        redirect_q;
  logic [31:0] redirect_pc_q;

  // decode
  logic [4:0]  d_rs1, d_rs2, d_rd;
  logic        d_reg_we; logic [1:0] d_rd_src; alu_op_t d_alu_op;
  logic        d_alu_a_pc, d_alu_b_imm, d_mem_read, d_mem_write;
  logic [2:0]  d_mem_funct3, d_br_funct3;
  logic        d_branch, d_jal, d_jalr, d_ecall;
  logic        d_is_gcfg, d_is_gstart, d_is_vlw, d_is_vsw;
  logic        d_is_gcfgi; logic [2:0] d_gi_row, d_gi_col;
  logic [2:0]  d_g_row, d_g_col; alu_op_t d_g_op; src_sel_t d_g_srca, d_g_srcb; logic d_g_drain;
  logic [2:0]  d_gs_vd, d_gs_vs1, d_gs_vs2; logic [4:0] d_gs_len; logic [3:0] d_gs_lanes;
  logic [2:0]  d_v_vd, d_v_vs;
  logic        d_is_gflow; logic [4:0] d_gf_dstreg, d_gf_cntreg; logic d_gf_mode;
  logic [31:0] d_imm;
  logic [31:0] rf_rdata1, rf_rdata2, rf_rdata3, rf_rdata4;
  logic        wb_we; logic [4:0] wb_rd; logic [31:0] wb_data;

  // ID/EX
  logic        ex_valid;
  logic [31:0] ex_imm, ex_br_tgt;
  logic [31:0] ex_opa, ex_opb;          // ALU operands as chosen in ID (rs / pc / imm / 0 / 4)
  logic [31:0] ex_rs1, ex_rs2;          // raw register values (branch, store, JALR, VLW/VSW, GCFGI)
  logic [2:0]  ex_fa, ex_fb;            // one-hot {reg, wb, mem} for ALU operands
  logic [2:0]  ex_f1, ex_f2;            // one-hot {reg, wb, mem} for raw rs1 / rs2
  logic        ex_scg;                  // 1 = EX bubble: tile (0,0) sees grid operands
  logic [4:0]  ex_rd;
  logic        ex_reg_we; alu_op_t ex_alu_op;
  logic        ex_mem_read, ex_mem_write;
  logic [2:0]  ex_mem_funct3, ex_br_funct3;
  logic        ex_branch, ex_jal, ex_jalr, ex_ecall;
  logic        ex_is_gcfg; logic [2:0] ex_g_row, ex_g_col; alu_op_t ex_g_op;
  src_sel_t    ex_g_srca, ex_g_srcb; logic ex_g_drain;
  logic        ex_is_gcfgi; logic [2:0] ex_gi_row, ex_gi_col;
  logic        ex_is_gstart; logic [2:0] ex_gs_vd, ex_gs_vs1, ex_gs_vs2;
  logic [4:0]  ex_gs_len; logic [3:0] ex_gs_lanes;
  logic        ex_is_vlw, ex_is_vsw; logic [2:0] ex_v_vd, ex_v_vs;
  logic        ex_is_gflow, ex_gf_mode;
  logic [31:0] ex_gf_src1, ex_gf_src2, ex_gf_dst, ex_gf_cnt;

  // EX/MEM, MEM/WB
  logic        mem_valid, mem_reg_we, mem_mem_read, mem_mem_write;
  logic [4:0]  mem_rd;
  logic [31:0] mem_alu, mem_store_data, mem_vaddr;
  logic [2:0]  mem_funct3_r;
  logic        mem_is_vlw, mem_is_vsw; logic [2:0] mem_v_vd;
  logic [N*32-1:0] mem_vstore;
  logic        wb_we_r; logic [4:0] wb_rd_r; logic [31:0] wb_data_fwd;

  // grid configuration
  logic [N*N*5-1:0]  cfg_op_f;
  logic [N*N*3-1:0]  cfg_srca_f, cfg_srcb_f;
  logic [N*N-1:0]    cfg_drain_f;
  logic [N*N*32-1:0] cfg_const_f;

  // vector register file
  logic [2:0]      vrf_raddr1, vrf_raddr2;
  logic [N*32-1:0] vrf_rd1, vrf_rd2;
  logic            vrf_we; logic [2:0] vrf_waddr;
  logic [N*32-1:0] vrf_wdata; logic [N-1:0] vrf_wmask;

  // GSTART FSM
  typedef enum logic [1:0] {G_IDLE, G_RUN, G_DRAIN} gstate_e;
  gstate_e         gstate;
  logic [5:0]      gcnt;
  logic [2:0]      g_vd_l; logic [3:0] g_lanes_l;

  // GFLOW FSM (encoding order kept: F_RUN == 1 is probed by tb/run_tb.sv)
  typedef enum logic [1:0] {F_IDLE, F_RUN, F_FIN, F_FIN2} fstate_e;
  fstate_e     fstate;
  logic [31:0] f_pa, f_pb, f_pw;
  logic [31:0] f_in_left, f_b_left, f_out_left, f_accum;
  logic [STW-1:0] f_step;
  logic [4:0]  f_len, f_ebcol; logic f_mode;
  logic        f_inj_nz, f_b_nz, f_out_nz, f_out_one, f_eb_ge, f_len_ge;  // precomputed flags
  logic [4:0]  len_hw, ebcol_hw;
  logic [N-1:0] col_drain, col_extb;
  logic        gstart_fire, gflow_fire, f_inject, f_bfetch, f_out, f_last_out;
  logic        grid_step;

  // grid datapath
  logic [N*32-1:0] inj_a_q, inj_b_q, extb_q;
  logic [N*N*5-1:0] g_op_flat;
  logic [31:0]      scalar_y;
  logic [MR1*32-1:0] scalar_rows;
  logic [N*32-1:0]  grid_drain_val;
  logic [N-1:0]     grid_drain_act;

  // accumulate path
  logic [N*32-1:0] drain_q;
  logic            drain_v;

  // scalar MUL
  logic [1:0]      mul_ph;
  logic [31:0]     smul_y;
  logic [MR1*32-1:0] smul_rows_q;
  logic            ex_live, ex_is_smul, smul_done, ex_commit;

  // ======================================================================
  // IF stage
  // ======================================================================
  assign imem_addr   = pc;
  assign front_stall = load_use || grid_busy || mul_stall;

  always_ff @(posedge clk) begin
    if (!rst_n)              pc <= 32'h0;
    else if (redirect_q)     pc <= redirect_pc_q;
    else if (!front_stall)   pc <= pc + 4;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      id_pc <= 0; id_instr <= 32'h13; id_valid <= 0;
    end else if (redirect_q) begin
      id_valid <= 0;                                   // flush
    end else if (!front_stall) begin
      id_pc <= pc; id_instr <= imem_rdata; id_valid <= 1'b1;
    end
  end

  // ======================================================================
  // ID stage : decode, register read, operand + forwarding pre-decode
  // ======================================================================
  decoder dec (
    .instr(id_instr),
    .rs1_addr(d_rs1), .rs2_addr(d_rs2), .rd_addr(d_rd),
    .reg_we(d_reg_we), .rd_src(d_rd_src), .alu_op(d_alu_op),
    .alu_a_pc(d_alu_a_pc), .alu_b_imm(d_alu_b_imm),
    .mem_read(d_mem_read), .mem_write(d_mem_write), .mem_funct3(d_mem_funct3),
    .branch(d_branch), .br_funct3(d_br_funct3), .jal(d_jal), .jalr(d_jalr),
    .is_ecall(d_ecall),
    .is_gcfg(d_is_gcfg), .g_row(d_g_row), .g_col(d_g_col), .g_op(d_g_op),
    .g_srca(d_g_srca), .g_srcb(d_g_srcb), .g_drain(d_g_drain),
    .is_gcfgi(d_is_gcfgi), .gi_row(d_gi_row), .gi_col(d_gi_col),
    .is_gstart(d_is_gstart), .gs_vd(d_gs_vd), .gs_vs1(d_gs_vs1), .gs_vs2(d_gs_vs2),
    .gs_len(d_gs_len), .gs_lanes(d_gs_lanes),
    .is_vlw(d_is_vlw), .is_vsw(d_is_vsw), .v_vd(d_v_vd), .v_vs(d_v_vs),
    .is_gflow(d_is_gflow), .gf_dstreg(d_gf_dstreg), .gf_cntreg(d_gf_cntreg),
    .gf_mode(d_gf_mode)
  );
  imm_gen igen (.instr(id_instr), .imm(d_imm));

  regfile rf (
    .clk, .rst_n,
    .we(wb_we), .waddr(wb_rd), .wdata(wb_data),
    .raddr1(d_rs1), .rdata1(rf_rdata1),
    .raddr2(d_rs2), .rdata2(rf_rdata2),
    .raddr3(d_gf_dstreg), .rdata3(rf_rdata3),    // GFLOW dst base
    .raddr4(d_gf_cntreg), .rdata4(rf_rdata4)     // GFLOW block count
  );

  // ---- load-use hazard (unchanged condition) ----
  assign load_use = id_valid && ex_valid && ex_mem_read && (ex_rd != 0) &&
                    ((ex_rd == d_rs1) || (ex_rd == d_rs2));

  // ---- ALU operands chosen here, so EX needs no pc/imm muxes and no result
  //      mux: LUI = 0 + imm, JAL/JALR link = pc + 4, AUIPC = pc + imm ----
  wire d_lui  = (d_rd_src == RD_IMM);
  wire d_link = (d_rd_src == RD_PC4);
  wire d_a_rs = !(d_alu_a_pc || d_link || d_lui);           // operand A is rs1
  wire d_b_rs = !(d_alu_b_imm || d_link || d_lui);          // operand B is rs2
  wire [31:0] d_opa = (d_alu_a_pc || d_link) ? id_pc :
                      d_lui                  ? 32'd0 : rf_rdata1;
  wire [31:0] d_opb = (d_alu_b_imm || d_lui) ? d_imm :
                      d_link                 ? 32'd4 : rf_rdata2;

  // ---- forwarding pre-decode. Next cycle, today's EX instruction is in MEM
  //      (forward mem_alu) and today's MEM instruction is in WB (forward
  //      wb_data_fwd). Valid because ID->EX only moves when EX->MEM moves
  //      too (mul_stall freezes both), and a load in EX blocks the move. ----
  wire ex_wr  = ex_valid && ex_reg_we && (ex_rd != 5'd0);
  wire mem_wr = mem_reg_we && (mem_rd != 5'd0);
  wire d1_m = ex_wr && (ex_rd == d_rs1);
  wire d1_w = !d1_m && mem_wr && (mem_rd == d_rs1);
  wire d2_m = ex_wr && (ex_rd == d_rs2);
  wire d2_w = !d2_m && mem_wr && (mem_rd == d_rs2);
  wire [2:0] d_f1 = {!(d1_m || d1_w), d1_w, d1_m};          // {reg, wb, mem}
  wire [2:0] d_f2 = {!(d2_m || d2_w), d2_w, d2_m};
  wire [2:0] d_fa = d_a_rs ? d_f1 : 3'b100;
  wire [2:0] d_fb = d_b_rs ? d_f2 : 3'b100;

  wire [31:0] d_br_tgt = id_pc + d_imm;                     // branch / JAL target

  // ======================================================================
  // ID/EX pipeline register
  //   bubble  : only the valid bit and the tile (0,0) select flops are forced
  //             (everything downstream is qualified by ex_live)
  //   hold    : scalar MUL keeps the whole register for its extra cycles
  // ======================================================================
  wire ex_bubble = load_use || redirect_q || grid_busy;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ex_valid <= 1'b0; ex_scg <= 1'b1;
      ex_fa <= 3'b000; ex_fb <= 3'b000; ex_f1 <= 3'b100; ex_f2 <= 3'b100;
    end else if (!mul_stall) begin
      ex_valid <= id_valid && !ex_bubble;
      ex_scg   <= ex_bubble || !id_valid;
      ex_fa    <= (ex_bubble || !id_valid) ? 3'b000 : d_fa;
      ex_fb    <= (ex_bubble || !id_valid) ? 3'b000 : d_fb;
      ex_f1    <= d_f1;
      ex_f2    <= d_f2;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ex_imm <= 0; ex_br_tgt <= 0; ex_opa <= 0; ex_opb <= 0;
      ex_rs1 <= 0; ex_rs2 <= 0; ex_rd <= 0;
      ex_reg_we <= 0; ex_alu_op <= ALU_ADD; ex_mem_read <= 0; ex_mem_write <= 0;
      ex_mem_funct3 <= 0; ex_br_funct3 <= 0;
      ex_branch <= 0; ex_jal <= 0; ex_jalr <= 0; ex_ecall <= 0;
      ex_is_gcfg <= 0; ex_g_row <= 0; ex_g_col <= 0; ex_g_op <= ALU_ADD;
      ex_g_srca <= SRC_WEST; ex_g_srcb <= SRC_WEST; ex_g_drain <= 0;
      ex_is_gcfgi <= 0; ex_gi_row <= 0; ex_gi_col <= 0;
      ex_is_gstart <= 0; ex_gs_vd <= 0; ex_gs_vs1 <= 0; ex_gs_vs2 <= 0;
      ex_gs_len <= 0; ex_gs_lanes <= 0;
      ex_is_vlw <= 0; ex_is_vsw <= 0; ex_v_vd <= 0; ex_v_vs <= 0;
      ex_is_gflow <= 0; ex_gf_mode <= 0;
      ex_gf_src1 <= 0; ex_gf_src2 <= 0; ex_gf_dst <= 0; ex_gf_cnt <= 0;
    end else if (!mul_stall) begin
      ex_imm     <= d_imm;    ex_br_tgt <= d_br_tgt;
      ex_opa     <= d_opa;    ex_opb <= d_opb;
      ex_rs1     <= rf_rdata1; ex_rs2 <= rf_rdata2;
      ex_rd      <= d_rd;
      ex_reg_we  <= d_reg_we; ex_alu_op <= d_alu_op;
      ex_mem_read<= d_mem_read; ex_mem_write <= d_mem_write;
      ex_mem_funct3 <= d_mem_funct3; ex_br_funct3 <= d_br_funct3;
      ex_branch  <= d_branch; ex_jal <= d_jal; ex_jalr <= d_jalr; ex_ecall <= d_ecall;
      ex_is_gcfgi <= d_is_gcfgi; ex_gi_row <= d_gi_row; ex_gi_col <= d_gi_col;
      ex_is_gcfg <= d_is_gcfg; ex_g_row <= d_g_row; ex_g_col <= d_g_col;
      ex_g_op    <= d_g_op; ex_g_srca <= d_g_srca; ex_g_srcb <= d_g_srcb;
      ex_g_drain <= d_g_drain;
      ex_is_gstart <= d_is_gstart; ex_gs_vd <= d_gs_vd; ex_gs_vs1 <= d_gs_vs1;
      ex_gs_vs2 <= d_gs_vs2; ex_gs_len <= d_gs_len; ex_gs_lanes <= d_gs_lanes;
      ex_is_vlw <= d_is_vlw; ex_is_vsw <= d_is_vsw; ex_v_vd <= d_v_vd; ex_v_vs <= d_v_vs;
      ex_is_gflow <= d_is_gflow; ex_gf_mode <= d_gf_mode;
      // GFLOW operands come straight from the regfile, as in the baseline
      ex_gf_src1 <= rf_rdata1; ex_gf_src2 <= rf_rdata2;
      ex_gf_dst  <= rf_rdata3; ex_gf_cnt  <= rf_rdata4;
    end
  end

  // ======================================================================
  // EX stage
  // ======================================================================
  // An instruction in EX is squashed when the redirect of an older taken
  // branch/jump (now in MEM) is being applied.
  assign ex_live = ex_valid && !redirect_q;

  // raw forwarded register values (one-hot AND-OR, selects are flops)
  wire [31:0] rs1v = ({32{ex_f1[0]}} & mem_alu) | ({32{ex_f1[1]}} & wb_data_fwd) |
                     ({32{ex_f1[2]}} & ex_rs1);
  wire [31:0] rs2v = ({32{ex_f2[0]}} & mem_alu) | ({32{ex_f2[1]}} & wb_data_fwd) |
                     ({32{ex_f2[2]}} & ex_rs2);

  // ---- grid configuration registers (written by GCFG / GCFGI) ----
  // width-safe at N=1, where $clog2(N*N) would be 0
  localparam int IDXW = (N*N > 1) ? $clog2(N*N) : 1;
  wire [IDXW-1:0] gcfg_idx  = IDXW'(ex_g_row*N + ex_g_col);
  wire [IDXW-1:0] gcfgi_idx = IDXW'(ex_gi_row*N + ex_gi_col);
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cfg_op_f    <= {(N*N){ALU_NOP}};
      cfg_srca_f  <= '0; cfg_srcb_f <= '0; cfg_drain_f <= '0;
      cfg_const_f <= '0;
    end else begin
      if (ex_live && ex_is_gcfg) begin
        for (int i = 0; i < N*N; i++) if (gcfg_idx == i) begin
          cfg_op_f   [i*5 +: 5] <= ex_g_op;
          cfg_srca_f [i*3 +: 3] <= ex_g_srca;
          cfg_srcb_f [i*3 +: 3] <= ex_g_srcb;
          cfg_drain_f[i]        <= ex_g_drain;
        end
      end
      if (ex_live && ex_is_gcfgi) begin
        for (int i = 0; i < N*N; i++) if (gcfgi_idx == i)
          cfg_const_f[i*32 +: 32] <= rs1v;
      end
    end
  end

  // ---- vector register file ----
  // read port 1 serves GSTART vs1 and VSW vs; read port 2 serves GSTART vs2
  assign vrf_raddr1 = ex_is_gstart ? ex_gs_vs1 : ex_v_vs;
  assign vrf_raddr2 = ex_gs_vs2;

  vregfile #(.N(N)) vrf (
    .clk, .rst_n,
    .we(vrf_we), .waddr(vrf_waddr), .wdata(vrf_wdata), .wmask(vrf_wmask),
    .raddr1(vrf_raddr1), .rdata1(vrf_rd1),
    .raddr2(vrf_raddr2), .rdata2(vrf_rd2)
  );

  // ======================================================================
  // Grid control (GSTART / GFLOW)
  // ======================================================================
  assign gstart_fire = ex_live && ex_is_gstart && (gstate == G_IDLE);
  assign gflow_fire  = ex_live && ex_is_gflow  && (fstate == F_IDLE);

  // Path latency = 1 (registered injection) + 2 per column (two-stage tiles)
  // to the deepest draining column (minimum 3), and the EXTB column in steps
  // (2 per column) of the deepest tile that selects SRC_EXTB -- the same
  // values as src_opt, computed as a per-column OR over the rows followed by
  // an N-input priority scan (not a running max chained over all N*N tiles).
  always_comb begin
    col_drain = '0;
    col_extb  = '0;
    for (int k = 0; k < N*N; k++) begin
      if (cfg_drain_f[k]) col_drain[k % N] = 1'b1;
      if (src_sel_t'(cfg_srca_f[k*3 +: 3]) == SRC_EXTB ||
          src_sel_t'(cfg_srcb_f[k*3 +: 3]) == SRC_EXTB) col_extb[k % N] = 1'b1;
    end
    len_hw   = 5'd3;
    ebcol_hw = 5'd0;
    for (int cc = 0; cc < N; cc++) begin           // ascending: deepest wins
      if (col_drain[cc]) len_hw   = 5'(1 + 2*(cc + 1));
      if (col_extb[cc])  ebcol_hw = 5'(2*cc);
    end
  end

  // All decisions are flop outputs ANDed with the state decode.
  assign f_inject   = (fstate == F_RUN) && f_inj_nz;
  assign f_bfetch   = (fstate == F_RUN) && f_eb_ge && f_b_nz;
  assign f_out      = (fstate == F_RUN) && f_len_ge && f_out_nz;
  assign f_last_out = f_out && f_out_one;

  assign grid_busy = (gstate != G_IDLE) || gstart_fire ||
                     (fstate != F_IDLE) || gflow_fire;
  assign grid_step = (gstate == G_RUN) || (fstate == F_RUN);

  wire [STW-1:0] f_step_n = (&f_step) ? f_step : f_step + 1'b1;   // saturating

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fstate <= F_IDLE; f_pa <= 0; f_pb <= 0; f_pw <= 0;
      f_in_left <= 0; f_b_left <= 0; f_out_left <= 0; f_step <= 0;
      f_len <= 0; f_ebcol <= 0; f_mode <= 0;
      f_inj_nz <= 0; f_b_nz <= 0; f_out_nz <= 0; f_out_one <= 0;
      f_eb_ge <= 0; f_len_ge <= 0;
    end else begin
      unique case (fstate)
        F_IDLE: if (gflow_fire) begin
          f_pa <= ex_gf_src1; f_pb <= ex_gf_src2; f_pw <= ex_gf_dst;
          f_in_left <= ex_gf_cnt; f_b_left <= ex_gf_cnt; f_out_left <= ex_gf_cnt;
          f_step <= '0; f_len <= len_hw; f_ebcol <= ebcol_hw;
          f_mode <= ex_gf_mode;
          f_inj_nz  <= (ex_gf_cnt != 0);
          f_b_nz    <= (ex_gf_cnt != 0);
          f_out_nz  <= (ex_gf_cnt != 0);
          f_out_one <= (ex_gf_cnt == 1);
          f_eb_ge   <= (ebcol_hw == 5'd0);           // step 0 >= ebcol
          f_len_ge  <= 1'b0;                         // len_hw >= 3
          fstate    <= F_RUN;
        end
        F_RUN: begin
          f_step   <= f_step_n;
          f_eb_ge  <= (f_step_n >= STW'(f_ebcol));
          f_len_ge <= (f_step_n >= STW'(f_len));
          if (f_inject) begin
            f_pa <= f_pa + 4*N; f_in_left <= f_in_left - 1;
            f_inj_nz <= (f_in_left != 1);
          end
          if (f_bfetch) begin
            f_pb <= f_pb + 4*N; f_b_left <= f_b_left - 1;
            f_b_nz <= (f_b_left != 1);
          end
          if (f_out) begin
            f_out_left <= f_out_left - 1;
            f_out_nz   <= (f_out_left != 1);
            f_out_one  <= (f_out_left == 2);
            if (!f_mode) f_pw <= f_pw + 4*N;           // stream: advance dst
          end
          if (f_last_out) fstate <= f_mode ? F_FIN : F_IDLE;
        end
        // F_FIN: the last partial is added into f_accum; F_FIN2 writes it back.
        F_FIN:  fstate <= F_FIN2;
        F_FIN2: fstate <= F_IDLE;
        default: fstate <= F_IDLE;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      gstate <= G_IDLE; gcnt <= 0; g_vd_l <= 0; g_lanes_l <= 0;
    end else begin
      unique case (gstate)
        G_IDLE: if (gstart_fire) begin
          g_vd_l <= ex_gs_vd; g_lanes_l <= ex_gs_lanes;
          gcnt <= {ex_gs_len, 1'b0};                  // two steps per tile hop
          gstate <= G_RUN;
        end
        G_RUN:   if (gcnt > 1) gcnt <= gcnt - 1; else gstate <= G_DRAIN;
        G_DRAIN: gstate <= G_IDLE;
        default: gstate <= G_IDLE;
      endcase
    end
  end

  // ---- registered column-0 / EXTB injection ----
  // One register per feed serves every mode: GSTART loads the vector
  // operands once and holds them; GFLOW reloads every cycle (0 once inputs
  // run out); a scalar MUL loads its forwarded operands into row 0 and holds
  // them for tile (0,0)'s multiplier. The tiles therefore see flop -> operand
  // mux, never FSM decode or forwarding logic.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      inj_a_q <= '0; inj_b_q <= '0; extb_q <= '0;
    end else begin
      extb_q <= f_bfetch ? vB_rdata : '0;
      if (gstart_fire) begin
        inj_a_q <= vrf_rd1; inj_b_q <= vrf_rd2;
      end else if (ex_is_smul && mul_ph == 2'd0) begin
        inj_a_q <= '0; inj_b_q <= '0;
        inj_a_q[0 +: 32] <= rs1v; inj_b_q[0 +: 32] <= rs2v;
      end else if (gstate == G_IDLE && !(ex_is_smul && mul_ph == 2'd1)) begin
        inj_a_q <= f_inject ? vA_rdata : '0;
        // column-0 West-B feed only when no tile takes stream B via EXTB
        inj_b_q <= (f_bfetch && f_ebcol == 5'd0) ? vB_rdata : '0;
      end
    end
  end

  // ======================================================================
  // ALU grid. Whenever EX holds an instruction, tile (0,0) follows it: op =
  // the scalar op, grid operand sources = West (the multiplier reads the
  // row-0 injection registers); the ALU operand choice is made inside the
  // tile (ex_scg / ex_fa). All of these selects are flop outputs.
  // ======================================================================
  logic [N*N*3-1:0] g_srca_flat, g_srcb_flat;
  always_comb begin
    g_op_flat   = cfg_op_f;
    g_srca_flat = cfg_srca_f;
    g_srcb_flat = cfg_srcb_f;
    if (!ex_scg) begin
      g_op_flat  [0 +: 5] = ex_alu_op;
      g_srca_flat[0 +: 3] = SRC_WEST;
      g_srcb_flat[0 +: 3] = SRC_WEST;
    end
  end

  alu_grid #(.N(N)) grid (
    .clk, .rst_n, .step(grid_step),
    .op_flat(g_op_flat), .srca_flat(g_srca_flat), .srcb_flat(g_srcb_flat),
    .drain_flat(cfg_drain_f), .const_flat(cfg_const_f),
    .inj_a_flat(inj_a_q), .inj_b_flat(inj_b_q), .extb_flat(extb_q),
    .sc_grid(ex_scg), .sc_asel(ex_fa), .sc_bsel(ex_fb),
    .sc_mem(mem_alu), .sc_wb(wb_data_fwd), .sc_ra(ex_opa), .sc_rb(ex_opb),
    .scalar_y(scalar_y), .scalar_rows(scalar_rows),
    .drain_val_flat(grid_drain_val), .drain_act(grid_drain_act)
  );

  // ---- GFLOW accumulate: register the drained lanes, then fold them into a
  //      carry-save accumulator {acc_s, acc_c}: per block only 3:2 levels
  //      (N=4: 6 rows -> 3 levels; N=8: 10 rows -> 5 levels), no CPA. The
  //      value f_accum = acc_s + acc_c is only needed at write-back (F_FIN2).
  generate
    if (RED_TREE) begin : g_red
      logic [31:0]  acc_s, acc_c;
      logic [63:0]  acc_n;
      always_ff @(posedge clk) begin
        if (!rst_n) drain_q <= '0;
        else if (f_out)
          drain_q <= grid_drain_val;   // inactive rows already drain 0 (alu_grid)
      end
      csa_tree #(.W(32), .NIN(N+2), .LV(csa_levels(N+2)), .NOUT(2))
        u_acc (.in_rows({drain_q, acc_c, acc_s}), .out_rows(acc_n));
      always_ff @(posedge clk) begin
        if (!rst_n || gflow_fire) begin acc_s <= '0; acc_c <= '0; end
        else if (drain_v)         begin acc_s <= acc_n[31:0]; acc_c <= acc_n[63:32]; end
      end
      assign f_accum = acc_s + acc_c;
    end else begin : g_nored
      // ablation: no N-input adder, just the lowest drained lane
      logic [31:0] lane_sel;
      always_comb begin
        lane_sel = '0;
        for (int l = N-1; l >= 0; l--)
          if (grid_drain_act[l]) lane_sel = grid_drain_val[l*32 +: 32];
      end
      always_ff @(posedge clk) begin
        if (!rst_n) drain_q <= '0;
        else if (f_out) begin
          drain_q <= '0;
          drain_q[0 +: 32] <= lane_sel;
        end
      end
      always_ff @(posedge clk) begin
        if (!rst_n)          f_accum <= '0;
        else if (gflow_fire) f_accum <= '0;
        else if (drain_v)    f_accum <= f_accum + drain_q[0 +: 32];
      end
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (!rst_n) drain_v <= 1'b0;
    else        drain_v <= f_out && f_mode;
  end

  // ======================================================================
  // Scalar MUL on tile (0,0)'s multiplier, three cycles in EX:
  //   ph 0 : forwarded operands -> row-0 injection registers       (stall)
  //   ph 1 : tile (0,0) Booth + 4 CSA levels -> smul_rows_q        (stall)
  //   ph 2 : 2 CSA levels + CPA -> EX/MEM                          (commit)
  // MUL_MASK[0] = 0 removes tile (0,0)'s multiplier: no stall, MUL returns 0,
  // exactly like the baseline.
  // ======================================================================
  assign ex_is_smul = SMUL_EN && ex_live && ex_reg_we && (ex_alu_op == ALU_MUL);
  assign mul_stall  = ex_is_smul && (mul_ph != 2'd2);
  assign smul_done  = ex_is_smul && (mul_ph == 2'd2);

  always_ff @(posedge clk) begin
    if (!rst_n)          mul_ph <= 2'd0;
    else if (ex_is_smul) mul_ph <= (mul_ph == 2'd2) ? 2'd0 : mul_ph + 2'd1;
    else                 mul_ph <= 2'd0;
  end

  generate
    if (SMUL_EN) begin : g_smul
      always_ff @(posedge clk)
        if (ex_is_smul && mul_ph == 2'd1) smul_rows_q <= scalar_rows;
      csa_sum #(.W(32), .NIN(MR1)) u_smul (.rows(smul_rows_q), .y(smul_y));
    end else begin : g_no_smul
      assign smul_rows_q = '0; assign smul_y = '0;
    end
  endgenerate

  // tile (0,0)'s ALU returns 0 for ALU_MUL, so the product is simply ORed in
  wire [31:0] ex_alu_result = scalar_y | ({32{smul_done}} & smul_y);

  // ---- branch / jump resolution (registered redirect) ----
  logic br_take;
  always_comb begin
    unique case (ex_br_funct3)
      3'b000: br_take = (rs1v == rs2v);
      3'b001: br_take = (rs1v != rs2v);
      3'b100: br_take = ($signed(rs1v) <  $signed(rs2v));
      3'b101: br_take = ($signed(rs1v) >= $signed(rs2v));
      3'b110: br_take = (rs1v <  rs2v);
      3'b111: br_take = (rs1v >= rs2v);
      default:br_take = 1'b0;
    endcase
  end
  wire ex_take = ex_live && ((ex_branch && br_take) || ex_jal || ex_jalr);
  wire [31:0] ex_tgt = ex_jalr ? ((rs1v + ex_imm) & ~32'd1) : ex_br_tgt;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      redirect_q <= 1'b0; redirect_pc_q <= 32'h0;
    end else begin
      redirect_q    <= ex_take;
      redirect_pc_q <= ex_tgt;
    end
  end

  // ======================================================================
  // EX/MEM pipeline register
  // ======================================================================
  assign ex_commit = ex_live && !mul_stall;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mem_valid<=0; mem_reg_we<=0; mem_rd<=0;
      mem_mem_read<=0; mem_mem_write<=0; mem_funct3_r<=0; mem_store_data<=0;
      mem_is_vlw<=0; mem_is_vsw<=0; mem_v_vd<=0; mem_vaddr<=0; mem_vstore<=0;
    end else begin
      mem_valid     <= ex_commit;
      mem_reg_we    <= ex_commit && ex_reg_we;
      mem_rd        <= ex_rd;
      mem_mem_read  <= ex_commit && ex_mem_read;
      mem_mem_write <= ex_commit && ex_mem_write;
      mem_funct3_r  <= ex_mem_funct3;
      mem_store_data<= rs2v;
      mem_is_vlw    <= ex_commit && ex_is_vlw;
      mem_is_vsw    <= ex_commit && ex_is_vsw;
      mem_v_vd      <= ex_v_vd;
      mem_vaddr     <= rs1v + ex_imm;
      mem_vstore    <= vrf_rd1;       // VSW store data (vs read via port 1)
    end
  end
  // the scalar result flop is the end of the EX critical path: no reset gate
  // (nothing reads it before a valid instruction has written it)
  always_ff @(posedge clk) mem_alu <= ex_alu_result;

  // ======================================================================
  // MEM stage : scalar mem + vector mem
  // ======================================================================
  assign dmem_addr   = mem_alu;
  assign dmem_we     = mem_mem_write;
  assign dmem_re     = mem_mem_read;
  assign dmem_funct3 = mem_funct3_r;
  assign dmem_wdata  = mem_store_data;

  // vector read ports: GFLOW streams during F_RUN, otherwise VLW on port A
  assign vA_addr = (fstate == F_RUN) ? f_pa : mem_vaddr;
  assign vB_addr = (fstate == F_RUN) ? f_pb : 32'b0;

  // vector write port: GFLOW stream/accumulate output, else VSW
  always_comb begin
    if (fstate == F_RUN && f_out && !f_mode) begin     // stream out N words
      vW_we = 1'b1; vW_addr = f_pw; vW_wdata = grid_drain_val; vW_wmask = grid_drain_act;
    end else if (fstate == F_FIN2) begin               // accumulate -> 1 scalar
      vW_we = 1'b1; vW_addr = f_pw; vW_wdata = '0; vW_wdata[0 +: 32] = f_accum;
      vW_wmask = {{(N-1){1'b0}}, 1'b1};
    end else begin                                      // VSW
      vW_we = mem_is_vsw; vW_addr = mem_vaddr; vW_wdata = mem_vstore; vW_wmask = {N{1'b1}};
    end
  end

  // ---- vector register write port: grid drain (priority) or VLW ----
  always_comb begin
    if (gstate == G_DRAIN) begin
      vrf_we    = 1'b1;
      vrf_waddr = g_vd_l;
      vrf_wdata = grid_drain_val;
      vrf_wmask = grid_drain_act & g_lanes_l;
    end else if (mem_is_vlw) begin
      vrf_we    = 1'b1;
      vrf_waddr = mem_v_vd;
      vrf_wdata = vA_rdata;
      vrf_wmask = {N{1'b1}};
    end else begin
      vrf_we = 1'b0; vrf_waddr = 0; vrf_wdata = 0; vrf_wmask = 0;
    end
  end

  // ======================================================================
  // MEM/WB pipeline register + writeback
  // ======================================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wb_we_r <= 0; wb_rd_r <= 0; wb_data_fwd <= 0;
    end else begin
      wb_we_r     <= mem_reg_we;
      wb_rd_r     <= mem_rd;
      wb_data_fwd <= mem_mem_read ? dmem_rdata : mem_alu;
    end
  end
  assign wb_we   = wb_we_r;
  assign wb_rd   = wb_rd_r;
  assign wb_data = wb_data_fwd;

  // ======================================================================
  // Halt on ECALL, when it reaches EX on the correct path. Grid operations
  // are always finished by then (they hold the ECALL in ID while busy).
  // ======================================================================
  always_ff @(posedge clk) begin
    if (!rst_n)                   halt <= 1'b0;
    else if (ex_live && ex_ecall) halt <= 1'b1;
  end
endmodule
