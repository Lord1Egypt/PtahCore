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

TOPLEVEL = $(TOP)

include $(shell cocotb-config --makefiles)/Makefile.sim
