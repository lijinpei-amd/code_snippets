#!/usr/bin/env python3
"""Strip `loc(...)` annotations from MLIR / TTGIR text.

Removes both top-level location definitions (`#loc<N> = loc(...)`) and inline
location annotations (`... loc(#loc1)`) while balancing parentheses and
ignoring content inside string literals.

Usage:
    python strip_mlir_loc.py input.ttgir              # write to stdout
    python strip_mlir_loc.py input.ttgir -o out.ttgir # write to file
    python strip_mlir_loc.py input.ttgir -i           # rewrite in place
    cat input.ttgir | python strip_mlir_loc.py -      # read from stdin
"""
import argparse
import sys

LOC = 'loc('


def _scan_string(text, i):
    """Advance past a "..."-delimited string starting at text[i] == '"'."""
    n = len(text)
    i += 1
    while i < n:
        c = text[i]
        if c == '\\' and i + 1 < n:
            i += 2
            continue
        if c == '"':
            return i + 1
        i += 1
    return i


def _find_loc_spans(text):
    """Return [(start, end), ...] for every top-level `loc(...)` occurrence."""
    n = len(text)
    i = 0
    spans = []
    while i < n:
        c = text[i]
        if c == '"':
            i = _scan_string(text, i)
            continue
        # Cheap prefix test first; word-boundary check only on the rare hit.
        if text.startswith(LOC, i) and (
            i == 0 or not (text[i - 1].isalnum() or text[i - 1] == '_')
        ):
            start = i
            j = i + len(LOC)
            depth = 1
            while j < n and depth > 0:
                cj = text[j]
                if cj == '"':
                    j = _scan_string(text, j)
                    continue
                if cj == '(':
                    depth += 1
                elif cj == ')':
                    depth -= 1
                j += 1
            spans.append((start, j))
            i = j
        else:
            i += 1
    return spans


def strip_loc(text):
    pieces = []
    last = 0
    for s, e in _find_loc_spans(text):
        # If this span is a `#loc<N> = loc(...)` declaration on its own line,
        # drop the whole line so no orphan `#loc<N> =` remains.
        line_start = text.rfind('\n', 0, s) + 1
        prefix = text[line_start:s]
        if (
            prefix.lstrip().startswith('#loc')
            and prefix.rstrip().endswith('=')
            and text.find('\n', e) != -1
            and text[e:text.find('\n', e)].strip() == ''
        ):
            line_end = text.find('\n', e) + 1
            pieces.append(text[last:line_start])
            last = line_end
            continue
        pieces.append(text[last:s].rstrip(' \t'))
        last = e
    pieces.append(text[last:])
    return ''.join(pieces)


def main():
    ap = argparse.ArgumentParser(
        description='Strip loc(...) annotations from MLIR / TTGIR.'
    )
    ap.add_argument('input', help='Input MLIR file (- for stdin)')
    sink = ap.add_mutually_exclusive_group()
    sink.add_argument('-o', '--output', help='Output file (default: stdout)')
    sink.add_argument('-i', '--in-place', action='store_true',
                      help='Rewrite the input file in place')
    args = ap.parse_args()

    if args.in_place and args.input == '-':
        ap.error('--in-place requires a file path, not stdin')

    if args.input == '-':
        text = sys.stdin.read()
    else:
        with open(args.input, encoding='utf-8') as f:
            text = f.read()

    result = strip_loc(text)

    if args.in_place:
        with open(args.input, 'w', encoding='utf-8') as f:
            f.write(result)
    elif args.output:
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(result)
    else:
        sys.stdout.write(result)


if __name__ == '__main__':
    main()
