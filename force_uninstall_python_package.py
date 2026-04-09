#!/usr/bin/env python3
"""Forcefully uninstall a Python package, removing leftover files if uv can't."""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def force_uninstall(pkg, python, max_attempts):
    print(f"Using python: {python}")
    print(f"Using uv:     uv pip uninstall --python {python}")

    prev_pkg_path = None
    attempt = 0
    while max_attempts is None or attempt < max_attempts:
        attempt += 1

        # After attempt 1, uv's metadata is gone (we rmtree'd it); re-running
        # would just print "not installed".
        if attempt == 1:
            result = subprocess.run(
                ["uv", "pip", "uninstall", "--python", python, pkg],
                stderr=subprocess.PIPE,
                text=True,
            )
            if result.returncode == 0:
                print(f"uv uninstalled '{pkg}'.")
            elif result.stderr:
                print(result.stderr, file=sys.stderr, end="")

        probe = subprocess.run(
            [
                python,
                "-c",
                "import importlib, os, sys; "
                "m = importlib.import_module(sys.argv[1]); "
                "print(os.path.dirname(m.__file__))",
                pkg,
            ],
            capture_output=True,
            text=True,
        )
        if probe.returncode != 0:
            print(f"'{pkg}' is no longer importable. Clean removal confirmed.")
            return 0

        pkg_path_str = probe.stdout.strip()
        if not pkg_path_str:
            print(
                f"ERROR: probe returned empty path for '{pkg}' (top-level module?).",
                file=sys.stderr,
            )
            return 1
        pkg_path = Path(pkg_path_str)
        print(f"Attempt {attempt}: '{pkg}' still importable at: {pkg_path}")

        if pkg_path == prev_pkg_path:
            print(
                f"ERROR: cannot remove '{pkg_path}' (no progress between attempts). "
                "Check permissions.",
                file=sys.stderr,
            )
            return 1
        prev_pkg_path = pkg_path

        print(f"Removing {pkg_path}")
        shutil.rmtree(pkg_path, ignore_errors=True)

        for pattern in (f"{pkg}*.dist-info", f"{pkg}*.egg-info"):
            for meta in pkg_path.parent.glob(pattern):
                print(f"Removing metadata: {meta}")
                shutil.rmtree(meta, ignore_errors=True)

    print(
        f"ERROR: Failed to fully remove '{pkg}' after {max_attempts} attempts.",
        file=sys.stderr,
    )
    return 1


def main():
    parser = argparse.ArgumentParser(
        description="Forcefully uninstall a Python package, removing leftover files."
    )
    parser.add_argument("package", help="Importable module name to uninstall")
    parser.add_argument(
        "--python",
        default=sys.executable,
        help="Python interpreter to operate on (default: this interpreter)",
    )
    parser.add_argument(
        "--max-attempts",
        type=lambda s: None if s.lower() in ("inf", "infinity") else int(s),
        default=None,
        help="Max uninstall attempts; 'inf' means unlimited (default: inf)",
    )
    args = parser.parse_args()
    return force_uninstall(args.package, args.python, args.max_attempts)


if __name__ == "__main__":
    sys.exit(main())
