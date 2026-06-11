#!/usr/bin/env python3
"""PtahCore — make the tile's clock feedthrough STA-propagatable.

OpenROAD's write_timing_model characterises mac_tile's clk_in→clk_out
feedthrough as a `falling_edge` arc with a negative cell_rise reference.
Edge-triggered arcs TERMINATE clock propagation in OpenSTA (same rule as
a flop's clk→q), so in the abutted row only tile 0 ever sees a clock and
tiles 1–31 are silently UNCONSTRAINED — the worst kind of false-clean
(run-4 reported violations only because tile-0 paths exist).

The arc's measured delay (~89 ps fall) is real; only the TYPE encoding
is wrong for a wire feedthrough. This patch rewrites the clk_out timing
group as `combinational` / `positive_unate`, reusing the measured FALL
tables for both transitions (the negative-reference rise table is
discarded; rise/fall asymmetry of a buffered wire is ≪ the 100 ps clock
uncertainty already in the SDC). Documented in docs/HARDENING.md — this
is a model-encoding fix, not a timing waiver.

Usage: python3 flow/patch_tile_clk_arc.py <mac_tile_typ.lib>
Idempotent: skips if already patched.
"""

import re
import sys


def main():
    path = sys.argv[1]
    txt = open(path).read()

    m = re.search(r'(    pin\("clk_out"\) \{.*?\n    \})', txt, re.S)
    if not m:
        sys.exit("clk_out pin group not found")
    group = m.group(1)

    if "combinational" in group:
        print("already patched — skipping")
        return

    if "falling_edge" not in group:
        sys.exit("unexpected clk_out arc encoding (no falling_edge); "
                 "inspect manually")

    fall_delay = re.search(
        r"cell_fall\(template_1\) \{\s*index_1\(([^)]*)\);\s*"
        r"values\(([^)]*)\);", group, re.S)
    fall_tran = re.search(
        r"fall_transition\(template_1\) \{\s*index_1\(([^)]*)\);\s*"
        r"values\(([^)]*)\);", group, re.S)
    cap = re.search(r"capacitance : ([\d.]+);", group)
    if not (fall_delay and fall_tran and cap):
        sys.exit("could not extract fall tables from clk_out group")

    def table(kind, idx, vals):
        return (f"        {kind}(template_1) {{\n"
                f"          index_1({idx});\n"
                f"          values({vals});\n"
                f"        }}")

    new_group = (
        '    pin("clk_out") {\n'
        "      direction : output;\n"
        f"      capacitance : {cap.group(1)};\n"
        "      timing() {\n"
        '        related_pin : "clk_in";\n'
        "        timing_sense : positive_unate;\n"
        "        timing_type : combinational;\n"
        + table("cell_rise", fall_delay.group(1), fall_delay.group(2)) + "\n"
        + table("rise_transition", fall_tran.group(1), fall_tran.group(2)) + "\n"
        + table("cell_fall", fall_delay.group(1), fall_delay.group(2)) + "\n"
        + table("fall_transition", fall_tran.group(1), fall_tran.group(2)) + "\n"
        "      }\n"
        "    }"
    )

    open(path, "w").write(txt.replace(group, new_group))
    print(f"patched clk_out arc in {path}: falling_edge → combinational "
          f"(measured fall tables reused for both transitions)")


if __name__ == "__main__":
    main()
