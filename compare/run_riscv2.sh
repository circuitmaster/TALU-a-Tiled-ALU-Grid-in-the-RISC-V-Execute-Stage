#!/usr/bin/env bash
# Build+run the RISC-V2 vector simulator for a given kernel.
# usage: run_riscv2.sh <example> <AVL> <LANES> <REALISTIC 0|1>
set -e
[ -d "$(dirname "$0")/RISC-V-Vector" ] || { echo "RISC-V-Vector missing: run compare/setup_baselines.sh"; exit 1; }
EX=${1:-vvadd}; AVL=${2:-1024}; LANES=${3:-4}; REAL=${4:-1}
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/RISC-V-Vector"
VS="$ROOT/vector_simulator"
mkdir -p "$HERE/build"
cd "$VS"

# our extra kernels live in ../riscv2_bench (tracked); upstream examples
# (vvadd, dot_product, fir, saxpy) come with the submodule
if [ -f "$HERE/riscv2_bench/$EX/instrs.csv" ]; then
  cp "$HERE/riscv2_bench/$EX/instrs.csv" instrs.csv
else
  cp "examples/$EX/instrs.csv" instrs.csv
fi
python3 sim_generator.py instrs.csv "$AVL" "$LANES" >/dev/null 2>&1

# set memory realism
sed -i -E "s/localparam int REALISTIC = [0-9]+;/localparam int REALISTIC = $REAL;/" ../rtl/shared/params.sv

HEADERS="../rtl/vector/vmacros.sv ../rtl/shared/params.sv ../rtl/shared/structs.sv ../rtl/vector/vstructs.sv"
REST=$(grep -hvE '^\s*(-sv|//|#|$)' files_rtl.f files_sim.f | grep -vE 'vmacros\.sv|shared/params\.sv|shared/structs\.sv|vstructs\.sv')
verilator --binary -j 4 --top-module vector_sim_top \
  -Wno-fatal -Wno-lint -Wno-style --timing \
  -I../rtl/shared -I../rtl/vector -I../vector_simulator -I../vector_simulator/decoder_results \
  $HEADERS $REST -o vsim > "$HERE/build/riscv2_build.log" 2>&1 || { echo "BUILD FAILED"; tail -5 "$HERE/build/riscv2_build.log"; exit 1; }

CYC=$(timeout 300 ./obj_dir/vsim 2>&1 | grep "Total Cycles" | grep -oE "[0-9]+")
echo "RISC-V2  $EX  AVL=$AVL lanes=$LANES realistic=$REAL  ->  $CYC cycles"
