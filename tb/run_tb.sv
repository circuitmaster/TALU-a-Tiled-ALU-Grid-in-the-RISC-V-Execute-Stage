// run_tb.sv -- generic program runner for the TALU core.
//   vvp build/run +PROG=build/x.hex [+DMEM=build/d.hex] [+MAXCYC=2000] [+DUMP=1]
// Loads the program into imem, runs until halt (ecall) or MAXCYC, then dumps
// the scalar register file, first data-memory words, and the vector regfile.
`timescale 1ns/1ps
`include "talu_pkg.sv"

module run_tb;
  import talu_pkg::*;
  localparam int N = GRID_N;

  logic clk = 0, rst_n = 0, halt;
  talu_top #(.N(N), .IWORDS(1024), .DWORDS(16384)) dut (.clk, .rst_n, .halt);

  always #5 clk = ~clk;

  // vector-memory access trace (+MEMTRACE=<file>); off by default
  integer mtf = 0, mtc = 0;
  string  mtfile;
  initial if ($value$plusargs("MEMTRACE=%s", mtfile)) mtf = $fopen(mtfile, "w");
  always @(posedge clk) if (rst_n && mtf != 0 && dut.u_core.fstate == 2'd1)
    $fwrite(mtf, "%0d %0d %0d %0d %0d %0d %0d %0d\n", mtc++,
            dut.u_core.f_inject, dut.u_core.vA_addr,
            dut.u_core.f_bfetch, dut.u_core.vB_addr,
            dut.u_core.vW_we,    dut.u_core.vW_addr, dut.u_core.vW_wmask);

  // fabric-utilization counters (+UTIL=1 to report; counting is harmless)
  int unsigned util_run = 0, util_busy = 0, util_tilecyc = 0, util_tot = 0;
  int unsigned util_t0 = 0, util_t1 = 0;   // first/last GFLOW streaming cycle
  always @(posedge clk) if (rst_n && !halt) begin
    util_tot++;
    if (dut.u_core.grid_busy) util_busy++;
    if (dut.u_core.fstate == 2'd1) begin          // GFLOW F_RUN
      util_run++;
      if (util_t0 == 0) util_t0 = util_tot;      // entry into streaming
      util_t1 = util_tot;                         // last streaming cycle
      for (int i = 0; i < N*N; i++)
        if (dut.u_core.cfg_op_f[i*5 +: 5] != 5'd31) util_tilecyc++;  // != ALU_NOP
    end
  end

  string progfile, dmemfile;
  int maxcyc, cyc = 0, dump = 0;
  int dumpbase = 0, dumpn = 64;   // data-dump window (+DUMPBASE/+DUMPN)

  initial begin
    if (!$value$plusargs("PROG=%s", progfile)) begin
      $display("ERROR: +PROG=<hex> required"); $finish;
    end
    if (!$value$plusargs("MAXCYC=%d", maxcyc)) maxcyc = 4000;
    void'($value$plusargs("DUMP=%d", dump));
    void'($value$plusargs("DUMPBASE=%d", dumpbase));
    void'($value$plusargs("DUMPN=%d", dumpn));

    // load program + optional data image
    $readmemh(progfile, dut.u_imem.mem);
    if ($value$plusargs("DMEM=%s", dmemfile)) $readmemh(dmemfile, dut.u_dmem.mem);

    // reset
    repeat (3) @(negedge clk);
    rst_n = 1;

    // run
    while (!halt && cyc < maxcyc) begin
      @(posedge clk); cyc++;
    end
    // drain the pipeline so in-flight instructions reach writeback
    repeat (4) @(posedge clk);

    @(negedge clk);
    if (halt) $display("HALT at cycle %0d", cyc);
    else      $display("TIMEOUT at cycle %0d", cyc);
    if ($test$plusargs("UTIL"))
      $display("UTIL total=%0d busy=%0d run=%0d tilecyc=%0d tiles=%0d t0=%0d t1=%0d",
               util_tot, util_busy, util_run, util_tilecyc, N*N, util_t0, util_t1);

    // dump scalar registers (rf is a flat packed vector)
    for (int i = 1; i < 32; i++)
      $display("x%0d=%08x", i, dut.u_core.rf.rf[i*32 +: 32]);
    // dump data words (default: the first 64)
    for (int i = dumpbase; i < dumpbase + dumpn; i++)
      $display("mem[%0d]=%08x", i, dut.u_dmem.mem[i]);
    // dump vector registers, lane by lane (lane 0 = lowest word)
    for (int v = 0; v < VREGS; v++)
      for (int l = 0; l < N; l++)
        $display("v%0d[%0d]=%08x", v, l, dut.u_core.vrf.vrf[(v*N + l)*32 +: 32]);

    if (mtf != 0) $fclose(mtf);
    $finish;
  end
endmodule
