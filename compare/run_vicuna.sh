#!/usr/bin/env bash
# Build + run one Vicuna RVV kernel and print its cycle count (PROG_CYCLES,
# reported by our verilator_main.cpp patch).
# usage: run_vicuna.sh <kernel> [AVL] [MEM_LATENCY]
#   kernel = a file compare/vicuna_bench/<kernel>.S
# The count includes Vicuna's fixed start-up; `empty` measures it (21 cycles)
# and compare/table1.py subtracts it.
set -euo pipefail
K=$1; AVL=${2:-1024}; LAT=${3:-1}
HERE="$(cd "$(dirname "$0")" && pwd)"; VIC="$HERE/vicuna"
SIM=${VSIM:-$HERE/build/vicuna/obj_dir/Vvproc_top}
[ -x "$SIM" ] || { echo "Vicuna simulator missing: run compare/setup_baselines.sh"; exit 1; }

# RISC-V GCC: riscv32-unknown-elf-*, riscv-none-elf-* (xPack) or riscv64-unknown-elf-*
P=${RISCV_PREFIX:-}
if [ -z "$P" ]; then
  for p in riscv32-unknown-elf- riscv-none-elf- riscv64-unknown-elf-; do
    command -v "${p}gcc" >/dev/null 2>&1 && { P=$p; break; }
  done
fi
[ -n "$P" ] || { echo "no RISC-V GCC on PATH (set RISCV_PREFIX)"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
F="-march=rv32imv -mabi=ilp32 -static -mcmodel=medany -nostdlib -nostartfiles"
"${P}gcc" $F -DAVL="$AVL" -c "$HERE/vicuna_bench/$K.S" -o "$T/k.o"
"${P}gcc" $F -T "$VIC/sw/link.ld" "$VIC/sw/crt0.o" "$T/k.o" -o "$T/k.elf" 2>/dev/null
"${P}objcopy" -O binary "$T/k.elf" "$T/k.bin"
python3 "$HERE/bin2vmem.py" "$T/k.bin" "$T/k.vmem"
echo "$T/k.vmem /dev/null 0 0 /dev/null 0 0" > "$T/progs.txt"
CYC=$("$SIM" "$T/progs.txt" 32 262144 "$LAT" 256 /dev/null 2>&1 >/dev/null \
      | grep PROG_CYCLES | grep -oE "[0-9]+")
echo "Vicuna $K AVL=$AVL lat=$LAT -> $CYC cycles"
