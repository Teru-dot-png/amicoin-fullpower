#!/usr/bin/env python3
"""CC:Tweaked glyph reference tool.

Decodes the real CC:Tweaked font bitmap (term_font.png, 256x256, a 16x16 grid of
16x16px cells) and renders any byte 0-255 as ASCII art, so we can see EXACTLY
what ComputerCraft draws for each character code. CC's font is NOT CP437 - the
block/box characters live at different code points - so this is the ground truth
for picking glyphs.

Usage:
  python3 decode_font.py                 # render all 256 glyphs
  python3 decode_font.py 159 219 176     # render specific codes (decimal)
  python3 decode_font.py --find-solid    # list codes whose glyph is mostly/fully filled
  python3 decode_font.py --teletext      # show the 128-159 teletext block range
  python3 decode_font.py --lua           # emit a Lua table of {code -> fill ratio}

Font path: term_font.png in CWD (downloaded from cc-tweaked/CC-Tweaked).
"""
import sys
from PIL import Image

FONT = "term_font.png"
# Exact geometry from CC:Tweaked FixedWidthFontRenderer.java:
#   FONT_WIDTH = 6, FONT_HEIGHT = 9
#   column = code % 16 ; row = code // 16
#   xStart = 1 + column * (FONT_WIDTH + 2)   # pitch 8
#   yStart = 1 + row    * (FONT_HEIGHT + 2)  # pitch 11
GW, GH = 6, 9
PITCH_X, PITCH_Y = 8, 11


def load_cells():
    img = Image.open(FONT).convert("RGBA")
    px = img.load()
    cells = {}
    for code in range(256):
        col = code % 16
        row = code // 16
        xs = 1 + col * PITCH_X
        ys = 1 + row * PITCH_Y
        grid = []
        for y in range(GH):
            r = []
            for x in range(GW):
                pr, pg, pb, pa = px[xs + x, ys + y]
                r.append(pa > 64 and (pr + pg + pb) > 96)
            grid.append(r)
        cells[code] = grid
    return cells


def crop(grid):
    """Trim fully-empty border rows/cols for a tight glyph view."""
    rows = [i for i, r in enumerate(grid) if any(r)]
    cols = [j for j in range(len(grid[0])) if any(grid[i][j] for i in range(len(grid)))]
    if not rows or not cols:
        return [[False]]
    r0, r1, c0, c1 = rows[0], rows[-1], cols[0], cols[-1]
    return [row[c0:c1 + 1] for row in grid[r0:r1 + 1]]


def fill_ratio(grid):
    total = sum(len(r) for r in grid)
    on = sum(sum(1 for c in r if c) for r in grid)
    return on / total if total else 0.0


def render(code, grid, tight=True):
    g = crop(grid) if tight else grid
    art = "\n".join("".join("#" if c else "." for c in row) for row in g)
    name = chr(code) if 32 <= code < 127 else ""
    print(f"=== code {code} (0x{code:02X}) {('ASCII '+repr(name)) if name else ''}  fill={fill_ratio(grid):.2f} ===")
    print(art)
    print()


def main():
    cells = load_cells()
    args = sys.argv[1:]

    if "--find-solid" in args:
        solids = sorted(((fill_ratio(g), code) for code, g in cells.items()), reverse=True)
        print("Most-filled glyph codes (code: fill ratio):")
        for ratio, code in solids[:24]:
            print(f"  {code:3d} (0x{code:02X}): {ratio:.2f}")
        return

    if "--teletext" in args:
        for code in range(128, 160):
            render(code, cells[code], tight=False)
        return

    if "--lua" in args:
        print("-- AUTO: fill ratio per CC font code (0=empty .. 1=solid)")
        print("return {")
        for code in range(256):
            print(f"  [{code}] = {fill_ratio(cells[code]):.3f},")
        print("}")
        return

    codes = [int(a) for a in args if a.isdigit()]
    if not codes:
        codes = range(256)
    for code in codes:
        render(code, cells[code])


if __name__ == "__main__":
    main()
