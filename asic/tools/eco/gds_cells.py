# F.3: cells of the final GDS: top cell(s), empty cells, abstract-only macros
import sys, pya
ly = pya.Layout(); ly.read(gds)
tops = [c.name for c in ly.top_cells()]
print('GDSCELLS top', tops, 'cells', ly.cells())
empty = [c.name for c in ly.each_cell() if c.is_empty() or (c.bbox().empty())]
print('GDSCELLS empty', len(empty), empty[:20])
want = ['sky130_sram_2kbyte_1rw1r_32x512_8', 'ProcessingElementRow', 'GemmAxiShell']
for w in want:
    ci = ly.cell_by_name(w) if ly.has_cell(w) else None
    if ci is None: print('GDSCELLS missing', w); continue
    c = ly.cell(ci)
    shapes = sum(c.shapes(li).size() for li in ly.layer_indices())
    print(f'GDSCELLS {w}: children {c.child_cells()}, own shapes {shapes}, bbox {c.dbbox()}, instances in top {ly.top_cell().dbbox() and sum(1 for i in ly.top_cell().each_inst() if i.cell_index == ci)}')
