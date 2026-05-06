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
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


DEFAULT_PARENT = Path.home() / "development" / "workspace"
REPOS_DIR = Path.home() / "development" / "repos"
_SCRIPT_DIR = Path(__file__).resolve().parent
SETUP_VENV_SCRIPT = _SCRIPT_DIR / "setup_venv.sh"
BUILD_SCRIPTS_DIR = _SCRIPT_DIR / "build"
BUILD_SCRIPT_PATTERN = re.compile(r"^(\d+)-(.+)\.sh$")
REPOS_LIST = _SCRIPT_DIR / "repos.txt"


def run(cmd, **kwargs):
    print(f"  $ {' '.join(str(c) for c in cmd)}")
    subprocess.run(cmd, check=True, **kwargs)


def ensure_repos():
    """Ensure REPOS_DIR exists and contains a bare clone for each URL in repos.txt."""
    if not REPOS_LIST.is_file():
        print(f"Warning: {REPOS_LIST} not found, skipping repo bootstrap.", file=sys.stderr)
        return

    REPOS_DIR.mkdir(parents=True, exist_ok=True)

    pending = []
    for raw in REPOS_LIST.read_text().splitlines():
        url = raw.strip()
        if not url or url.startswith("#"):
            continue

        repo_name = url.rstrip("/").rsplit("/", 1)[-1]
        if not repo_name.endswith(".git"):
            repo_name += ".git"
        target = REPOS_DIR / repo_name

        if target.exists():
            continue

        pending.append((url, target))

    if not pending:
        return

    def clone(url, target):
        print(f"Cloning bare repo {url} -> {target}...")
        run(["git", "clone", "--bare", url, str(target)])

    with ThreadPoolExecutor(max_workers=min(4, len(pending))) as pool:
        for fut in [pool.submit(clone, url, target) for url, target in pending]:
            fut.result()


def discover_bare_repos():
    repos = sorted(REPOS_DIR.glob("*.git"))
    if not repos:
        print(f"Warning: no bare repos found in {REPOS_DIR}", file=sys.stderr)
    return repos


def activate_venv(venv_path):
    venv_bin = str(venv_path / "bin")
    os.environ["PATH"] = f"{venv_bin}:{os.environ['PATH']}"
    os.environ["VIRTUAL_ENV"] = str(venv_path)


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


def add_worktree(workspace, bare_repo):
    """Add a worktree for bare_repo into workspace if not already present.

    Returns the project name if a worktree was added, otherwise None.
    """
    repo_name = bare_repo.name.removesuffix(".git")
    worktree_path = workspace / repo_name

    if worktree_path.is_dir():
        return None

    start_point = find_default_branch(bare_repo)
    if start_point is None:
        print(f"Warning: no main or master branch in {bare_repo.name}, skipping.", file=sys.stderr)
        return None

    print(f"Adding worktree for {repo_name} (from {start_point})...")
    run(["git", "--git-dir", str(bare_repo), "worktree", "prune"])
    run([
        "git", "--git-dir", str(bare_repo),
        "worktree", "add", "--detach",
        str(worktree_path),
        start_point,
    ])
    return repo_name


def setup_workspace(identifier, parent_dir, force=False):
    workspace = parent_dir / identifier

    ensure_repos()

    bare_repos = discover_bare_repos()

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
        add_worktree(workspace, bare_repo)

    venv_path = workspace / "venv" / identifier
    print(f"Creating virtual environment at {venv_path}...")
    run(["uv", "venv", "--system-site-packages", str(venv_path)])
    activate_venv(venv_path)

    if SETUP_VENV_SCRIPT.exists():
        print(f"Running {SETUP_VENV_SCRIPT}...")
        run(["bash", str(SETUP_VENV_SCRIPT)])
    else:
        print(f"Warning: {SETUP_VENV_SCRIPT} not found, skipping venv setup.", file=sys.stderr)

    post_setup(workspace)


def post_setup(workspace, only_projects=None):
    if not BUILD_SCRIPTS_DIR.is_dir():
        print(f"Warning: {BUILD_SCRIPTS_DIR} not found, nothing to build.", file=sys.stderr)
        return

    scripts = []
    for entry in BUILD_SCRIPTS_DIR.iterdir():
        m = BUILD_SCRIPT_PATTERN.match(entry.name)
        if m:
            scripts.append((int(m.group(1)), m.group(2), entry))

    scripts.sort(key=lambda x: (x[0], x[1]))

    for _, project, script in scripts:
        if only_projects is not None and project not in only_projects:
            continue

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


def update_workspace(identifier, parent_dir):
    workspace = parent_dir / identifier
    if not workspace.is_dir():
        print(f"Error: workspace '{workspace}' does not exist.", file=sys.stderr)
        sys.exit(1)

    ensure_repos()

    added = []
    for bare_repo in discover_bare_repos():
        project = add_worktree(workspace, bare_repo)
        if project is not None:
            added.append(project)

    if not added:
        print("No new worktrees added; workspace is already up to date.")
        return

    venv_path = workspace / "venv" / identifier
    if venv_path.is_dir():
        activate_venv(venv_path)

    post_setup(workspace, only_projects=set(added))


def main():
    parser = argparse.ArgumentParser(description="Set up a new development workspace.")
    parser.add_argument("identifier", help="Workspace identifier (used as directory name and branch prefix)")
    parser.add_argument(
        "-p", "--base-dir",
        type=Path,
        default=DEFAULT_PARENT,
        help=f"Base directory for the workspace (default: {DEFAULT_PARENT})",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "-f", "--force",
        action="store_true",
        help="Remove existing workspace before creating a new one",
    )
    mode.add_argument(
        "-u", "--update",
        action="store_true",
        help="Update an existing workspace: clone any new repos, add missing worktrees, and build them",
    )
    args = parser.parse_args()
    if args.update:
        update_workspace(args.identifier, args.base_dir)
    else:
        setup_workspace(args.identifier, args.base_dir, force=args.force)


if __name__ == "__main__":
    main()
