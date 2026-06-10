# cocotb testbench runner for PtahCore RTL leaves.
#
#   make TOP=fp8_decode      → exhaustive decode test
#   make TOP=fp32_mul        → multiply vs numpy
#   make TOP=fp32_add        → adder vs numpy
#   make TOP=mac_cell        → MAC leaf vs pymodel
#   make all_leaves          → everything above in sequence

SIM ?= verilator
TOPLEVEL_LANG = verilog
EXTRA_ARGS += --trace --trace-structs

PWD := $(shell pwd)
RTL := $(PWD)/..

TOP ?= fp8_decode

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

TOPLEVEL = $(TOP)

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: all_leaves
all_leaves:
	$(MAKE) TOP=fp8_decode
	$(MAKE) TOP=fp32_mul
	$(MAKE) TOP=fp32_add
	$(MAKE) TOP=mac_cell
