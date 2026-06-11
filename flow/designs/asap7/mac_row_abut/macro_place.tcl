# PtahCore -- abutted traveling-clock row (Phase 7b-3).
#
# 32 mac_tile macros at EXACTLY the tile width (46.656 um), zero gap:
# every east-edge pin of tile j is coordinate-coincident with the
# matching west-edge pin of tile j+1 (the tile's mirrored-pin contract,
# verified in 7b-2). Tile width and these x-coordinates are all
# multiples of 0.432 um = lcm(site, M1/M3/M5 pitches), so place_macro's
# track snapping is a no-op -- the first 46.44 um tile flipped track
# phase every tile (+24 nm snap) and abutment became overlap (MPL-0041).
# The clock enters tile 0 and travels the chain through each tile's
# clk_in->clk_out feedthrough -- no row CTS.

place_macro -macro_name {col\[0\].u_tile} -location {2.160 12.96} -orientation R0
place_macro -macro_name {col\[1\].u_tile} -location {48.816 12.96} -orientation R0
place_macro -macro_name {col\[2\].u_tile} -location {95.472 12.96} -orientation R0
place_macro -macro_name {col\[3\].u_tile} -location {142.128 12.96} -orientation R0
place_macro -macro_name {col\[4\].u_tile} -location {188.784 12.96} -orientation R0
place_macro -macro_name {col\[5\].u_tile} -location {235.440 12.96} -orientation R0
place_macro -macro_name {col\[6\].u_tile} -location {282.096 12.96} -orientation R0
place_macro -macro_name {col\[7\].u_tile} -location {328.752 12.96} -orientation R0
place_macro -macro_name {col\[8\].u_tile} -location {375.408 12.96} -orientation R0
place_macro -macro_name {col\[9\].u_tile} -location {422.064 12.96} -orientation R0
place_macro -macro_name {col\[10\].u_tile} -location {468.720 12.96} -orientation R0
place_macro -macro_name {col\[11\].u_tile} -location {515.376 12.96} -orientation R0
place_macro -macro_name {col\[12\].u_tile} -location {562.032 12.96} -orientation R0
place_macro -macro_name {col\[13\].u_tile} -location {608.688 12.96} -orientation R0
place_macro -macro_name {col\[14\].u_tile} -location {655.344 12.96} -orientation R0
place_macro -macro_name {col\[15\].u_tile} -location {702.000 12.96} -orientation R0
place_macro -macro_name {col\[16\].u_tile} -location {748.656 12.96} -orientation R0
place_macro -macro_name {col\[17\].u_tile} -location {795.312 12.96} -orientation R0
place_macro -macro_name {col\[18\].u_tile} -location {841.968 12.96} -orientation R0
place_macro -macro_name {col\[19\].u_tile} -location {888.624 12.96} -orientation R0
place_macro -macro_name {col\[20\].u_tile} -location {935.280 12.96} -orientation R0
place_macro -macro_name {col\[21\].u_tile} -location {981.936 12.96} -orientation R0
place_macro -macro_name {col\[22\].u_tile} -location {1028.592 12.96} -orientation R0
place_macro -macro_name {col\[23\].u_tile} -location {1075.248 12.96} -orientation R0
place_macro -macro_name {col\[24\].u_tile} -location {1121.904 12.96} -orientation R0
place_macro -macro_name {col\[25\].u_tile} -location {1168.560 12.96} -orientation R0
place_macro -macro_name {col\[26\].u_tile} -location {1215.216 12.96} -orientation R0
place_macro -macro_name {col\[27\].u_tile} -location {1261.872 12.96} -orientation R0
place_macro -macro_name {col\[28\].u_tile} -location {1308.528 12.96} -orientation R0
place_macro -macro_name {col\[29\].u_tile} -location {1355.184 12.96} -orientation R0
place_macro -macro_name {col\[30\].u_tile} -location {1401.840 12.96} -orientation R0
place_macro -macro_name {col\[31\].u_tile} -location {1448.496 12.96} -orientation R0
