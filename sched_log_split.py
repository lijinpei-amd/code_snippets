#!/usr/bin/env python3
"""Split a file into multiple files based on a regex pattern."""

import argparse
import re
import os
import sys


def main():
    parser = argparse.ArgumentParser(
        description="Split a file into multiple files at lines matching a regex."
    )
    parser.add_argument("input_file", help="Path to the input file")
    parser.add_argument("regex", help="Regex pattern to split on")
    parser.add_argument(
        "-o", "--output-dir", default=".", help="Output directory (default: current directory)"
    )
    args = parser.parse_args()

    if not os.path.isfile(args.input_file):
        print(f"Error: '{args.input_file}' not found", file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.output_dir, exist_ok=True)

    pattern = re.compile(args.regex)
    base, ext = os.path.splitext(os.path.basename(args.input_file))

    chunk_index = 0
    out_file = None

    def open_next_chunk():
        nonlocal chunk_index
        chunk_index += 1
        out_name = f"{base}_{chunk_index}{ext}"
        out_path = os.path.join(args.output_dir, out_name)
        print(out_path)
        return open(out_path, "w")

    try:
        with open(args.input_file, "r") as f:
            for line in f:
                if pattern.search(line):
                    if out_file:
                        out_file.close()
                    out_file = open_next_chunk()
                elif out_file is None:
                    out_file = open_next_chunk()
                out_file.write(line)
    finally:
        if out_file:
            out_file.close()

    if chunk_index == 0:
        print("No splits found; nothing written.", file=sys.stderr)
    else:
        print(f"Split into {chunk_index} file(s).", file=sys.stderr)


if __name__ == "__main__":
    main()
