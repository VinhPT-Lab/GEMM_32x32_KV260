# KLayout batch script (klayout -b -r) of tools/magic_macro_check.sh:
# reads the full GDS once and writes every window of windows.json as its own
# top cell gemm_clip_<n> into one small GDS.
# env: GEMM_GDS, GEMM_TOP, GEMM_WORK
import json
import os
import time

import pya

t = time.time()
work = os.environ["GEMM_WORK"]
wins = json.load(open(os.path.join(work, "windows.json")))["windows"]
ly = pya.Layout()
ly.read(os.environ["GEMM_GDS"])
top = ly.cell(os.environ["GEMM_TOP"])
print("  GDS read in %.0f s (%d cells)" % (time.time() - t, ly.cells()))
opt = pya.SaveLayoutOptions()
for w in wins:
    ci = ly.clip(top.cell_index(), pya.DBox(*w["box"]).to_itype(ly.dbu))
    ly.rename_cell(ci, "gemm_clip_%d" % w["n"])
    opt.add_cell(ci)
ly.write(os.path.join(work, "clips.gds"), opt)
print("  %d windows clipped into clips.gds in %.0f s" % (len(wins), time.time() - t))
