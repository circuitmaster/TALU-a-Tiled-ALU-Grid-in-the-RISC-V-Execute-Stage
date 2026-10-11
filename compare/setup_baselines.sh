#!/usr/bin/env bash
# Fetch and build the two vector-processor baselines at the exact commits used
# in the paper, and apply our two small simulator-only patches.
#
#   RISC-V^2  github.com/ic-lab-duth/RISC-V-Vector  (Verilator, 4 lanes)
#   Vicuna    github.com/vproc/vicuna               (Verilator, Ibex host,
#                                                    VREG_W=128, VMEM_W=64)
#
# usage: compare/setup_baselines.sh            (idempotent; re-run is cheap)
# needs: git, verilator (5.x), make, a C++ compiler, and for Vicuna kernels a
#        rv32imv GCC (riscv32-unknown-elf-* or riscv-none-elf-*).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"
mkdir -p "$BUILD"

RV2_URL=https://github.com/ic-lab-duth/RISC-V-Vector.git
RV2_SHA=8ded0f4036bcb34868c2d15475883d03bff37328
VIC_URL=https://github.com/vproc/vicuna.git
VIC_SHA=debfb03a74b13dc0b212084eb13027345cd5b5f3

fetch() {   # $1 dir  $2 url  $3 sha
  if [ ! -d "$HERE/$1/.git" ]; then
    git clone --quiet "$2" "$HERE/$1"
  fi
  git -C "$HERE/$1" checkout --quiet "$3"
}

patch_once() {   # $1 dir  $2 patch
  if git -C "$HERE/$1" apply --check "$HERE/patches/$2" 2>/dev/null; then
    git -C "$HERE/$1" apply "$HERE/patches/$2"
    echo "   applied $2"
  elif git -C "$HERE/$1" apply --reverse --check "$HERE/patches/$2" 2>/dev/null; then
    echo "   $2 already applied"
  else
    echo "   ERROR: $2 does not apply to $1"; exit 1
  fi
}

echo "== RISC-V^2 @ ${RV2_SHA:0:7}"
fetch RISC-V-Vector "$RV2_URL" "$RV2_SHA"
patch_once RISC-V-Vector riscv2-verilator-include.patch

echo "== Vicuna @ ${VIC_SHA:0:7}"
fetch vicuna "$VIC_URL" "$VIC_SHA"
git -C "$HERE/vicuna" submodule update --init --quiet ibex
patch_once vicuna vicuna-verilator-cycles.patch

VSIM="$BUILD/vicuna/obj_dir/Vvproc_top"
if [ ! -x "$VSIM" ]; then
  echo "== building the Vicuna simulator (a few minutes)"
  mkdir -p "$BUILD/vicuna"
  make -C "$HERE/vicuna/sim" PROJ_DIR="$BUILD/vicuna" \
       VREG_W=128 VMEM_W=64 MEM_W=32 "$BUILD/vicuna/obj_dir/Vvproc_top.mk" \
       > "$BUILD/vicuna/gen.log" 2>&1
  make -C "$BUILD/vicuna/obj_dir" -f Vvproc_top.mk Vvproc_top -j"$(nproc)" \
       > "$BUILD/vicuna/build.log" 2>&1
fi
echo "   $VSIM"

# Vicuna's C runtime start file, needed to link the kernels
PFX=""
for p in riscv32-unknown-elf- riscv-none-elf- riscv64-unknown-elf-; do
  command -v "${p}gcc" >/dev/null 2>&1 && { PFX=$p; break; }
done
if [ -n "$PFX" ]; then
  # newer GCCs need Zicsr named explicitly; older ones reject the suffix
  "${PFX}gcc" -march=rv32im_zicsr -mabi=ilp32 -c "$HERE/vicuna/sw/crt0.S" \
      -o "$HERE/vicuna/sw/crt0.o" 2>/dev/null ||
  "${PFX}gcc" -march=rv32im -mabi=ilp32 -c "$HERE/vicuna/sw/crt0.S" \
      -o "$HERE/vicuna/sw/crt0.o"
  echo "== crt0.o built with ${PFX}gcc"
else
  echo "== WARNING: no RISC-V GCC found; Vicuna kernels cannot be compiled"
fi
echo "done."
