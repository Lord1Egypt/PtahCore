#!/usr/bin/env python3
"""PtahCore — machine check of the TILE_SPEC abutment invariants.

Verifies, against the routed DEF of an abutted parent (row or array) and
the tile's LEF abstract:

  A1. every tile instance sits at its EXACT requested grid position
      (origin = x0 + col*W, y0 + row*H) — zero placer snap;
  A2. abutted pin coincidence: tile (r,c)'s east-edge pin geometry lands
      coordinate-exact on tile (r,c+1)'s matching west-edge pin (and
      south-on-north for stacked rows);
  A3. tile outline is integral in the site grid and every owned
      routing-track pitch (the MPL-0041 lesson).

Usage:
  python3 flow/check_abutment.py \
      --def  flow/results/asap7/mac_row_abut/base/6_final.def \
      --lef  flow/results/asap7/mac_row_abut_mac_tile/base/mac_tile.lef \
      --cols 32 --rows 1 --x0 2.16 --y0 12.96

Exits non-zero on any violation. Pure stdlib.
"""

import argparse
import re
import sys


def parse_lef_pins(lef_path):
    """Pin name → (layer, x1, y1, x2, y2) of the first RECT, in µm."""
    txt = open(lef_path).read()
    size = re.search(r"SIZE ([\d.]+) BY ([\d.]+)", txt)
    w, h = float(size.group(1)), float(size.group(2))
    pins = {}
    for m in re.finditer(
        r"PIN (\S+)\s.*?PORT\s+(.*?)\s+END\b", txt, re.S
    ):
        name, port = m.group(1), m.group(2)
        lay = re.search(r"LAYER (\S+)", port)
        rect = re.search(
            r"RECT\s+([\d.-]+)\s+([\d.-]+)\s+([\d.-]+)\s+([\d.-]+)", port
        )
        if lay and rect:
            x1, y1, x2, y2 = map(float, rect.groups())
            pins[name] = (lay.group(1), x1, y1, x2, y2)
    return w, h, pins


def parse_def_components(def_path, master):
    """instance name → (x µm, y µm) for all instances of `master`."""
    txt = open(def_path).read()
    dbu = int(re.search(r"UNITS DISTANCE MICRONS (\d+)", txt).group(1))
    comps = {}
    sec = txt.split("COMPONENTS")[1].split("END COMPONENTS")[0]
    for m in re.finditer(
        r"- (\S+) (\S+) \+ (?:PLACED|FIXED) \( (-?\d+) (-?\d+) \)", sec
    ):
        inst, mast, x, y = m.group(1), m.group(2), int(m.group(3)), int(m.group(4))
        if mast == master:
            comps[inst] = (x / dbu, y / dbu)
    return comps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_path", required=True)
    ap.add_argument("--lef", required=True)
    ap.add_argument("--master", default="mac_tile")
    ap.add_argument("--cols", type=int, required=True)
    ap.add_argument("--rows", type=int, default=1)
    ap.add_argument("--x0", type=float, required=True)
    ap.add_argument("--y0", type=float, required=True)
    ap.add_argument(
        "--pitches-x", default="0.054,0.036,0.048",
        help="site + vertical-layer track pitches (µm)")
    ap.add_argument(
        "--pitches-y", default="0.27,0.036,0.048",
        help="row + horizontal-layer track pitches (µm)")
    args = ap.parse_args()

    W, H, pins = parse_lef_pins(args.lef)
    comps = parse_def_components(args.def_path, args.master)
    fails = 0

    def fail(msg):
        nonlocal fails
        fails += 1
        print(f"FAIL  {msg}")

    # A3 — outline integral in every pitch (nm math to dodge float fuzz)
    for dim, val, plist in (("width", W, args.pitches_x),
                            ("height", H, args.pitches_y)):
        for p in (float(s) for s in plist.split(",")):
            if round(val * 1e6) % round(p * 1e6):
                fail(f"A3 outline {dim} {val} not a multiple of pitch {p}")

    # A1 — exact grid positions. Geometric row index r counts from the
    # BOTTOM (y grows up); the grid floorplan puts RTL row 0 at the TOP
    # (B enters from the north die edge — gen_floorplan.py), so the
    # instance at geometric row r is row[rows-1-r].
    def inst_name(r, c):
        # row top uses col[c].u_tile; array uses row[i].col[c].u_tile
        return (f"col\\[{c}\\].u_tile" if args.rows == 1
                else f"row\\[{args.rows - 1 - r}\\].col\\[{c}\\].u_tile")

    grid = {}
    for r in range(args.rows):
        for c in range(args.cols):
            want = (args.x0 + c * W, args.y0 + r * H)
            inst = inst_name(r, c)
            got = comps.get(inst)
            if got is None:
                fail(f"A1 {inst} missing from DEF")
                continue
            if (round(got[0] * 1000) != round(want[0] * 1000)
                    or round(got[1] * 1000) != round(want[1] * 1000)):
                fail(f"A1 {inst} at {got}, requested {want} (snapped?)")
            grid[(r, c)] = got

    # A2 — abutted pin coincidence, east↔west and (if rows>1) south↔north
    we_pairs = [("clk_out", "clk_in"), ("rst_out", "rst_in"),
                ("en_out", "en_in"), ("zero_out", "zero_in"),
                ("row_hit_out", "row_hit_in")]
    we_pairs += [(f"slot_out[{i}]", f"slot_in[{i}]") for i in range(2)]
    we_pairs += [(f"drain_slot_out[{i}]", f"drain_slot_in[{i}]")
                 for i in range(2)]
    we_pairs += [(f"a_out[{i}]", f"a_in[{i}]") for i in range(32)]
    ns_pairs = [(f"b_out[{i}]", f"b_in[{i}]") for i in range(32)]
    ns_pairs += [(f"drain_s_out[{i}]", f"drain_n_in[{i}]")
                 for i in range(32)]

    def check_pair(g1, g2, out_pin, in_pin, what):
        """Abutment contact: the two pin rects share a full edge at the
        tile boundary (same layer, touching, identical span along it)."""
        if out_pin not in pins or in_pin not in pins:
            fail(f"A2 {what}: pin {out_pin}/{in_pin} missing from LEF")
            return
        l1, ax1, ay1, ax2, ay2 = pins[out_pin]
        l2, bx1, by1, bx2, by2 = pins[in_pin]
        nm = lambda g, v: round((g + v) * 1000)
        r1 = (nm(g1[0], ax1), nm(g1[1], ay1), nm(g1[0], ax2), nm(g1[1], ay2))
        r2 = (nm(g2[0], bx1), nm(g2[1], by1), nm(g2[0], bx2), nm(g2[1], by2))
        if what.endswith("E"):   # east↔west: touch in x, same y-span
            ok = (l1 == l2 and r1[2] == r2[0]
                  and r1[1] == r2[1] and r1[3] == r2[3])
        else:                    # south↔north: touch in y, same x-span
            ok = (l1 == l2 and r1[1] == r2[3]
                  and r1[0] == r2[0] and r1[2] == r2[2])
        if not ok:
            fail(f"A2 {what} {out_pin}->{in_pin}: {l1}{r1} vs {l2}{r2}")

    for r in range(args.rows):
        for c in range(args.cols - 1):
            if (r, c) in grid and (r, c + 1) in grid:
                for o, i in we_pairs:
                    check_pair(grid[(r, c)], grid[(r, c + 1)], o, i,
                               f"({r},{c})->E")
    for r in range(args.rows - 1):
        for c in range(args.cols):
            # row r is NORTH of row r+1 when y grows upward and row 0 is
            # the bottom; drain chains south: r+1 (above) feeds r (below)
            if (r, c) in grid and (r + 1, c) in grid:
                for o, i in ns_pairs:
                    check_pair(grid[(r + 1, c)], grid[(r, c)], o, i,
                               f"({r + 1},{c})->S")

    n_inst = args.rows * args.cols
    n_checks = ((args.cols - 1) * args.rows * len(we_pairs)
                + (args.rows - 1) * args.cols * len(ns_pairs))
    if fails:
        print(f"\n{fails} abutment violations "
              f"({n_inst} tiles, {n_checks} pin checks)")
        sys.exit(1)
    print(f"ABUTMENT OK — {n_inst} tiles exact-grid, "
          f"{n_checks} abutted pin pairs coordinate-exact, "
          f"outline pitch-integral")


if __name__ == "__main__":
    main()
