# PtahCore -- mac_row manual macro placement (Phase 7a).
#
# 32 mac_cell macros on a regular pitch (TILE_SPEC: the array places
# tiles on a regular pitch), centered vertically (y=16.2 = 60 site rows)
# so DRT has a routing channel on BOTH sides of the macro pins -- flush
# against the core's south edge it had no channel below and detailed
# route never converged (466 stuck violations, then OOM).
# Replaces rtl_macro_placer, which found no valid tiling for a 1x32
# mixed cluster at this aspect ratio (MPL-0003) -- a heuristic limit,
# not a real constraint; the row layout is fully determined anyway.
# Instance names carry literal backslashes in the ODB (Yosys escaped
# identifiers survive verilog->db as-is).

place_macro -macro_name {col\[0\].u_cell} -location {3.654 16.2} -orientation R0
place_macro -macro_name {col\[1\].u_cell} -location {52.279 16.2} -orientation R0
place_macro -macro_name {col\[2\].u_cell} -location {100.904 16.2} -orientation R0
place_macro -macro_name {col\[3\].u_cell} -location {149.529 16.2} -orientation R0
place_macro -macro_name {col\[4\].u_cell} -location {198.154 16.2} -orientation R0
place_macro -macro_name {col\[5\].u_cell} -location {246.779 16.2} -orientation R0
place_macro -macro_name {col\[6\].u_cell} -location {295.404 16.2} -orientation R0
place_macro -macro_name {col\[7\].u_cell} -location {344.029 16.2} -orientation R0
place_macro -macro_name {col\[8\].u_cell} -location {392.654 16.2} -orientation R0
place_macro -macro_name {col\[9\].u_cell} -location {441.279 16.2} -orientation R0
place_macro -macro_name {col\[10\].u_cell} -location {489.904 16.2} -orientation R0
place_macro -macro_name {col\[11\].u_cell} -location {538.529 16.2} -orientation R0
place_macro -macro_name {col\[12\].u_cell} -location {587.154 16.2} -orientation R0
place_macro -macro_name {col\[13\].u_cell} -location {635.779 16.2} -orientation R0
place_macro -macro_name {col\[14\].u_cell} -location {684.404 16.2} -orientation R0
place_macro -macro_name {col\[15\].u_cell} -location {733.029 16.2} -orientation R0
place_macro -macro_name {col\[16\].u_cell} -location {781.654 16.2} -orientation R0
place_macro -macro_name {col\[17\].u_cell} -location {830.279 16.2} -orientation R0
place_macro -macro_name {col\[18\].u_cell} -location {878.904 16.2} -orientation R0
place_macro -macro_name {col\[19\].u_cell} -location {927.529 16.2} -orientation R0
place_macro -macro_name {col\[20\].u_cell} -location {976.154 16.2} -orientation R0
place_macro -macro_name {col\[21\].u_cell} -location {1024.779 16.2} -orientation R0
place_macro -macro_name {col\[22\].u_cell} -location {1073.404 16.2} -orientation R0
place_macro -macro_name {col\[23\].u_cell} -location {1122.029 16.2} -orientation R0
place_macro -macro_name {col\[24\].u_cell} -location {1170.654 16.2} -orientation R0
place_macro -macro_name {col\[25\].u_cell} -location {1219.279 16.2} -orientation R0
place_macro -macro_name {col\[26\].u_cell} -location {1267.904 16.2} -orientation R0
place_macro -macro_name {col\[27\].u_cell} -location {1316.529 16.2} -orientation R0
place_macro -macro_name {col\[28\].u_cell} -location {1365.154 16.2} -orientation R0
place_macro -macro_name {col\[29\].u_cell} -location {1413.779 16.2} -orientation R0
place_macro -macro_name {col\[30\].u_cell} -location {1462.404 16.2} -orientation R0
place_macro -macro_name {col\[31\].u_cell} -location {1511.029 16.2} -orientation R0
