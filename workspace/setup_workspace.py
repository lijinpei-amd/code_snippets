#!/usr/bin/env python3
"""Set up a new development workspace.

Creates a workspace directory, checks out detached worktrees from local clones
in REPOS_DIR (started at each repo's upstream default branch), and sets up a
Python virtual environment.
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
    """Ensure REPOS_DIR exists and contains a clone for each URL in repos.txt."""
    if not REPOS_LIST.is_file():
        print(f"Warning: {REPOS_LIST} not found, skipping repo bootstrap.", file=sys.stderr)
        return

    REPOS_DIR.mkdir(parents=True, exist_ok=True)

    pending = []
    for raw in REPOS_LIST.read_text().splitlines():
        url = raw.strip()
        if not url or url.startswith("#"):
            continue

        repo_name = url.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")
        target = REPOS_DIR / repo_name

        if target.exists():
            continue

        pending.append((url, target))

    if not pending:
        return

    with ThreadPoolExecutor(max_workers=min(4, len(pending))) as pool:
        for fut in [pool.submit(clone_detached, url, target) for url, target in pending]:
            fut.result()


def find_default_upstream_ref(repo):
    """Return e.g. 'origin/main' by asking git what the remote's HEAD points to."""
    result = subprocess.run(
        ["git", "-C", str(repo), "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def clone_detached(url, target):
    """Clone url into target with a detached HEAD at the upstream default commit.

    Leaves the central clone with no local branches so it acts as a pure source
    of objects and refs.
    """
    print(f"Cloning {url} -> {target}...")
    run(["git", "clone", "--no-checkout", url, str(target)])

    ref = find_default_upstream_ref(target)
    if ref is None:
        print(
            f"Warning: no default upstream branch in {target.name}; "
            f"leaving working tree empty.",
            file=sys.stderr,
        )
        return

    print(f"Detaching {target.name} at {ref}...")
    run(["git", "-C", str(target), "checkout", "--detach", ref])

    local_branches = subprocess.run(
        ["git", "-C", str(target), "for-each-ref", "--format=%(refname:short)", "refs/heads/"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    if local_branches:
        run(["git", "-C", str(target), "branch", "-D", *local_branches])


def discover_repos():
    if not REPOS_DIR.is_dir():
        print(f"Warning: no repos found in {REPOS_DIR}", file=sys.stderr)
        return []
    repos = sorted(p for p in REPOS_DIR.iterdir() if p.is_dir() and (p / ".git").exists())
    if not repos:
        print(f"Warning: no repos found in {REPOS_DIR}", file=sys.stderr)
    return repos


def activate_venv(venv_path):
    venv_bin = str(venv_path / "bin")
    os.environ["PATH"] = f"{venv_bin}:{os.environ['PATH']}"
    os.environ["VIRTUAL_ENV"] = str(venv_path)


def registered_worktree_paths(repo):
    """Resolved paths of every worktree currently registered for repo.

    Includes worktrees whose directory was deleted out-of-band (git reports
    them as "prunable"). Matching by path lets us target a specific worktree
    without guessing the .git/worktrees/<name> metadata dir, which git
    disambiguates with numeric suffixes when basenames collide across
    workspaces (e.g. aiter, aiter1, aiter3 for three workspaces).
    """
    result = subprocess.run(
        ["git", "-C", str(repo), "worktree", "list", "--porcelain"],
        capture_output=True, text=True, check=False,
    )
    paths = set()
    for line in result.stdout.splitlines():
        if line.startswith("worktree "):
            paths.add(Path(line[len("worktree "):]).resolve())
    return paths


def remove_worktrees(workspace, repos):
    for repo in repos:
        worktree_path = workspace / repo.name

        # Only act on a worktree this repo actually has registered at our path.
        # Skipping unregistered paths avoids misleading "Removing..." output and
        # keeps a genuine removal failure (below) distinguishable from a no-op.
        if worktree_path.resolve() not in registered_worktree_paths(repo):
            continue

        print(f"Removing worktree {worktree_path}...")
        # Double --force removes the worktree even if it is locked or dirty; for
        # a registration whose directory was deleted out-of-band, git drops the
        # stale entry too. We target by path and deliberately avoid the
        # repo-wide `worktree prune`, which would also drop other workspaces'
        # registrations if their directories happened to be transiently absent.
        result = subprocess.run(
            ["git", "-C", str(repo), "worktree", "remove", "--force", "--force", str(worktree_path)],
            check=False, capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(
                f"Warning: failed to remove worktree {worktree_path}: {result.stderr.strip()}",
                file=sys.stderr,
            )


def add_worktree(workspace, repo):
    """Returns the project name if a worktree was added, otherwise None."""
    repo_name = repo.name
    worktree_path = workspace / repo_name

    if worktree_path.is_dir():
        return None

    start_point = find_default_upstream_ref(repo)
    if start_point is None:
        print(f"Warning: no default upstream branch in {repo.name}, skipping.", file=sys.stderr)
        return None

    print(f"Adding worktree for {repo_name} (detached at {start_point})...")
    run([
        "git", "-C", str(repo),
        "worktree", "add", "--detach",
        str(worktree_path),
        start_point,
    ])
    return repo_name


def setup_workspace(identifier, parent_dir, force=False):
    workspace = parent_dir / identifier

    ensure_repos()

    repos = discover_repos()

    if workspace.exists():
        if not force:
            print(f"Error: workspace '{workspace}' already exists.", file=sys.stderr)
            sys.exit(1)
        print(f"Removing existing workspace: {workspace}")
        remove_worktrees(workspace, repos)
        shutil.rmtree(workspace)

    print(f"Creating workspace: {workspace}")
    workspace.mkdir(parents=True)

    for repo in repos:
        add_worktree(workspace, repo)

    venv_path = workspace / "venv"
    print(f"Creating virtual environment at {venv_path}...")
    run(["uv", "venv", "--system-site-packages", "--prompt", identifier, str(venv_path)])
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
    for repo in discover_repos():
        project = add_worktree(workspace, repo)
        if project is not None:
            added.append(project)

    if not added:
        print("No new worktrees added; workspace is already up to date.")
        return

    venv_path = workspace / "venv"
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
