#!/usr/bin/env python3
"""Animated previewer for the baked AmiCoin fan (fan_frames.lua).

Plays the pre-rendered teletext frames in your terminal using Unicode block
characters, so you can SEE the spin (speed, smoothness, direction) without
booting Minecraft. Each CC teletext code 128-159 maps to a 2x3 sextant; we
render the 5 directly-addressable sub-pixels (BR omitted, exactly like the bake).

Usage:
  python3 fan_visualizer.py                       # loop the default frames file
  python3 fan_visualizer.py --fps 8               # set playback speed
  python3 fan_visualizer.py --once                # play one loop then stop
  python3 fan_visualizer.py path/to/fan_frames.lua
  python3 fan_visualizer.py --grid                # show all frames side by side (no animation)

Ctrl+C to quit.
"""
import sys
import re
import time
import os

DEFAULT_PATH = os.path.join(
    os.path.dirname(__file__), "..", "ami", "lib", "ui", "widgets", "fan_frames.lua"
)

# CC teletext sub-pixel bits (relative to code-128):
#   TL=1 TR=2 ML=4 MR=8 BL=16   (BR is via colour-swap, not a code bit)
# We draw each char cell as a 2-wide x 3-tall block of half-density Unicode.
FILL = "\u2588"   # full block
EMPTY = " "


def parse_frames(path):
    with open(path, "r") as fh:
        data = fh.read()
    cols = int(re.search(r"cols\s*=\s*(\d+)", data).group(1))
    rows = int(re.search(r"rows\s*=\s*(\d+)", data).group(1))
    blocks = re.findall(r"\{\s*((?:\s*\"[^\"]*\",)+)\s*\},", data)
    frames = []
    for b in blocks:
        rowstrs = re.findall(r'"([^"]*)"', b)
        frame = []
        for rs in rowstrs:
            codes = [int(x) for x in re.findall(r"\\(\d{3})", rs)]
            frame.append(codes)
        frames.append(frame)
    return frames, cols, rows


def code_to_subpixels(code):
    """Return the 2x3 boolean grid for a teletext code (or space)."""
    if code == 32 or code < 128 or code > 159:
        return [[False, False], [False, False], [False, False]]
    b = code - 128
    tl = bool(b & 1)
    tr = bool(b & 2)
    ml = bool(b & 4)
    mr = bool(b & 8)
    bl = bool(b & 16)
    br = False  # colour-swap pixel; not used in single-colour bake
    return [[tl, tr], [ml, mr], [bl, br]]


def render_frame(frame):
    """Render one frame (list of code-rows) into text lines at 2x3 sub-resolution."""
    out_lines = []
    for code_row in frame:
        # each char cell -> 3 sub-rows tall, 2 sub-cols wide
        sub = [[], [], []]
        for code in code_row:
            grid = code_to_subpixels(code)
            for sr in range(3):
                for sc in range(2):
                    sub[sr].append(FILL if grid[sr][sc] else EMPTY)
        for sr in range(3):
            out_lines.append("".join(sub[sr]))
    return out_lines


def clear():
    sys.stdout.write("\033[2J\033[H")


def main():
    args = sys.argv[1:]
    fps = 6.0
    once = "--once" in args
    grid = "--grid" in args
    if "--fps" in args:
        fps = float(args[args.index("--fps") + 1])
    paths = [a for a in args if a.endswith(".lua")]
    path = paths[0] if paths else DEFAULT_PATH

    frames, cols, rows = parse_frames(path)
    print(f"Loaded {len(frames)} frames ({cols}x{rows} chars) from {path}")
    time.sleep(0.8)

    if grid:
        # render all frames stacked with separators (good for a static look)
        for i, fr in enumerate(frames):
            print(f"\n--- frame {i} ---")
            for line in render_frame(fr):
                print(line)
        return

    cyan = "\033[96m"
    reset = "\033[0m"
    try:
        loops = 0
        while True:
            for i, fr in enumerate(frames):
                clear()
                print(f"{cyan}AmiCoin fan  |  frame {i+1}/{len(frames)}  |  {fps:.0f} fps  |  Ctrl+C quit{reset}\n")
                for line in render_frame(fr):
                    print(cyan + line + reset)
                time.sleep(1.0 / fps)
            loops += 1
            if once and loops >= 1:
                break
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
