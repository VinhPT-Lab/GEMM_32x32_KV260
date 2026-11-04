# Headless KLayout screenshots of the final GDS (KLayout 0.28 of the OpenLane 1.0.2 image).
# klayout -b -r klayout_shots.py -rd gds=<GEMM_top.gds> -rd lyp=<sky130A.lyp> -rd out=<dir>
# -rd only_shots=a,b to render some regions only.
# Regions (um, from the final DEF): whole chip; rows 0-2 (flat 32-PE row macros, power grid
# hidden); about one PE
# (the first 110 um of row 0 = 1/32 of its width; the row is flat, PE boundaries are not
# drawn); one SRAM macro; the ECO clock repeater eco_clk_20 and its neighbourhood.
import pya
lv = pya.LayoutView()
lv.set_config('background-color', '#ffffff')
lv.set_config('grid-visible', 'false')
lv.set_config('text-visible', 'false')
lv.load_layout(gds, True)
lv.load_layer_props(lyp)
cv = lv.active_cellview()
regions = [
    ('chip_full', None, 1, 1600, 2300),
    ('rows_0_2_no_met4_met5', pya.DBox(3747.16 - 10, 10327.84 - 2 * 155.04 - 10, 3747.16 + 3517.62 + 10, 10327.84 + 133.28 + 10), 99, 4000, 545),
    ('pe_about_one', pya.DBox(3747.16, 10327.84, 3747.16 + 110, 10327.84 + 133.28), 99, 1600, 1950),
    ('sram_macro', pya.DBox(2043.78 - 10, 9952.48 - 10, 2043.78 + 683.1 + 10, 9952.48 + 416.54 + 10), 99, 2000, 1250),
    ('eco_clk_20', pya.DBox(550.16 - 25, 6043.84 - 20, 550.16 + 25, 6043.84 + 22.72), 99, 1600, 1350),
]
sel = globals().get('only_shots', '')
for name, box, hier, w, h in regions:
    if sel and name not in sel.split(','): continue
    # the row strip hides the power grid (met4 71/x, met5 72/x, via4 71/44) to show the cells
    hide = name.endswith('no_met4_met5')
    it = lv.begin_layers()
    while not it.at_end():
        lp = it.current(); src = lp.source
        lp.visible = not (hide and (src.startswith('71/') or src.startswith('72/')))
        lv.set_layer_properties(it, lp); it.next()
    lv.min_hier_levels = 0
    lv.max_hier_levels = hier
    if box is None: lv.zoom_fit()
    else: lv.zoom_box(box)
    lv.save_image(f'{out}/{name}.png', w, h)
    print('SHOT', name, w, h)
