# TALU -- build, test, and reproduce every number in the paper.
#
#   make test        lint + unit testbenches + program suites (both cores)
#   make paper       regenerate every table, figure and in-text number
#                    (needs `make baselines` once for the vector-core columns)
#   make help        all targets
#
# rtl/       the 1 GHz (retimed) core -- used for every result in the paper
# rtl_base/  the baseline core       -- Table I "base" column

IV   = iverilog -g2012
VL   = verilator --lint-only -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME
PY   = python3
B    = build
R    = results

UNITS_1G   = alu regfile alu_tile_1g talu_mul vregfile decoder dmem
UNITS_BASE = alu regfile alu_tile alu_grid vregfile decoder dmem

.PHONY: help all sim test lint units programs equiv compiler baselines paper \
        table1 fig4 scaling numbers clean

help:
	@echo "make sim         build both simulators (build/run = 1 GHz, build/run_base)"
	@echo "make test        lint + unit testbenches + program suites + core equivalence"
	@echo "make compiler    build the LLVM pass and run its end-to-end check (LLVM 20)"
	@echo "make baselines   fetch + patch + build RISC-V^2 and Vicuna (network, ~5 min)"
	@echo "make table1      Table I"
	@echo "make fig4        Fig. 4"
	@echo "make scaling     Table II throughput columns (grid size, multiplier variants)"
	@echo "make numbers     in-text numbers of Sec. IV"
	@echo "make paper       all of the above except baselines"

all: test

# ---------------------------------------------------------------- simulators
sim: $(B)/run $(B)/run_base
$(B)/run: tb/run_tb.sv $(wildcard rtl/*.sv)
	@mkdir -p $(B)
	$(IV) -I rtl -o $@ tb/run_tb.sv rtl/*.sv 2>&1 | grep -v "sorry:" || true
$(B)/run_base: tb/run_tb.sv $(wildcard rtl_base/*.sv)
	@mkdir -p $(B)
	$(IV) -I rtl_base -o $@ tb/run_tb.sv rtl_base/*.sv 2>&1 | grep -v "sorry:" || true

# ---------------------------------------------------------------- tests
test: lint units programs equiv

lint:
	@$(VL) -Irtl      --top-module talu_top rtl/*.sv      && echo "LINT OK  rtl/"
	@$(VL) -Irtl_base --top-module talu_top rtl_base/*.sv && echo "LINT OK  rtl_base/"

units:
	@mkdir -p $(B)
	@for u in $(UNITS_1G); do \
	  $(IV) -I rtl -o $(B)/$${u}_tb tb/$${u}_tb.sv rtl/*.sv 2>&1 | grep -v "sorry:"; \
	  printf "%-9s %-16s " rtl/ $$u; vvp $(B)/$${u}_tb | grep -E "PASS|FAIL" | tail -1; \
	done
	@for u in $(UNITS_BASE); do \
	  $(IV) -I rtl_base -o $(B)/$${u}_tb_base tb/$${u}_tb.sv rtl_base/*.sv 2>&1 | grep -v "sorry:"; \
	  printf "%-9s %-16s " rtl_base/ $$u; vvp $(B)/$${u}_tb_base | grep -E "PASS|FAIL" | tail -1; \
	done

programs: sim
	@echo "== program suite, rtl/ (1 GHz)";  $(PY) tests/run_all.py --sim $(B)/run
	@echo "== program suite, rtl_base/";      $(PY) tests/run_all.py --sim $(B)/run_base

equiv: sim
	$(PY) tools/equiv_cores.py

compiler: $(B)/run
	$(MAKE) -C compiler
	$(PY) compiler/verify.py

# ---------------------------------------------------------------- baselines
baselines:
	bash compare/setup_baselines.sh

# ---------------------------------------------------------------- paper
paper: table1 fig4 scaling numbers

table1: sim
	@mkdir -p $(R)
	$(PY) compare/table1.py | tee $(R)/table1.txt

fig4: sim
	@mkdir -p $(R)
	$(PY) tools/abl_reduce.py | tee $(R)/fig4_reduction.txt
	$(PY) scripts/plot_reduction.py

scaling:
	@mkdir -p $(R)
	@for v in full mulcol0 nomul; do $(PY) compare/scaling.py --variant $$v; done

numbers: sim
	@mkdir -p $(R)
	$(PY) tools/abl_scaling.py chain   | tee $(R)/deep_chain.txt
	$(PY) tools/abl_scaling.py issue   | tee $(R)/issue_vs_width.txt
	$(PY) tools/abl_scaling.py avl     | tee $(R)/avl_sweep_talu.txt
	$(PY) compare/bench.py 256 1024 4096 | tee $(R)/avl_sweep_vs_riscv2.txt
	$(PY) compare/table1.py --talu-only --avl 64   | tee $(R)/retiming_avl64.txt
	$(PY) compare/table1.py --talu-only --avl 4096 | tee $(R)/retiming_avl4096.txt
	$(PY) tools/mem_ablate.py          | tee $(R)/memory_model.txt
	$(PY) tools/map_ablate.py          | tee $(R)/compiler_mapping.txt

clean:
	rm -rf $(B) compiler/build compiler/TALUMap.so
