#!/usr/bin/env python3
"""Fail the make target when the last cocotb run had failing tests.

cocotb 1.x's Makefile.sim exits 0 even when tests FAIL — this once let a
4-suite regression hide inside a green `make all_leaves`. The driver
Makefile runs this after every sim; it parses results.xml (written by
cocotb in this directory) and exits 1 on any <failure>.
"""

import sys
import xml.etree.ElementTree as ET

failures = ET.parse("results.xml").findall(".//failure")
if failures:
    print(f"FAILED: {len(failures)} failing test(s) in results.xml")
    sys.exit(1)
