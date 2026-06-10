# cocotb testbench driver for PtahCore RTL leaves.
#
#   make TOP=fp8_decode      → exhaustive decode test
#   make TOP=fp32_mul        → multiply vs numpy
#   make TOP=fp32_add        → adder vs numpy
#   make TOP=mac_cell        → MAC leaf vs pymodel
#   make all_leaves          → everything above in sequence
#
# Why the indirection: cocotb exports PYTHONHOME for its embedded
# interpreter (conda is not a venv). Verilator's helper scripts then run
# /usr/bin/python3 with that foreign PYTHONHOME and die in 'encodings'.
# Command-line variable definitions propagate to every recursive make
# (MAKEOVERRIDES), so the driver hands verilated.mk a clean interpreter.

TOP ?= fp8_decode
HERE := $(shell pwd)

.PHONY: sim all_leaves clean
sim:
	$(MAKE) -f cocotb.mk TOP=$(TOP) PYTHON3=$(HERE)/python3-clean

all_leaves:
	$(MAKE) sim TOP=fp8_decode
	$(MAKE) sim TOP=fp32_mul
	$(MAKE) sim TOP=fp32_add
	$(MAKE) sim TOP=mac_cell
	$(MAKE) sim TOP=fp8_encode
	$(MAKE) sim TOP=smem
	$(MAKE) sim TOP=barrier
	$(MAKE) sim TOP=load
	$(MAKE) sim TOP=store
	$(MAKE) sim TOP=mac_array
	$(MAKE) sim TOP=cmdproc_tb_top
	$(MAKE) sim TOP=mma_unit
	$(MAKE) sim TOP=chip_top

clean:
	rm -rf sim_build_* results.xml dump.vcd __pycache__
