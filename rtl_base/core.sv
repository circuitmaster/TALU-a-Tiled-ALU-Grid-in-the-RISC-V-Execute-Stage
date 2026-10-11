// core.sv
// TALU 5-stage pipelined RV32I core with an N x N ALU grid execute fabric.
//
//  - Scalar RV32I flows through grid tile(0,0)'s combinational tap.
//    Forwarding + load-use stalls exist only on this scalar path.
//    Branches/jumps resolve in EX and flush the two younger instructions.
//  - GCFG  : writes the per-tile grid configuration registers (committed in EX).
//  - GSTART: multi-cycle. A small FSM stalls the front-end, injects the operand
//    vectors (vs1/vs2) into the grid's column-0 West feeds, steps the systolic
//    array `len` cycles, then drains the perimeter tiles into vector reg vd.
//    (Grid mode assumes no inter-instruction data hazards.)
//  - VLW/VSW: wide N-word vector load/store via the data-memory vector port.
`include "talu_pkg.sv"

module core
  import talu_pkg::*;
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

  // ======================================================================
  // IF stage
  // ======================================================================
  logic [31:0] pc;
  logic        stall, redirect, grid_busy;
  logic [31:0] redirect_pc;

  assign imem_addr = pc;

  // front-end is frozen by a load-use stall or while the grid FSM is busy
  wire front_stall = stall || grid_busy;

  always_ff @(posedge clk) begin
    if (!rst_n)              pc <= 32'h0;
    else if (redirect)       pc <= redirect_pc;
    else if (!front_stall)   pc <= pc + 4;
  end

  // IF/ID register
  logic [31:0] id_pc, id_instr;
  logic        id_valid;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      id_pc <= 0; id_instr <= 32'h13; id_valid <= 0;
    end else if (redirect) begin
      id_pc <= 0; id_instr <= 32'h13; id_valid <= 0;   // flush
    end else if (!front_stall) begin
      id_pc <= pc; id_instr <= imem_rdata; id_valid <= 1'b1;
    end
  end

  // ======================================================================
  // ID stage : decode + register read
  // ======================================================================
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

  logic [31:0] rf_rdata1, rf_rdata2, rf_rdata3, rf_rdata4;
  logic        wb_we; logic [4:0] wb_rd; logic [31:0] wb_data;
  regfile rf (
    .clk, .rst_n,
    .we(wb_we), .waddr(wb_rd), .wdata(wb_data),
    .raddr1(d_rs1), .rdata1(rf_rdata1),
    .raddr2(d_rs2), .rdata2(rf_rdata2),
    .raddr3(d_gf_dstreg), .rdata3(rf_rdata3),    // GFLOW dst base
    .raddr4(d_gf_cntreg), .rdata4(rf_rdata4)     // GFLOW block count
  );

  // ---- load-use hazard ----
  logic ex_mem_read; logic [4:0] ex_rd;
  logic load_use;
  assign load_use = id_valid && ex_mem_read && (ex_rd != 0) &&
                    ((ex_rd == d_rs1) || (ex_rd == d_rs2));
  assign stall = load_use;

  // ======================================================================
  // ID/EX pipeline register
  // ======================================================================
  logic [31:0] ex_pc, ex_imm, ex_a, ex_b;
  logic [4:0]  ex_rs1, ex_rs2;
  logic        ex_reg_we; logic [1:0] ex_rd_src; alu_op_t ex_alu_op;
  logic        ex_alu_a_pc, ex_alu_b_imm, ex_mem_write;
  logic [2:0]  ex_mem_funct3, ex_br_funct3;
  logic        ex_branch, ex_jal, ex_jalr;
  logic        ex_valid;
  logic        ex_is_gcfg; logic [2:0] ex_g_row, ex_g_col; alu_op_t ex_g_op;
  src_sel_t    ex_g_srca, ex_g_srcb; logic ex_g_drain;
  logic        ex_is_gcfgi; logic [2:0] ex_gi_row, ex_gi_col;
  logic        ex_is_gstart; logic [2:0] ex_gs_vd, ex_gs_vs1, ex_gs_vs2;
  logic [4:0]  ex_gs_len; logic [3:0] ex_gs_lanes;
  logic        ex_is_vlw, ex_is_vsw; logic [2:0] ex_v_vd, ex_v_vs;
  // GFLOW (streaming): operand values latched from the regfile read ports
  logic        ex_is_gflow, ex_gf_mode;
  logic [31:0] ex_gf_src1, ex_gf_src2, ex_gf_dst, ex_gf_cnt;

  // EX is bubbled on a load-use stall or a flush, but NOT held during grid_busy
  // (the GSTART that started the FSM advances out as a harmless bubble).
  wire ex_bubble = stall || redirect || grid_busy;

  always_ff @(posedge clk) begin
    if (!rst_n || ex_bubble) begin
      ex_valid <= 0; ex_reg_we <= 0; ex_mem_read <= 0; ex_mem_write <= 0;
      ex_branch <= 0; ex_jal <= 0; ex_jalr <= 0; ex_rd <= 0;
      ex_is_gcfg <= 0; ex_is_gstart <= 0; ex_is_vlw <= 0; ex_is_vsw <= 0;
      ex_is_gcfgi <= 0; ex_gi_row <= 0; ex_gi_col <= 0;
      ex_alu_op <= ALU_ADD; ex_rd_src <= RD_ALU;
      ex_pc <= 0; ex_imm <= 0; ex_a <= 0; ex_b <= 0; ex_rs1 <= 0; ex_rs2 <= 0;
      ex_alu_a_pc <= 0; ex_alu_b_imm <= 0; ex_mem_funct3 <= 0; ex_br_funct3 <= 0;
      ex_g_row <= 0; ex_g_col <= 0; ex_g_op <= ALU_ADD; ex_g_srca <= SRC_WEST;
      ex_g_srcb <= SRC_WEST; ex_g_drain <= 0;
      ex_gs_vd <= 0; ex_gs_vs1 <= 0; ex_gs_vs2 <= 0; ex_gs_len <= 0; ex_gs_lanes <= 0;
      ex_v_vd <= 0; ex_v_vs <= 0;
      ex_is_gflow <= 0; ex_gf_mode <= 0;
      ex_gf_src1 <= 0; ex_gf_src2 <= 0; ex_gf_dst <= 0; ex_gf_cnt <= 0;
    end else begin
      ex_valid   <= id_valid;
      ex_pc      <= id_pc;    ex_imm <= d_imm;
      ex_a       <= rf_rdata1; ex_b <= rf_rdata2;
      ex_rs1     <= d_rs1; ex_rs2 <= d_rs2; ex_rd <= d_rd;
      ex_reg_we  <= d_reg_we; ex_rd_src <= d_rd_src; ex_alu_op <= d_alu_op;
      ex_alu_a_pc<= d_alu_a_pc; ex_alu_b_imm <= d_alu_b_imm;
      ex_mem_read<= d_mem_read; ex_mem_write <= d_mem_write;
      ex_mem_funct3 <= d_mem_funct3; ex_br_funct3 <= d_br_funct3;
      ex_branch  <= d_branch; ex_jal <= d_jal; ex_jalr <= d_jalr;
      ex_is_gcfgi <= d_is_gcfgi; ex_gi_row <= d_gi_row; ex_gi_col <= d_gi_col;
      ex_is_gcfg <= d_is_gcfg; ex_g_row <= d_g_row; ex_g_col <= d_g_col;
      ex_g_op    <= d_g_op; ex_g_srca <= d_g_srca; ex_g_srcb <= d_g_srcb;
      ex_g_drain <= d_g_drain;
      ex_is_gstart <= d_is_gstart; ex_gs_vd <= d_gs_vd; ex_gs_vs1 <= d_gs_vs1;
      ex_gs_vs2 <= d_gs_vs2; ex_gs_len <= d_gs_len; ex_gs_lanes <= d_gs_lanes;
      ex_is_vlw <= d_is_vlw; ex_is_vsw <= d_is_vsw; ex_v_vd <= d_v_vd; ex_v_vs <= d_v_vs;
      ex_is_gflow <= d_is_gflow; ex_gf_mode <= d_gf_mode;
      ex_gf_src1 <= rf_rdata1; ex_gf_src2 <= rf_rdata2;
      ex_gf_dst  <= rf_rdata3; ex_gf_cnt  <= rf_rdata4;
    end
  end

  // ======================================================================
  // EX stage : forwarding, scalar ALU (tile 0,0), branch resolution
  // ======================================================================
  logic [31:0] mem_wb_data;
  logic [4:0]  mem_rd, wb_rd_r;
  logic        mem_reg_we, wb_we_r; logic [31:0] wb_data_fwd;

  logic [31:0] fwd_a, fwd_b;
  always_comb begin
    fwd_a = ex_a;
    if (mem_reg_we && mem_rd != 0 && mem_rd == ex_rs1)      fwd_a = mem_wb_data;
    else if (wb_we_r && wb_rd_r != 0 && wb_rd_r == ex_rs1)  fwd_a = wb_data_fwd;
    fwd_b = ex_b;
    if (mem_reg_we && mem_rd != 0 && mem_rd == ex_rs2)      fwd_b = mem_wb_data;
    else if (wb_we_r && wb_rd_r != 0 && wb_rd_r == ex_rs2)  fwd_b = wb_data_fwd;
  end

  logic [31:0] alu_in_a, alu_in_b;
  assign alu_in_a = ex_alu_a_pc  ? ex_pc  : fwd_a;
  assign alu_in_b = ex_alu_b_imm ? ex_imm : fwd_b;

  // ---- grid configuration registers (written by GCFG) ----
  // Per-tile config held as flat packed registers (explicit flops, not a memory)
  // so they synthesise cleanly. Layout matches the grid's flattened buses.
  logic [N*N*5-1:0]  cfg_op_f;
  logic [N*N*3-1:0]  cfg_srca_f, cfg_srcb_f;
  logic [N*N-1:0]    cfg_drain_f;
  logic [N*N*32-1:0] cfg_const_f;    // per-tile constants (GCFGI)
  // width-safe at N=1, where $clog2(N*N) would be 0
  localparam int IDXW = (N*N > 1) ? $clog2(N*N) : 1;
  wire [IDXW-1:0] gcfg_idx  = IDXW'(ex_g_row*N + ex_g_col);
  wire [IDXW-1:0] gcfgi_idx = IDXW'(ex_gi_row*N + ex_gi_col);
  // synchronous reset (clock runs during reset in all testbenches)
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cfg_op_f    <= {(N*N){ALU_NOP}};
      cfg_srca_f  <= '0; cfg_srcb_f <= '0; cfg_drain_f <= '0;
      cfg_const_f <= '0;
    end else begin
      if (ex_valid && ex_is_gcfg) begin
        // one-hot decoded write (constant part-selects -> clean synthesis)
        for (int i = 0; i < N*N; i++) if (gcfg_idx == i) begin
          cfg_op_f   [i*5 +: 5] <= ex_g_op;
          cfg_srca_f [i*3 +: 3] <= ex_g_srca;
          cfg_srcb_f [i*3 +: 3] <= ex_g_srcb;
          cfg_drain_f[i]        <= ex_g_drain;
        end
      end
      if (ex_valid && ex_is_gcfgi) begin
        // tile constant := rs1 value (forwarded like any EX operand)
        for (int i = 0; i < N*N; i++) if (gcfgi_idx == i)
          cfg_const_f[i*32 +: 32] <= fwd_a;
      end
    end
  end

  // ======================================================================
  // Vector register file
  // ======================================================================
  logic [2:0]      vrf_raddr1, vrf_raddr2;
  logic [N*32-1:0] vrf_rd1, vrf_rd2;
  logic            vrf_we; logic [2:0] vrf_waddr;
  logic [N*32-1:0] vrf_wdata; logic [N-1:0] vrf_wmask;

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
  // GSTART FSM
  // ======================================================================
  typedef enum logic [1:0] {G_IDLE, G_RUN, G_DRAIN} gstate_e;
  gstate_e         gstate;
  logic [4:0]      gcnt;
  logic [2:0]      g_vd_l; logic [3:0] g_lanes_l;
  logic [N*32-1:0] g_a_l, g_b_l;

  wire gstart_fire = ex_valid && ex_is_gstart && (gstate == G_IDLE);

  // ======================================================================
  // GFLOW streaming FSM : pipelines blocks of N elements through the grid,
  // reading two source streams and writing one destination stream (or, in
  // accumulate mode, summing the drained results into a single scalar).
  // ======================================================================
  typedef enum logic [1:0] {F_IDLE, F_RUN, F_FIN} fstate_e;
  fstate_e     fstate;
  logic [31:0] f_pa, f_pb, f_pw;      // byte-address stream pointers
  logic [31:0] f_blocks, f_in_left, f_b_left, f_out_done, f_step, f_accum;
  logic [3:0]  f_len, f_ebcol; logic f_mode;

  // path latency = (deepest draining column) + 1, derived from the grid config
  logic [3:0] len_hw;
  always_comb begin
    len_hw = 4'd1;
    // single flat loop (k = rr*N + cc); column = k % N
    for (int k = 0; k < N*N; k++)
      if (cfg_drain_f[k] && (((k % N) + 1) > len_hw)) len_hw = 4'((k % N) + 1);
  end

  // EXTB injection column, derived from the grid config: the (deepest) column
  // of any tile whose operand A or B selects SRC_EXTB. 0 = column 0 (i.e. the
  // plain West-B feed timing; stream B is then fetched in lockstep with A).
  logic [3:0] ebcol_hw;
  always_comb begin
    ebcol_hw = 4'd0;
    for (int k = 0; k < N*N; k++)
      if ((src_sel_t'(cfg_srca_f[k*3 +: 3]) == SRC_EXTB ||
           src_sel_t'(cfg_srcb_f[k*3 +: 3]) == SRC_EXTB) &&
          (4'(k % N) > ebcol_hw)) ebcol_hw = 4'(k % N);
  end

  wire gflow_fire = ex_valid && ex_is_gflow && (fstate == F_IDLE);
  wire f_inject   = (fstate == F_RUN) && (f_in_left != 0);
  // stream-B fetch: delayed by the EXTB column so block i of stream B arrives
  // at the EXTB tile in the same cycle as block i of stream A (in-flight)
  wire f_bfetch   = (fstate == F_RUN) && (f_step >= {28'b0, f_ebcol}) && (f_b_left != 0);
  wire f_out      = (fstate == F_RUN) && (f_step >= {28'b0,f_len}) && (f_out_done < f_blocks);
  wire f_last_out = f_out && (f_out_done == f_blocks - 1);

  assign grid_busy = (gstate != G_IDLE) || gstart_fire ||
                     (fstate != F_IDLE) || gflow_fire;
  wire grid_step   = (gstate == G_RUN) || (fstate == F_RUN);

  // sum of the active drained lanes (used by accumulate mode)
  logic [31:0] f_drain_sum;
  always_comb begin
    f_drain_sum = '0;
    if (RED_TREE) begin
      for (int l = 0; l < N; l++)
        if (grid_drain_act[l]) f_drain_sum += grid_drain_val[l*32 +: 32];
    end else begin
      // ablation: no N-input adder, just a mux onto the lowest drained lane
      for (int l = N-1; l >= 0; l--)
        if (grid_drain_act[l]) f_drain_sum = grid_drain_val[l*32 +: 32];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fstate <= F_IDLE; f_pa<=0; f_pb<=0; f_pw<=0; f_blocks<=0;
      f_in_left<=0; f_b_left<=0; f_out_done<=0; f_step<=0; f_accum<=0;
      f_len<=0; f_ebcol<=0; f_mode<=0;
    end else begin
      unique case (fstate)
        F_IDLE: if (gflow_fire) begin
          f_pa<=ex_gf_src1; f_pb<=ex_gf_src2; f_pw<=ex_gf_dst;
          f_blocks<=ex_gf_cnt; f_in_left<=ex_gf_cnt; f_b_left<=ex_gf_cnt;
          f_out_done<=0;
          f_step<=0; f_accum<=0; f_len<=len_hw; f_ebcol<=ebcol_hw;
          f_mode<=ex_gf_mode;
          fstate<=F_RUN;
        end
        F_RUN: begin
          f_step <= f_step + 1;
          if (f_inject) begin
            f_pa <= f_pa + 4*N; f_in_left <= f_in_left - 1;
          end
          if (f_bfetch) begin
            f_pb <= f_pb + 4*N; f_b_left <= f_b_left - 1;
          end
          if (f_out) begin
            f_out_done <= f_out_done + 1;
            if (!f_mode) f_pw   <= f_pw + 4*N;          // stream: advance dst
            else         f_accum<= f_accum + f_drain_sum; // accumulate
          end
          if (f_last_out) fstate <= f_mode ? F_FIN : F_IDLE;
        end
        F_FIN:  fstate <= F_IDLE;   // accumulate result written this cycle
        default:fstate <= F_IDLE;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      gstate <= G_IDLE; gcnt <= 0; g_vd_l <= 0; g_lanes_l <= 0; g_a_l <= 0; g_b_l <= 0;
    end else begin
      unique case (gstate)
        G_IDLE: if (gstart_fire) begin
          g_a_l <= vrf_rd1; g_b_l <= vrf_rd2;
          g_vd_l <= ex_gs_vd; g_lanes_l <= ex_gs_lanes;
          gcnt <= ex_gs_len; gstate <= G_RUN;
        end
        G_RUN:  if (gcnt > 1) gcnt <= gcnt - 1; else gstate <= G_DRAIN;
        G_DRAIN: gstate <= G_IDLE;
        default: gstate <= G_IDLE;
      endcase
    end
  end

  // ======================================================================
  // ALU grid : scalar tap (tile 0,0) in scalar mode; systolic in grid mode
  // ======================================================================
  logic [N*N*5-1:0] g_op_flat;
  logic [N*N*3-1:0] g_srca_flat, g_srcb_flat;
  logic [N*N-1:0]   g_drain_flat;
  logic [N*32-1:0]  g_inj_a, g_inj_b, g_extb;
  always_comb begin
    g_op_flat    = cfg_op_f;
    g_srca_flat  = cfg_srca_f;
    g_srcb_flat  = cfg_srcb_f;
    g_drain_flat = cfg_drain_f;
    // EXTB bus: stream B, fetched on its own (column-delayed) schedule
    g_extb = (fstate == F_RUN && f_bfetch) ? vB_rdata : '0;
    if (fstate == F_RUN) begin
      // streaming mode: inject the two source streams (0 once inputs exhausted)
      g_inj_a = f_inject ? vA_rdata : '0;
      // column-0 West-B feed only when no tile takes stream B via EXTB
      g_inj_b = (f_bfetch && f_ebcol == 0) ? vB_rdata : '0;
    end else if (grid_busy) begin
      // GSTART systolic mode: operands injected from latched vregs
      g_inj_a = g_a_l; g_inj_b = g_b_l;
    end else begin
      // scalar mode: override tile(0,0) to the decoded scalar op
      g_op_flat  [0 +: 5] = ex_alu_op;
      g_srca_flat[0 +: 3] = SRC_WEST;
      g_srcb_flat[0 +: 3] = SRC_WEST;
      g_inj_a = '0; g_inj_b = '0;
      g_inj_a[0 +: 32] = alu_in_a;
      g_inj_b[0 +: 32] = alu_in_b;
    end
  end

  logic [31:0]     scalar_y;
  logic [N*32-1:0] grid_drain_val; logic [N-1:0] grid_drain_act;
  alu_grid #(.N(N)) grid (
    .clk, .rst_n, .step(grid_step),
    .op_flat(g_op_flat), .srca_flat(g_srca_flat), .srcb_flat(g_srcb_flat),
    .drain_flat(g_drain_flat), .const_flat(cfg_const_f),
    .inj_a_flat(g_inj_a), .inj_b_flat(g_inj_b), .extb_flat(g_extb),
    .scalar_y(scalar_y),
    .drain_val_flat(grid_drain_val), .drain_act(grid_drain_act)
  );

  wire [31:0] ex_alu_result = scalar_y;

  // vector memory address (rs1 + imm) for VLW/VSW
  wire [31:0] ex_vmem_addr = fwd_a + ex_imm;

  // ---- branch / jump resolution ----
  logic br_take;
  always_comb begin
    unique case (ex_br_funct3)
      3'b000: br_take = (fwd_a == fwd_b);
      3'b001: br_take = (fwd_a != fwd_b);
      3'b100: br_take = ($signed(fwd_a) <  $signed(fwd_b));
      3'b101: br_take = ($signed(fwd_a) >= $signed(fwd_b));
      3'b110: br_take = (fwd_a <  fwd_b);
      3'b111: br_take = (fwd_a >= fwd_b);
      default:br_take = 1'b0;
    endcase
  end
  wire take_branch = ex_valid && ex_branch && br_take;
  wire take_jal    = ex_valid && ex_jal;
  wire take_jalr   = ex_valid && ex_jalr;
  assign redirect    = take_branch || take_jal || take_jalr;
  assign redirect_pc = take_jalr ? ((fwd_a + ex_imm) & ~32'd1) : (ex_pc + ex_imm);

  // ======================================================================
  // EX/MEM pipeline register
  // ======================================================================
  logic [31:0] mem_alu, mem_pc4, mem_imm, mem_store_data, mem_vaddr;
  logic [1:0]  mem_rd_src; logic [2:0] mem_funct3_r;
  logic        mem_mem_read, mem_mem_write, mem_valid;
  logic        mem_is_vlw, mem_is_vsw; logic [2:0] mem_v_vd;
  logic [N*32-1:0] mem_vstore;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mem_valid<=0; mem_reg_we<=0; mem_rd<=0; mem_alu<=0; mem_rd_src<=RD_ALU;
      mem_mem_read<=0; mem_mem_write<=0; mem_funct3_r<=0; mem_store_data<=0;
      mem_pc4<=0; mem_imm<=0; mem_is_vlw<=0; mem_is_vsw<=0; mem_v_vd<=0;
      mem_vaddr<=0; mem_vstore<=0;
    end else begin
      mem_valid     <= ex_valid;
      mem_reg_we    <= ex_valid && ex_reg_we;
      mem_rd        <= ex_rd;
      mem_alu       <= ex_alu_result;
      mem_rd_src    <= ex_rd_src;
      mem_mem_read  <= ex_valid && ex_mem_read;
      mem_mem_write <= ex_valid && ex_mem_write;
      mem_funct3_r  <= ex_mem_funct3;
      mem_store_data<= fwd_b;
      mem_pc4       <= ex_pc + 4;
      mem_imm       <= ex_imm;
      mem_is_vlw    <= ex_valid && ex_is_vlw;
      mem_is_vsw    <= ex_valid && ex_is_vsw;
      mem_v_vd      <= ex_v_vd;
      mem_vaddr     <= ex_vmem_addr;
      mem_vstore    <= vrf_rd1;       // VSW store data (vs read via port 1)
    end
  end

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
  logic [N*32-1:0] f_accum_word;
  always_comb begin
    f_accum_word = '0;
    f_accum_word[0 +: 32] = f_accum;
  end
  always_comb begin
    if (fstate == F_RUN && f_out && !f_mode) begin     // stream out N words
      vW_we = 1'b1; vW_addr = f_pw; vW_wdata = grid_drain_val; vW_wmask = grid_drain_act;
    end else if (fstate == F_FIN) begin                // accumulate -> 1 scalar
      vW_we = 1'b1; vW_addr = f_pw; vW_wdata = f_accum_word; vW_wmask = {{(N-1){1'b0}}, 1'b1};
    end else begin                                      // VSW
      vW_we = mem_is_vsw; vW_addr = mem_vaddr; vW_wdata = mem_vstore; vW_wmask = {N{1'b1}};
    end
  end

  always_comb begin
    unique case (mem_rd_src)
      RD_MEM : mem_wb_data = dmem_rdata;
      RD_PC4 : mem_wb_data = mem_pc4;
      RD_IMM : mem_wb_data = mem_imm;
      default: mem_wb_data = mem_alu;
    endcase
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
      wb_data_fwd <= mem_wb_data;
    end
  end
  assign wb_we   = wb_we_r;
  assign wb_rd   = wb_rd_r;
  assign wb_data = wb_data_fwd;

  // ======================================================================
  // Halt on ECALL
  // ======================================================================
  // ECALL halts, but only when it actually commits down the correct path:
  //  - not while a grid op is in flight (ECALL held frozen in ID behind it), and
  //  - not when a taken branch/jump is flushing ID this cycle (the ECALL would
  //    then be a squashed fall-through of the branch).
  always_ff @(posedge clk) begin
    if (!rst_n) halt <= 1'b0;
    else if (id_valid && d_ecall && !grid_busy && !redirect) halt <= 1'b1;
  end
endmodule
