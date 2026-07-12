#!/usr/bin/env python3
"""Decode llvm.amdgcn.s.waitcnt i32 immediates into VMCNT/EXPCNT/LGKMCNT."""

import argparse


I32_MIN = -(1 << 31)
I32_MAX = (1 << 31) - 1
U32_MAX = (1 << 32) - 1


# Bit-field layouts per GFX generation, derived from AMDGPUBaseInfo.cpp
# Each entry: (shift, width)
LAYOUTS = {
    "gfx6": {  # also gfx7, gfx8
        "vmcnt_lo": (0, 4),
        "expcnt":   (4, 3),
        "lgkmcnt":  (8, 4),
        "vmcnt_hi": (14, 0),  # width 0 → no high bits
    },
    "gfx9": {
        "vmcnt_lo": (0, 4),
        "expcnt":   (4, 3),
        "lgkmcnt":  (8, 4),
        "vmcnt_hi": (14, 2),
    },
    "gfx10": {
        "vmcnt_lo": (0, 4),
        "expcnt":   (4, 3),
        "lgkmcnt":  (8, 6),
        "vmcnt_hi": (14, 2),
    },
    "gfx11": {  # also gfx12
        "expcnt":   (0, 3),
        "lgkmcnt":  (4, 6),
        "vmcnt_lo": (10, 6),
        "vmcnt_hi": (0, 0),  # no high bits, vmcnt is contiguous
    },
}

# Aliases
LAYOUTS["gfx7"] = LAYOUTS["gfx6"]
LAYOUTS["gfx8"] = LAYOUTS["gfx6"]
LAYOUTS["gfx12"] = LAYOUTS["gfx11"]


def extract_field(imm16, shift, width):
    if width == 0:
        return 0
    return (imm16 >> shift) & ((1 << width) - 1)


def max_field(width):
    if width == 0:
        return 0
    return (1 << width) - 1


def decode_waitcnt(imm, gfx):
    if isinstance(imm, bool) or not isinstance(imm, int):
        raise TypeError("waitcnt immediate must be an integer")
    if not I32_MIN <= imm <= U32_MAX:
        raise ValueError(
            f"waitcnt immediate must fit an i32 ({I32_MIN}..{I32_MAX}) "
            f"or a 32-bit hexadecimal bit pattern (0x0..0x{U32_MAX:X})"
        )
    layout = LAYOUTS[gfx]
    imm16 = imm & 0xFFFF

    vmcnt_lo_shift, vmcnt_lo_width = layout["vmcnt_lo"]
    vmcnt_hi_shift, vmcnt_hi_width = layout["vmcnt_hi"]
    expcnt_shift, expcnt_width = layout["expcnt"]
    lgkmcnt_shift, lgkmcnt_width = layout["lgkmcnt"]

    vmcnt_lo = extract_field(imm16, vmcnt_lo_shift, vmcnt_lo_width)
    vmcnt_hi = extract_field(imm16, vmcnt_hi_shift, vmcnt_hi_width)
    vmcnt = vmcnt_lo | (vmcnt_hi << vmcnt_lo_width)

    expcnt = extract_field(imm16, expcnt_shift, expcnt_width)
    lgkmcnt = extract_field(imm16, lgkmcnt_shift, lgkmcnt_width)

    vmcnt_max = max_field(vmcnt_lo_width + vmcnt_hi_width)
    expcnt_max = max_field(expcnt_width)
    lgkmcnt_max = max_field(lgkmcnt_width)

    return {
        "vmcnt":  (vmcnt, vmcnt_max),
        "expcnt": (expcnt, expcnt_max),
        "lgkmcnt": (lgkmcnt, lgkmcnt_max),
    }


def format_result(imm, gfx):
    results = decode_waitcnt(imm, gfx)
    imm16 = imm & 0xFFFF

    parts = []
    for name in ("vmcnt", "expcnt", "lgkmcnt"):
        val, mx = results[name]
        if val < mx:
            parts.append(f"{name}({val})")

    asm = "s_waitcnt " + " ".join(parts) if parts else "s_waitcnt  (no wait — all counters at max)"

    lines = [
        f"  Input:    {imm} (0x{imm & 0xFFFFFFFF:08X}, low16 = 0x{imm16:04X})",
        f"  Target:   {gfx}",
    ]
    for name in ("vmcnt", "expcnt", "lgkmcnt"):
        val, mx = results[name]
        wait = " \u2190 wait" if val < mx else ""
        lines.append(f"  {name.upper()+':':<10}{val}  (max={mx}){wait}")
    lines.append(f"  Assembly:  {asm}")
    return "\n".join(lines)


def parse_imm(s):
    s = s.strip().rstrip(",")
    is_hex = s.startswith(("0x", "0X"))
    try:
        value = int(s, 16 if is_hex else 10)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"invalid i32 immediate: {s!r}") from error

    minimum, maximum = (0, U32_MAX) if is_hex else (I32_MIN, I32_MAX)
    if not minimum <= value <= maximum:
        domain = (
            "0x00000000..0xFFFFFFFF"
            if is_hex
            else f"{I32_MIN}..{I32_MAX}"
        )
        raise argparse.ArgumentTypeError(
            f"i32 immediate {s!r} is outside the accepted range {domain}"
        )
    return value


def main():
    parser = argparse.ArgumentParser(
        description="Decode llvm.amdgcn.s.waitcnt i32 immediates",
        epilog="Examples:\n"
               "  %(prog)s -49168 49279\n"
               "  %(prog)s --gfx gfx10 0x3FF0\n"
               "  %(prog)s --gfx gfx11 0xFC07",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "immediates",
        nargs="+",
        type=parse_imm,
        help=(
            "i32 immediate values (signed decimal, or an unsigned 32-bit "
            "0x hexadecimal bit pattern)"
        ),
    )
    parser.add_argument("--gfx", default="gfx9",
                        choices=sorted(LAYOUTS.keys()),
                        help="target GFX generation (default: gfx9)")
    args = parser.parse_args()

    for i, imm in enumerate(args.immediates):
        if i > 0:
            print()
        print(format_result(imm, args.gfx))


if __name__ == "__main__":
    main()
