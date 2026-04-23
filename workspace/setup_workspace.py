#!/usr/bin/env python3
"""Set up a new development workspace.

Creates a workspace directory, checks out worktrees from bare repos,
and sets up a Python virtual environment.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


DEFAULT_PARENT = Path.home() / "development" / "workspace"
REPOS_DIR = Path.home() / "development" / "repos"
_SCRIPT_DIR = Path(__file__).resolve().parent
SETUP_VENV_SCRIPT = _SCRIPT_DIR / "setup_venv.sh"
BUILD_SCRIPTS_DIR = _SCRIPT_DIR / "build"
BUILD_SCRIPT_PATTERN = re.compile(r"^(\d+)-(.+)\.sh$")


def run(cmd, **kwargs):
    print(f"  $ {' '.join(str(c) for c in cmd)}")
    subprocess.run(cmd, check=True, **kwargs)


def find_default_branch(bare_repo):
    """Find main or master branch in a bare repo."""
    result = subprocess.run(
        ["git", "--git-dir", str(bare_repo), "branch", "--list", "main", "master"],
        capture_output=True, text=True,
    )
    for line in result.stdout.splitlines():
        name = line.strip().lstrip("* ")
        if name in ("main", "master"):
            return name
    return None


def remove_worktrees(workspace, bare_repos):
    """Remove git worktrees that were checked out into the workspace."""
    for bare_repo in bare_repos:
        repo_name = bare_repo.name.removesuffix(".git")
        worktree_path = workspace / repo_name

        if worktree_path.is_dir():
            print(f"Removing worktree {worktree_path}...")
            subprocess.run(
                ["git", "--git-dir", str(bare_repo), "worktree", "remove", "--force", str(worktree_path)],
                check=False,
            )

        # Clean up stale git worktree metadata if the directory is already gone
        # but the registration remains under <bare-repo>/worktrees/<name>/
        worktree_meta = bare_repo / "worktrees" / repo_name
        shutil.rmtree(worktree_meta, ignore_errors=True)


def setup_workspace(identifier, parent_dir, force=False):
    workspace = parent_dir / identifier

    # Discover bare repos once for both removal and setup
    bare_repos = sorted(REPOS_DIR.glob("*.git"))
    if not bare_repos:
        print(f"Warning: no bare repos found in {REPOS_DIR}", file=sys.stderr)

    if workspace.exists():
        if not force:
            print(f"Error: workspace '{workspace}' already exists.", file=sys.stderr)
            sys.exit(1)
        print(f"Removing existing workspace: {workspace}")
        remove_worktrees(workspace, bare_repos)
        shutil.rmtree(workspace)

    print(f"Creating workspace: {workspace}")
    workspace.mkdir(parents=True)

    for bare_repo in bare_repos:
        repo_name = bare_repo.name.removesuffix(".git")
        worktree_path = workspace / repo_name

        # Determine which branch to base the worktree on
        start_point = find_default_branch(bare_repo)
        if start_point is None:
            print(f"Warning: no main or master branch in {bare_repo.name}, skipping.", file=sys.stderr)
            continue

        print(f"Adding worktree for {repo_name} (from {start_point})...")
        run(["git", "--git-dir", str(bare_repo), "worktree", "prune"])
        run([
            "git", "--git-dir", str(bare_repo),
            "worktree", "add", "--detach",
            str(worktree_path),
            start_point,
        ])

    # Create and set up virtual environment
    venv_path = workspace / "venv"
    print(f"Creating virtual environment at {venv_path}...")
    run(["uv", "venv", "--system-site-packages", str(venv_path)])

    # Activate venv in the current environment for subsequent steps
    venv_bin = str(venv_path / "bin")
    os.environ["PATH"] = f"{venv_bin}:{os.environ['PATH']}"
    os.environ["VIRTUAL_ENV"] = str(venv_path)

    if SETUP_VENV_SCRIPT.exists():
        print(f"Running {SETUP_VENV_SCRIPT}...")
        run(["bash", str(SETUP_VENV_SCRIPT)])
    else:
        print(f"Warning: {SETUP_VENV_SCRIPT} not found, skipping venv setup.", file=sys.stderr)

    post_setup(workspace)


def post_setup(workspace):
    # Discover build scripts matching <number>-<project>.sh
    if not BUILD_SCRIPTS_DIR.is_dir():
        print(f"Warning: {BUILD_SCRIPTS_DIR} not found, nothing to build.", file=sys.stderr)
        return

    scripts = []
    for entry in BUILD_SCRIPTS_DIR.iterdir():
        m = BUILD_SCRIPT_PATTERN.match(entry.name)
        if m:
            scripts.append((int(m.group(1)), m.group(2), entry))

    # Sort by number, then by name for ties
    scripts.sort(key=lambda x: (x[0], x[1]))

    for number, project, script in scripts:
        source_dir = workspace / project
        build_dir = workspace / "build" / project
        install_dir = workspace / "install" / project

        if not source_dir.is_dir():
            print(f"Warning: source dir {source_dir} not found, skipping {script.name}.", file=sys.stderr)
            continue

        build_dir.mkdir(parents=True, exist_ok=True)
        install_dir.mkdir(parents=True, exist_ok=True)

        print(f"\nRunning {script.name} (source={source_dir}, build={build_dir}, install={install_dir})...")
        run(["bash", str(script), str(source_dir), str(build_dir), str(install_dir)])

    print(f"\nWorkspace is ready at {workspace}")


def main():
    parser = argparse.ArgumentParser(description="Set up a new development workspace.")
    parser.add_argument("identifier", help="Workspace identifier (used as directory name and branch prefix)")
    parser.add_argument(
        "-p", "--base-dir",
        type=Path,
        default=DEFAULT_PARENT,
        help=f"Base directory for the workspace (default: {DEFAULT_PARENT})",
    )
    parser.add_argument(
        "-f", "--force",
        action="store_true",
        help="Remove existing workspace before creating a new one",
    )
    args = parser.parse_args()
    setup_workspace(args.identifier, args.base_dir, force=args.force)


if __name__ == "__main__":
    main()
