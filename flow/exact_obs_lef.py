#!/usr/bin/env python3
"""Post-process a block abstract LEF for consumption as a chip macro.

ORFS generate_abstract hardcodes `write_abstract_lef
-bloat_occupied_layers`: every layer with ANY shape gets a single
full-die OBS rect. For mac_grid that blanket lands on M6/M7 — directly
on top of the macro's own M6 power-pin straps — so chip-level pdngen
can never via down to them (PDN-0006, docs/HARDENING.md).

The fix is two abstracts merged:
  * exact (`-bloat_factor 0`) ONLY for the first clear layer above the
    macro's pins (M7: 168 rects), where the parent's PDN vias land, and
  * the blanket kept for everything else — the tile sea covers M1–M5
    wall to wall, and M6 is the macro's own power layer: exact M6 OBS
    (2k rects) fragments the parent's die-wide M6 straps against every
    rect and pdngen's via-candidate enumeration runs away (>12 GB,
    killed twice). A blanket cuts those straps at the macro edge in one
    piece, and M7→M6-pin vias have no intermediate layer to block.

Usage:
    exact_obs_lef.py <exact.lef> <out.lef> [--exact-layers M7]

The output replaces each non-exact layer's OBS rect list with one
bounding rect; PIN sections are untouched.
"""

import argparse
import re
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("exact_lef", help="LEF from write_abstract_lef -bloat_factor 0")
    ap.add_argument("out_lef")
    ap.add_argument("--exact-layers", default="M7",
                    help="comma-separated layers whose OBS stays exact")
    args = ap.parse_args()
    keep_exact = set(args.exact_layers.split(","))

    text = open(args.exact_lef).read()
    m = re.search(r"(OBS\n)(.*?)(\n  END\n)", text, re.S)
    if not m:
        sys.exit("✗ no OBS section found")
    body = m.group(2)

    out_layers = []
    for layer, rects in re.findall(
            r"LAYER (\S+) ;\s*\n((?:\s*RECT [^;]+;\s*\n?)+)", body):
        rl = re.findall(r"RECT ([-\d. ]+) ;", rects)
        if layer in keep_exact:
            block = f"    LAYER {layer} ;\n" + "".join(
                f"      RECT {r} ;\n" for r in rl)
            n = len(rl)
        else:
            xs, ys = [], []
            for r in rl:
                x0, y0, x1, y1 = map(float, r.split())
                xs += [x0, x1]
                ys += [y0, y1]
            block = (f"    LAYER {layer} ;\n"
                     f"      RECT {min(xs):g} {min(ys):g} "
                     f"{max(xs):g} {max(ys):g} ;\n")
            n = 1
        out_layers.append(block)
        print(f"  OBS {layer}: {n} rects"
              f"{' (exact)' if layer in keep_exact else ' (blanket)'}")

    new = text[:m.start(2)] + "".join(out_layers).rstrip("\n") + text[m.end(2):]
    open(args.out_lef, "w").write(new)
    print(f"wrote {args.out_lef}")


if __name__ == "__main__":
    main()
