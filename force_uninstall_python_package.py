#!/usr/bin/env python3
"""Safely uninstall one Python distribution using its installed-file metadata.

The fallback remover deliberately does not import the requested package and never
recursively removes a directory.  It only unlinks paths recorded by the exact
installed distribution and removes now-empty parent directories.
"""

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


class UninstallError(RuntimeError):
    """Raised when a safe, exact removal plan cannot be constructed."""


@dataclass(frozen=True)
class DistributionInfo:
    name: str
    version: str
    files: tuple[Path, ...]
    install_roots: tuple[Path, ...]


# This code runs in the selected interpreter.  It inspects distribution metadata;
# it intentionally never imports the distribution's modules.
_METADATA_QUERY = r"""
import importlib.metadata
import json
import re
import site
import sys
import sysconfig

def canonicalize(name):
    return re.sub(r"[-_.]+", "-", name).lower()

wanted = canonicalize(sys.argv[1])
matches = []
for dist in importlib.metadata.distributions():
    name = dist.metadata.get("Name")
    if name and canonicalize(name) == wanted:
        matches.append(dist)

if not matches:
    result = {"status": "not-found"}
elif len(matches) != 1:
    result = {
        "status": "ambiguous",
        "matches": [
            {"name": d.metadata.get("Name", ""), "version": d.version}
            for d in matches
        ],
    }
else:
    dist = matches[0]
    files = dist.files
    if files is None:
        result = {
            "status": "missing-files",
            "name": dist.metadata.get("Name", ""),
            "version": dist.version,
        }
    else:
        roots = []
        schemes = [None]
        if site.ENABLE_USER_SITE:
            try:
                schemes.append(sysconfig.get_preferred_scheme("user"))
            except (AttributeError, KeyError):
                pass
        for scheme in schemes:
            paths = (
                sysconfig.get_paths()
                if scheme is None
                else sysconfig.get_paths(scheme=scheme)
            )
            for key in ("purelib", "platlib", "scripts"):
                value = paths.get(key)
                if value and value not in roots:
                    roots.append(value)
        result = {
            "status": "ok",
            "name": dist.metadata.get("Name", ""),
            "version": dist.version,
            "files": [str(dist.locate_file(path)) for path in files],
            "roots": roots,
        }

print("__DIST_INFO__" + json.dumps(result))
"""


def _absolute(path: Path) -> Path:
    """Return a normalized absolute path without following its final component."""
    return Path(os.path.abspath(os.fspath(path)))


def _lexists(path: Path) -> bool:
    """Like Path.exists(), but true for a broken symlink as well."""
    return os.path.lexists(path)


def _is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def inspect_distribution(package: str, python: str) -> DistributionInfo | None:
    """Read exact distribution metadata using *python*, without importing it."""
    result = subprocess.run(
        [python, "-c", _METADATA_QUERY, package],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "metadata query failed"
        raise UninstallError(f"could not inspect {python!r}: {detail}")

    marker = "__DIST_INFO__"
    payload_line = next(
        (line[len(marker):] for line in reversed(result.stdout.splitlines())
         if line.startswith(marker)),
        None,
    )
    if payload_line is None:
        raise UninstallError("selected interpreter returned no distribution metadata")
    try:
        payload = json.loads(payload_line)
    except json.JSONDecodeError as exc:
        raise UninstallError("selected interpreter returned invalid metadata") from exc

    status = payload.get("status")
    if status == "not-found":
        return None
    if status == "ambiguous":
        matches = ", ".join(
            f"{item['name']}=={item['version']}" for item in payload["matches"]
        )
        raise UninstallError(
            f"multiple installed distributions match {package!r}: {matches}"
        )
    if status == "missing-files":
        raise UninstallError(
            f"{payload['name']}=={payload['version']} has no installed-file metadata; "
            "refusing to guess what to remove"
        )
    if status != "ok":
        raise UninstallError(f"unrecognized metadata response: {status!r}")

    return DistributionInfo(
        name=payload["name"],
        version=payload["version"],
        files=tuple(_absolute(Path(path)) for path in payload["files"]),
        install_roots=tuple(_absolute(Path(path)) for path in payload["roots"]),
    )


def validate_owned_paths(info: DistributionInfo) -> tuple[Path, ...]:
    """Validate and deduplicate all metadata-owned paths before any mutation."""
    if not info.files:
        raise UninstallError(
            f"{info.name}=={info.version} records no installed files; refusing removal"
        )
    if not info.install_roots:
        raise UninstallError("selected interpreter reported no safe install roots")

    safe_paths = []
    seen = set()
    for path in info.files:
        path = _absolute(path)
        matching_root = next(
            (root for root in info.install_roots
             if path != root and _is_relative_to(path, root)),
            None,
        )
        if matching_root is None:
            raise UninstallError(
                f"metadata-owned path is outside the interpreter's package/script "
                f"directories: {path}"
            )

        # A parent symlink could make a lexically safe path target an arbitrary
        # location.  Resolving the parent still permits safely unlinking a final
        # symlink, including a broken one.
        resolved_parent = path.parent.resolve()
        if not _is_relative_to(resolved_parent, matching_root.resolve()):
            raise UninstallError(
                f"metadata-owned path traverses a symlink outside its install root: {path}"
            )
        if path not in seen:
            seen.add(path)
            safe_paths.append(path)
    return tuple(safe_paths)


def remove_owned_paths(paths: tuple[Path, ...], roots: tuple[Path, ...]) -> None:
    """Remove exact owned files and empty directories; never recurse."""
    failures = []
    for path in sorted(paths, key=lambda p: len(p.parts), reverse=True):
        if not _lexists(path):
            continue
        try:
            if path.is_dir() and not path.is_symlink():
                path.rmdir()
            else:
                path.unlink()
        except OSError as exc:
            failures.append(f"{path}: {exc}")

    # RECORD normally lists files, not package directories.  Clean up only
    # empty ancestors and stop before an installation root.
    parents = {path.parent for path in paths}
    for parent in sorted(parents, key=lambda p: len(p.parts), reverse=True):
        current = parent
        while any(current != root and _is_relative_to(current, root) for root in roots):
            try:
                current.rmdir()
            except OSError:
                break
            current = current.parent

    remaining = [path for path in paths if _lexists(path)]
    if failures or remaining:
        details = failures or [f"still exists: {path}" for path in remaining]
        raise UninstallError("could not remove every owned path:\n  " + "\n  ".join(details))


def force_uninstall(package, python, max_attempts):
    """Uninstall an exact distribution, with a metadata-bounded fallback."""
    if max_attempts is not None and max_attempts < 1:
        print("ERROR: --max-attempts must be at least 1", file=sys.stderr)
        return 1

    print(f"Using python: {python}")
    print(f"Using uv:     uv pip uninstall --python {python}")
    try:
        info = inspect_distribution(package, python)
        if info is None:
            print(f"Distribution {package!r} is not installed.")
            return 0
        owned_paths = validate_owned_paths(info)
    except (OSError, UninstallError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print(
        f"Found {info.name}=={info.version}; metadata records "
        f"{len(owned_paths)} owned paths."
    )
    try:
        result = subprocess.run(
            ["uv", "pip", "uninstall", "--python", python, info.name],
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        print(f"uv could not be run ({exc}); using the metadata fallback.", file=sys.stderr)
    else:
        if result.returncode == 0:
            print(f"uv uninstalled {info.name!r}.")
        else:
            detail = result.stderr.strip() or result.stdout.strip()
            if detail:
                print(detail, file=sys.stderr)
            print("uv did not complete the uninstall; using the metadata fallback.",
                  file=sys.stderr)

    remaining = tuple(path for path in owned_paths if _lexists(path))
    if remaining:
        print(f"Removing {len(remaining)} metadata-owned paths left by uv.")
        try:
            # Recheck parent symlinks after invoking the external uninstaller.
            validate_owned_paths(info)
            remove_owned_paths(remaining, info.install_roots)
        except UninstallError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 1

    print(f"Clean removal of {info.name!r} confirmed from its installed-file metadata.")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Safely uninstall a distribution using exact installed-file metadata."
    )
    parser.add_argument(
        "package",
        help="Installed distribution name (for example 'PyYAML', not import name 'yaml')",
    )
    parser.add_argument(
        "--python",
        default=sys.executable,
        help="Python interpreter to operate on (default: this interpreter)",
    )
    parser.add_argument(
        "--max-attempts",
        type=lambda s: None if s.lower() in ("inf", "infinity") else int(s),
        default=None,
        help="Deprecated compatibility option; the safe fallback makes one exact pass",
    )
    args = parser.parse_args()
    return force_uninstall(args.package, args.python, args.max_attempts)


if __name__ == "__main__":
    sys.exit(main())
