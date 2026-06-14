#!/bin/sh
# Phase 10 — prove the RTL elaborates clean at the 64x64x64 config (NOT just
# the pymodel: pymodel/tests/test_scale.py proves the algorithm scales; this
# proves the actual Verilog — generate-blocks and bit-widths — holds at 64).
#
#   sh synth/lint_64.sh        # must print "ALL CLEAN @ 64x64x64", exit 0
#
# verilator --lint-only catches width/generate bugs the pymodel can't. The
# only suppression, -Wno-WIDTHCONCAT, is a benign style warning: zeroing the
# operand latch (a_lat/b_lat <= '0) is a 64*64*8 = 32768-bit replication,
# which trips the ">8k replication is probably wrong" heuristic — here it is
# correct (a wide reset). No real width error is masked by it.
set -e
cd "$(dirname "$0")/.."

COMMON="--lint-only -Wno-WIDTHCONCAT -GM=64 -GN=64 -GK=64"

echo "== mac_array @ 64x64x64 =="
verilator $COMMON --top-module mac_array \
  rtl/fp8_decode.sv rtl/fp32_mul.sv rtl/fp32_add.sv rtl/mac_cell.sv \
  rtl/mac_tile.sv rtl/mac_grid.sv rtl/mac_array.sv

echo "== mma_unit @ 64x64x64 =="
verilator $COMMON --top-module mma_unit \
  rtl/fp8_decode.sv rtl/fp32_mul.sv rtl/fp32_add.sv rtl/mac_cell.sv \
  rtl/mac_tile.sv rtl/mac_grid.sv rtl/mac_array.sv rtl/mma_unit.sv

echo "== chip_top @ 64x64x64 =="
verilator $COMMON --top-module chip_top \
  rtl/fp8_decode.sv rtl/fp8_encode.sv rtl/fp32_mul.sv rtl/fp32_add.sv \
  rtl/mac_cell.sv rtl/mac_tile.sv rtl/mac_grid.sv rtl/mac_array.sv rtl/mma_unit.sv \
  rtl/fakeram7_256x256.sv rtl/smem_phys.sv rtl/ptah_clkbuf.sv rtl/clk_spine.sv \
  rtl/mx_scale.sv rtl/barrier.sv rtl/load.sv rtl/store.sv rtl/cmdproc.sv rtl/chip_top.sv

echo "ALL CLEAN @ 64x64x64"
