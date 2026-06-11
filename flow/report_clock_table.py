#!/usr/bin/env python3
"""PtahCore — per-tile clock-arrival table (the traveling-clock honesty
check, ARRAY_SPEC §2 / HARDENING.md false-clean trap).

After the clk-arc lib patch, STA propagates the clock tile-to-tile
through the chain; this script PROVES it by reporting the capture-clock
arrival at each sampled tile's clk_in (via the propagated clock network
delay in a report_checks to that tile's en_in endpoint). Arrival must
grow monotonically ~δe per column (and ~δs per row in the 2D grid) and
never be 0 past tile 0 — a flat or zero arrival means tiles are
silently unconstrained and every signoff number is fiction.

Runs OpenSTA inside the ORFS docker image against the routed odb:

  python3 flow/report_clock_table.py --design mac_row_abut --cols 32
  python3 flow/report_clock_table.py --design mac_grid --cols 32 --rows 32

Samples corners/edges/diagonal for grids (full 1024 would be slow);
--all forces every tile. Exits non-zero if any sampled arrival is
non-monotonic along its axis or missing.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def tile_insts(rows, cols, sample_all):
    if rows == 1:
        return [(0, c, f"col\\[{c}\\].u_tile") for c in range(cols)]
    idx = (sorted({0, 1, rows // 2, rows - 2, rows - 1})
           if not sample_all else list(range(rows)))
    out = []
    for r in idx:
        cs = (sorted({0, 1, cols // 2, cols - 2, cols - 1})
              if not sample_all else list(range(cols)))
        for c in cs:
            out.append((r, c, f"row\\[{r}\\].col\\[{c}\\].u_tile"))
    # the main diagonal exercises both axes together
    for d in range(min(rows, cols)):
        t = (d, d, f"row\\[{d}\\].col\\[{d}\\].u_tile")
        if t not in out:
            out.append(t)
    return out


def make_tcl(design, lib, insts):
    odb = f"/work/flow/results/asap7/{design}/base/6_final.odb"
    sdc = f"/work/flow/results/asap7/{design}/base/6_final.sdc"
    spef = f"/work/flow/results/asap7/{design}/base/6_final.spef"
    pdk = "/OpenROAD-flow-scripts/flow/platforms/asap7"
    tcl = [
        f"read_db {odb}",
        f"read_liberty {lib}",
        # NLDM filenames carry mixed dates (and SEQ is ungzipped) — glob
        f"foreach f [glob {pdk}/lib/NLDM/asap7sc7p5t_*_RVT_TT_nldm_*.lib*]"
        " { read_liberty $f }",
    ]
    tcl += [
        f"read_sdc {sdc}",
        f"read_spef {spef}",
        "set_propagated_clock [all_clocks]",
    ]
    for r, c, inst in insts:
        tcl += [
            f'puts "TILE {r} {c}"',
            f'report_checks -path_delay max -to "{inst}/en_in" '
            f'-format full_clock_expanded -fields {{}} -digits 2',
        ]
    tcl.append("exit")
    return "\n".join(tcl)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--design", required=True)
    ap.add_argument("--block", default=None,
                    help="block nickname (default <design>_mac_tile)")
    ap.add_argument("--cols", type=int, required=True)
    ap.add_argument("--rows", type=int, default=1)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--image", default="openroad/orfs:latest")
    args = ap.parse_args()

    block = args.block or f"{args.design}_mac_tile"
    lib = f"/work/flow/results/asap7/{block}/base/mac_tile_typ.lib"
    insts = tile_insts(args.rows, args.cols, args.all)
    tcl = make_tcl(args.design, lib, insts)
    # /tmp, not flow/objects — the flow dirs are root-owned by docker
    tclf = Path("/tmp/ptahcore_clock_table.tcl")
    tclf.write_text(tcl + "\n")

    res = subprocess.run(
        ["docker", "run", "--rm", "-v", f"{REPO}:/work",
         "-v", f"{tclf}:/clock_table.tcl", args.image,
         "bash", "-lc",
         "source /OpenROAD-flow-scripts/env.sh >/dev/null 2>&1 || true; "
         "openroad -no_init -exit /clock_table.tcl"],
        capture_output=True, text=True)
    out = res.stdout

    # capture-clock arrival = last "clock network delay (propagated)" +
    # its preceding clock edge/source line inside each TILE section
    arrivals = {}
    for sec in re.split(r"TILE (\d+) (\d+)\n", out)[1:][::1]:
        pass
    parts = re.split(r"TILE (\d+) (\d+)\n", out)
    for i in range(1, len(parts) - 2, 3):
        r, c, body = int(parts[i]), int(parts[i + 1]), parts[i + 2]
        # the CAPTURE clock section is the second "clock ..." block;
        # its arrival is the accumulated time on the capture clk_in line
        m = re.findall(r"([\d.]+)\s+([\d.]+) [v^] .*u_tile/clk_in", body)
        if m:
            arrivals[(r, c)] = float(m[-1][1])
    fails = 0
    print(f"{'tile':>10s} {'clk arrival (ps)':>18s} {'Δ prev col':>12s}")
    prev_by_row = {}
    for (r, c) in sorted(arrivals):
        a = arrivals[(r, c)]
        d = a - prev_by_row[r] if r in prev_by_row else 0.0
        prev_by_row[r] = a
        flag = ""
        if c > 0 and d <= 0:
            flag = "  NON-MONOTONIC"
            fails += 1
        print(f"({r:3d},{c:3d}) {a:18.2f} {d:12.2f}{flag}")
    missing = [t[:2] for t in insts if t[:2] not in arrivals]
    if missing:
        print(f"MISSING arrivals (unconstrained?): {missing}")
        fails += 1
    if fails:
        print(f"\nCLOCK TABLE FAIL — {fails} problems")
        sys.exit(1)
    print(f"\nCLOCK TABLE OK — {len(arrivals)} tiles, arrival grows "
          "monotonically (traveling clock STA-visible)")


if __name__ == "__main__":
    main()
