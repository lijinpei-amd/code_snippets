#!/usr/bin/env python3
"""Split LLVM/MLIR IR dump logs into one file per pass."""

import argparse
import os
import re
import sys

# LLVM new PM:    ; *** IR Dump After PassName on [module] ***
# LLVM legacy PM:   *** IR Dump After Human Name (slug) ***
# MLIR:           // -----// IR Dump Before PassName (slug) ('builtin.module' operation) //----- //
LLVM_HEADER_RE = re.compile(r"^;? ?\*\*\* IR Dump (After|Before) (.+?) \*\*\*")
MLIR_HEADER_RE = re.compile(r"^// -+// IR Dump (After|Before) (.+?) //-+ //")
TEMPLATE_RE = re.compile(r"<.*?>")
NON_ALNUM_RE = re.compile(r"[^A-Za-z0-9]+")
SLUG_RE = re.compile(r"\(([^)]+)\)")
ON_SPLIT_RE = re.compile(r" on ")


def sanitize(name: str) -> str:
    """Turn a pass name into a safe, short filename component."""
    # Legacy/MLIR: "Human Name (slug) ..." -> use first parenthesized slug
    slug = SLUG_RE.search(name)
    if slug:
        name = slug.group(1)
    else:
        # New PM: "PassName on [module]" -> strip "on ..." suffix
        name = ON_SPLIT_RE.split(name, maxsplit=1)[0]
    name = TEMPLATE_RE.sub("", name)
    name = NON_ALNUM_RE.sub("_", name).strip("_")
    return name or "unknown"


def main():
    ap = argparse.ArgumentParser(description="Split LLVM/MLIR IR dump logs into per-pass files.")
    ap.add_argument("input", help="Input IR dump log file (use - for stdin)")
    ap.add_argument("-o", "--output", required=True, help="Output directory")
    args = ap.parse_args()

    os.makedirs(args.output, exist_ok=True)

    inp = sys.stdin if args.input == "-" else open(args.input, "r")

    index_lines = []
    cur_file = None
    # For "Before" dumps: the content under "Before pass-N" is the state
    # after pass-(N-1) completed, so we shift names by one and rewrite
    # the header from "Before pass-N" to "After pass-(N-1)".
    pending_name = None
    prev_header = None

    try:
        for line in inp:
            if line and line[0] in ";*/":
                m = LLVM_HEADER_RE.match(line) or MLIR_HEADER_RE.match(line)
            else:
                m = None
            if m:
                if cur_file is not None:
                    cur_file.close()

                direction = m.group(1)
                pass_info = m.group(2)
                ext = ".mlir" if line.startswith("//") else ".ll"

                if direction == "Before":
                    if pending_name is None:
                        pending_name = "initial"
                        index_header = "Initial"
                    else:
                        index_header = prev_header.replace("Before", "After", 1)
                    short = pending_name
                    pending_name = sanitize(pass_info)
                    prev_header = line.rstrip()
                    write_header = False
                else:
                    short = sanitize(pass_info)
                    index_header = line.rstrip()
                    write_header = True

                n = len(index_lines)
                fname = f"{n:04d}_{short}{ext}"
                index_lines.append((fname, index_header))
                cur_file = open(os.path.join(args.output, fname), "w")
                if write_header:
                    cur_file.write(line)
            elif cur_file is not None:
                cur_file.write(line)
    finally:
        if cur_file is not None:
            cur_file.close()
        if inp is not sys.stdin:
            inp.close()

    with open(os.path.join(args.output, "index.txt"), "w") as f:
        for num, (fname, header) in enumerate(index_lines):
            f.write(f"{num:4d}  {fname}  {header}\n")

    print(f"Split into {len(index_lines)} files in {args.output}/", file=sys.stderr)


if __name__ == "__main__":
    main()
