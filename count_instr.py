#!/usr/bin/env python3
"""Count instruction mnemonics in assembly read from standard input."""

import re
import sys
from collections import Counter
from collections.abc import Iterable


LABEL_RE = re.compile(r"^(?:[A-Za-z_.$][\w.$]*|\d+):")
MNEMONIC_RE = re.compile(r"[A-Za-z_][\w.]*")


def extract_mnemonic(line: str) -> str | None:
    """Return the instruction mnemonic from an assembly line, if present."""
    text = line.strip()

    # A line can contain one or more labels before an instruction.  Removing
    # only the labels preserves an instruction written on the same line.
    while match := LABEL_RE.match(text):
        text = text[match.end() :].lstrip()

    if not text or text.startswith(("#", ";", ".")):
        return None

    match = MNEMONIC_RE.match(text)
    if match is None:
        return None
    return match.group(0).removesuffix("_e32").removesuffix("_e64")


def count_instructions(lines: Iterable[str]) -> Counter[str]:
    counts: Counter[str] = Counter()
    for line in lines:
        if line.strip() == "---":
            break
        if mnemonic := extract_mnemonic(line):
            counts[mnemonic] += 1
    return counts


def main() -> None:
    for mnemonic, count in sorted(count_instructions(sys.stdin).items()):
        print(mnemonic, count)


if __name__ == "__main__":
    main()
