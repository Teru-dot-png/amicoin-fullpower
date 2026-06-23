#!/usr/bin/env python3
"""Decimate fan_frames.lua: keep every other frame, delete the rest.

Does ONE thing: reads the baked frames, keeps frames 0,2,4,... (drops 1,3,5,...),
and rewrites the file. Halves the frame count each run. Does NOT touch the
generator or re-simulate anything.

Usage:
  python3 tools/decimate_fan_frames.py                 # edit the default file
  python3 tools/decimate_fan_frames.py path/to/fan_frames.lua
  python3 tools/decimate_fan_frames.py --keep-odd      # keep 1,3,5,... instead
  python3 tools/decimate_fan_frames.py --dry-run       # show result, don't write
"""
import sys
import re
import os

DEFAULT_PATH = os.path.join(
    os.path.dirname(__file__), "..", "ami", "lib", "ui", "widgets", "fan_frames.lua"
)


def main():
    args = sys.argv[1:]
    keep_odd = "--keep-odd" in args
    dry = "--dry-run" in args
    paths = [a for a in args if a.endswith(".lua")]
    path = paths[0] if paths else DEFAULT_PATH

    with open(path, "r") as fh:
        text = fh.read()

    # Split into: header (up to and including "frames = {"), the frame blocks,
    # and the footer (the closing "  }," "}" lines).
    m = re.search(r"frames\s*=\s*\{", text)
    if not m:
        print("ERROR: could not find 'frames = {' in", path)
        sys.exit(1)
    head = text[: m.end()]
    rest = text[m.end():]

    # Each frame block is `    {  ... rows ... },` -- match brace-balanced groups.
    blocks = []
    depth = 0
    start = None
    for i, ch in enumerate(rest):
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and start is not None:
                blocks.append(rest[start:i + 1])
                start = None
            elif depth < 0:
                # this is the closing brace of the outer frames table
                footer_start = i - 1  # back up to the leading "  },"/whitespace
                break

    # Footer = everything from the frames-table closer onward.
    last_block_end = rest.rfind(blocks[-1]) + len(blocks[-1]) if blocks else 0
    footer = rest[last_block_end:]

    total = len(blocks)
    kept = blocks[1::2] if keep_odd else blocks[0::2]
    print(f"{path}: {total} frames -> {len(kept)} (keeping {'odd' if keep_odd else 'even'} indices)")

    # Reassemble. Each captured block is a brace-balanced "{...}" WITHOUT its
    # trailing comma, so re-add ",\n" between/after frames to keep valid Lua.
    # The footer begins right after the last block's "}", i.e. with that block's
    # stray ",", so strip any leading comma/whitespace before the table closers.
    new_frames = "\n" + "".join("    " + b.strip() + ",\n" for b in kept)
    footer = footer.lstrip(", \t\r\n")
    new_text = head + new_frames + "  " + footer

    if dry:
        print("--- dry run, not writing ---")
        return

    with open(path, "w") as fh:
        fh.write(new_text)
    print("Wrote", path)


if __name__ == "__main__":
    main()
