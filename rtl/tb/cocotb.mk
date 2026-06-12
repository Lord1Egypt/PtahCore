# cocotb simulation makefile — invoked BY ./Makefile, not directly.
# (The driver passes PYTHON3=python3-clean on the command line so the
# override reaches Verilator's verilated.mk in the innermost sub-make.)

SIM ?= verilator
TOPLEVEL_LANG = verilog
EXTRA_ARGS += --trace --trace-structs

PWD := $(shell pwd)
RTL := $(PWD)/..

TOP ?= fp8_decode
# per-unit build dir — sharing one sim_build across TOPs leaves stale objects
SIM_BUILD = sim_build_$(TOP)

ifeq ($(TOP),fp8_decode)
  VERILOG_SOURCES = $(RTL)/fp8_decode.sv
  MODULE = test_fp8_decode
endif
ifeq ($(TOP),fp32_mul)
  VERILOG_SOURCES = $(RTL)/fp32_mul.sv
  MODULE = test_fp32_arith
endif
ifeq ($(TOP),fp32_add)
  VERILOG_SOURCES = $(RTL)/fp32_add.sv
  MODULE = test_fp32_arith
endif
ifeq ($(TOP),mac_cell)
  VERILOG_SOURCES = $(RTL)/fp32_mul.sv $(RTL)/fp32_add.sv $(RTL)/mac_cell.sv
  MODULE = test_mac_cell
endif
ifeq ($(TOP),fp8_encode)
  VERILOG_SOURCES = $(RTL)/fp8_encode.sv
  MODULE = test_fp8_encode
endif
ifeq ($(TOP),smem)
  VERILOG_SOURCES = $(RTL)/smem.sv
  MODULE = test_smem_barrier
endif
ifeq ($(TOP),smem_phys)
  VERILOG_SOURCES = $(RTL)/fakeram7_256x256.sv $(RTL)/smem_phys.sv
  MODULE = test_smem_phys
endif
ifeq ($(TOP),barrier)
  VERILOG_SOURCES = $(RTL)/barrier.sv
  MODULE = test_smem_barrier
endif
ifeq ($(TOP),load)
  VERILOG_SOURCES = $(RTL)/load.sv
  MODULE = test_load_store
endif
ifeq ($(TOP),store)
  VERILOG_SOURCES = $(RTL)/fp8_encode.sv $(RTL)/store.sv
  MODULE = test_load_store
endif
ifeq ($(TOP),mac_tile)
  VERILOG_SOURCES = $(RTL)/fp32_mul.sv $(RTL)/fp32_add.sv $(RTL)/mac_cell.sv $(RTL)/mac_tile.sv
  MODULE = test_mac_tile
endif
ifeq ($(TOP),mac_row)
  VERILOG_SOURCES = $(RTL)/fp32_mul.sv $(RTL)/fp32_add.sv $(RTL)/mac_cell.sv $(RTL)/mac_tile.sv $(RTL)/mac_row.sv
  MODULE = test_mac_row
  COMPILE_ARGS += -GN=4
endif
ifeq ($(TOP),mac_grid)
  VERILOG_SOURCES = $(RTL)/fp32_mul.sv $(RTL)/fp32_add.sv $(RTL)/mac_cell.sv $(RTL)/mac_tile.sv $(RTL)/mac_grid.sv
  MODULE = test_mac_grid
  COMPILE_ARGS += -GM=4 -GN=4
endif
ifeq ($(TOP),mac_array)
  VERILOG_SOURCES = $(RTL)/fp8_decode.sv $(RTL)/fp32_mul.sv $(RTL)/fp32_add.sv $(RTL)/mac_cell.sv $(RTL)/mac_tile.sv $(RTL)/mac_grid.sv $(RTL)/mac_array.sv
  MODULE = test_mac_array
  COMPILE_ARGS += -GM=4 -GN=4 -GK=8
endif
ifeq ($(TOP),cmdproc_tb_top)
  VERILOG_SOURCES = $(RTL)/barrier.sv $(RTL)/cmdproc.sv $(RTL)/cmdproc_tb_top.sv
  MODULE = test_cmdproc
endif
ifeq ($(TOP),mma_unit)
  VERILOG_SOURCES = $(RTL)/fp8_decode.sv $(RTL)/fp32_mul.sv $(RTL)/fp32_add.sv $(RTL)/mac_cell.sv $(RTL)/mac_tile.sv $(RTL)/mac_grid.sv $(RTL)/mac_array.sv $(RTL)/mma_unit.sv
  MODULE = test_mma_unit
  # K=16 → A_BYTES=64 = 2 fetch chunks, so the stall/retry path is
  # exercised mid-stream, not only on the first issue
  COMPILE_ARGS += -GM=4 -GN=4 -GK=16
endif
ifeq ($(TOP),chip_top)
  VERILOG_SOURCES = $(RTL)/fp8_decode.sv $(RTL)/fp8_encode.sv $(RTL)/fp32_mul.sv \
    $(RTL)/fp32_add.sv $(RTL)/mac_cell.sv $(RTL)/mac_tile.sv $(RTL)/mac_grid.sv \
    $(RTL)/mac_array.sv $(RTL)/mma_unit.sv $(RTL)/fakeram7_256x256.sv \
    $(RTL)/smem_phys.sv $(RTL)/ptah_clkbuf.sv $(RTL)/clk_spine.sv \
    $(RTL)/barrier.sv \
    $(RTL)/load.sv $(RTL)/store.sv $(RTL)/cmdproc.sv $(RTL)/chip_top.sv
  MODULE = test_chip_top
  COMPILE_ARGS += -GM=4 -GN=4 -GK=8
endif

TOPLEVEL = $(TOP)

include $(shell cocotb-config --makefiles)/Makefile.sim
