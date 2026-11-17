#!/usr/bin/env python3
"""Set up a new development workspace.

Creates a workspace directory, checks out detached worktrees from local clones
in REPOS_DIR (started at each repo's upstream default branch), and sets up a
Python virtual environment.  ``--components`` limits the run to a subset of the
repositories listed in repos.txt.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


DEFAULT_PARENT = Path.home() / "development" / "workspace"
REPOS_DIR = Path.home() / "development" / "repos"
_SCRIPT_DIR = Path(__file__).resolve().parent
SETUP_VENV_SCRIPT = _SCRIPT_DIR / "setup_venv.sh"
BUILD_SCRIPTS_DIR = _SCRIPT_DIR / "build"
BUILD_SCRIPT_PATTERN = re.compile(r"^(\d+)-(.+)\.sh$")
REPOS_LIST = _SCRIPT_DIR / "repos.txt"
PENDING_BUILDS_DIRNAME = ".workspace-pending-builds"
RECURSIVE_SUBMODULE_REPOS = {"aiter"}


class WorkspaceError(RuntimeError):
    """An error that makes creating or updating a workspace unsafe."""


def run(cmd, **kwargs):
    print(f"  $ {' '.join(str(c) for c in cmd)}")
    subprocess.run(cmd, check=True, **kwargs)


def resolve_workspace_path(identifier, parent_dir):
    """Return a safe, absolute workspace path below an absolute base path.

    Workspace identifiers are names, not paths.  Keeping that distinction here
    is important because the resulting path is eventually passed to both Git
    and ``shutil.rmtree``.
    """
    try:
        identifier = os.fspath(identifier)
    except TypeError as exc:
        raise WorkspaceError("workspace identifier must be a path component") from exc

    if not isinstance(identifier, str):
        raise WorkspaceError("workspace identifier must be text")

    identifier_path = Path(identifier)
    if (
        not identifier
        or "\0" in identifier
        or any(unicodedata.category(char) == "Cc" for char in identifier)
        or identifier in {".", ".."}
        or identifier_path.is_absolute()
        or identifier_path.name != identifier
        or len(identifier_path.parts) != 1
    ):
        raise WorkspaceError(
            f"invalid workspace identifier {identifier!r}: "
            "expected exactly one non-special path component"
        )

    try:
        base = Path(parent_dir).expanduser().resolve()
        candidate = base / identifier
        workspace = candidate.resolve()
    except (OSError, RuntimeError) as exc:
        raise WorkspaceError(
            f"could not resolve workspace path for {identifier!r}: {exc}"
        ) from exc

    try:
        workspace.relative_to(base)
    except ValueError as exc:
        raise WorkspaceError(
            f"workspace '{workspace}' must be strictly below base directory '{base}'"
        ) from exc

    if workspace == base:
        raise WorkspaceError(
            f"workspace '{workspace}' must be strictly below base directory '{base}'"
        )

    # An existing final-component symlink can redirect a valid-looking name to
    # another directory (including a sibling workspace).  Workspaces are real
    # directories, so reject that ambiguous case rather than deleting through
    # or operating on the link.
    if candidate.is_symlink():
        raise WorkspaceError(f"workspace path '{candidate}' must not be a symbolic link")

    return workspace


def refresh_repo(repo):
    """Fetch an existing central clone and refresh its origin/HEAD.

    A failed refresh is fatal: callers must not quietly create a workspace from
    stale remote-tracking refs when the remote could not be updated.
    """
    print(f"Refreshing {repo.name}...")
    try:
        run(["git", "-C", str(repo), "fetch", "--prune", "origin"])
        run(["git", "-C", str(repo), "remote", "set-head", "origin", "--auto"])
        ref = find_default_upstream_ref(repo)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise WorkspaceError(f"failed to refresh repository '{repo}'") from exc

    if ref is None:
        raise WorkspaceError(
            f"repository '{repo}' has no default upstream branch after refresh"
        )
    return ref


def repo_name_from_url(url):
    """Return the checkout directory name implied by a manifest URL."""
    repo_name = url.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")
    repo_path = Path(repo_name)
    if (
        not repo_name
        or repo_name in {".", ".."}
        or repo_path.name != repo_name
        or len(repo_path.parts) != 1
    ):
        raise WorkspaceError(f"invalid repository URL in {REPOS_LIST}: {url!r}")
    return repo_name


def read_repo_manifest():
    """Read and validate repos.txt before any repositories are changed."""
    if not REPOS_LIST.is_file():
        raise WorkspaceError(f"repository manifest '{REPOS_LIST}' does not exist")

    try:
        lines = REPOS_LIST.read_text().splitlines()
    except OSError as exc:
        raise WorkspaceError(f"failed to read repository manifest '{REPOS_LIST}'") from exc

    entries = []
    names = {}
    for line_number, raw in enumerate(lines, start=1):
        url = raw.strip()
        if not url or url.startswith("#"):
            continue

        repo_name = repo_name_from_url(url)
        if repo_name in names:
            raise WorkspaceError(
                f"duplicate repository basename '{repo_name}' in {REPOS_LIST} "
                f"(lines {names[repo_name]} and {line_number})"
            )
        names[repo_name] = line_number
        entries.append((url, repo_name))

    return entries


def split_components(value):
    """Split one ``--components`` argument into its comma-separated names."""
    names = [name.strip() for name in value.split(",")]
    if not all(names):
        raise argparse.ArgumentTypeError(
            f"invalid component list {value!r}: empty component name"
        )
    return names


def load_components(requested=None):
    """Read repos.txt and resolve which of its repositories to act on.

    Args:
        requested: Repository basenames from ``--components``; None selects
            every repository in repos.txt.

    Returns:
        ``(manifest, selected)``: every ``(url, name)`` entry of repos.txt and
        the set of repository names to act on.

    Raises:
        WorkspaceError: repos.txt is invalid, or *requested* is empty or names
            a repository that repos.txt does not list.
    """
    manifest = read_repo_manifest()
    known = [repo_name for _, repo_name in manifest]
    if requested is None:
        return manifest, set(known)
    if isinstance(requested, str):
        raise TypeError("components must be a collection of names, not a string")
    if not requested:
        raise WorkspaceError("no components selected")

    unknown = sorted(set(requested) - set(known))
    if unknown:
        raise WorkspaceError(
            f"unknown component(s) {', '.join(unknown)}; "
            f"expected names from {REPOS_LIST}: {', '.join(known)}"
        )
    return manifest, set(requested)


def get_origin_url(repo):
    """Return a central clone's configured origin fetch URL."""
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), "config", "--get", "remote.origin.url"],
            capture_output=True, text=True, check=False,
        )
    except OSError as exc:
        raise WorkspaceError(f"failed to inspect origin for '{repo}': {exc}") from exc

    if result.returncode != 0 or not result.stdout.strip():
        detail = (
            (result.stderr or "").strip()
            or (result.stdout or "").strip()
            or "origin is not configured"
        )
        raise WorkspaceError(f"failed to inspect origin for '{repo}': {detail}")
    return result.stdout.strip()


def verify_repo_origin(repo, expected_url):
    """Fail if an existing checkout does not match its manifest entry."""
    if get_origin_url(repo) != expected_url:
        raise WorkspaceError(
            f"repository '{repo}' origin does not match its entry in {REPOS_LIST}"
        )


def ensure_repos(manifest, selected):
    """Clone or refresh the *selected* repositories of *manifest* in REPOS_DIR.

    Args:
        manifest: Every ``(url, name)`` entry of repos.txt.
        selected: Names of the repositories to clone or refresh.
    """
    REPOS_DIR.mkdir(parents=True, exist_ok=True)

    pending = []
    for url, repo_name in manifest:
        target = REPOS_DIR / repo_name

        if target.exists():
            # Verify unselected clones too: --force still removes their
            # worktrees from the workspace being recreated.
            verify_repo_origin(target, url)
            if repo_name in selected:
                refresh_repo(target)
            continue

        if repo_name in selected:
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


def discover_repos(names=None):
    """Return the central clones in REPOS_DIR, limited to *names* if given."""
    if not REPOS_DIR.is_dir():
        print(f"Warning: no repos found in {REPOS_DIR}", file=sys.stderr)
        return []
    repos = sorted(p for p in REPOS_DIR.iterdir() if p.is_dir() and (p / ".git").exists())
    if not repos:
        print(f"Warning: no repos found in {REPOS_DIR}", file=sys.stderr)
        return repos
    if names is not None:
        repos = [r for r in repos if r.name in names]
    return repos


def activate_venv(venv_path):
    venv_bin = str(venv_path / "bin")
    os.environ["PATH"] = f"{venv_bin}:{os.environ['PATH']}"
    os.environ["VIRTUAL_ENV"] = str(venv_path)


_VENV_PREFIX_MARKER = "__WORKSPACE_VENV_PREFIX__"
_VENV_PREFIX_QUERY = (
    "import json, os, sys; "
    f"print({_VENV_PREFIX_MARKER!r} + json.dumps(os.path.realpath(sys.prefix)))"
)


def validate_workspace_venv(venv_path):
    """Return the venv Python after proving it belongs to *venv_path*."""
    config = venv_path / "pyvenv.cfg"
    python = venv_path / "bin" / "python"
    if not config.is_file() or not python.is_file():
        raise WorkspaceError(
            f"workspace virtual environment '{venv_path}' is missing or incomplete; "
            "refusing to run project builds"
        )

    try:
        result = subprocess.run(
            [str(python), "-I", "-c", _VENV_PREFIX_QUERY],
            capture_output=True, text=True, check=False,
        )
    except OSError as exc:
        raise WorkspaceError(
            f"could not execute workspace virtual environment '{python}': {exc}"
        ) from exc

    if result.returncode != 0:
        detail = (result.stderr or "").strip() or "interpreter query failed"
        raise WorkspaceError(
            f"could not validate workspace virtual environment '{venv_path}': {detail}"
        )

    payload = next(
        (
            line[len(_VENV_PREFIX_MARKER):]
            for line in reversed(result.stdout.splitlines())
            if line.startswith(_VENV_PREFIX_MARKER)
        ),
        None,
    )
    if payload is None:
        raise WorkspaceError(
            f"workspace virtual environment '{venv_path}' returned no prefix"
        )
    try:
        prefix = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise WorkspaceError(
            f"workspace virtual environment '{venv_path}' returned an invalid prefix"
        ) from exc

    expected_prefix = venv_path.resolve()
    try:
        actual_prefix = Path(prefix).resolve()
    except (OSError, TypeError) as exc:
        raise WorkspaceError(
            f"workspace virtual environment '{venv_path}' returned an invalid prefix"
        ) from exc
    if actual_prefix != expected_prefix:
        raise WorkspaceError(
            f"workspace virtual environment '{venv_path}' resolves to "
            f"'{actual_prefix}'; refusing to run project builds"
        )
    return python


def pending_builds_dir(workspace):
    state_dir = workspace / PENDING_BUILDS_DIRNAME
    if state_dir.is_symlink() or (state_dir.exists() and not state_dir.is_dir()):
        raise WorkspaceError(f"invalid pending-build state directory '{state_dir}'")
    return state_dir


def pending_projects(workspace):
    """Return projects whose post-add build has not completed successfully."""
    state_dir = pending_builds_dir(workspace)
    if not state_dir.exists():
        return set()

    projects = set()
    for marker in state_dir.iterdir():
        if marker.is_symlink() or not marker.is_file():
            raise WorkspaceError(f"invalid pending-build marker '{marker}'")
        projects.add(marker.name)
    return projects


def mark_projects_pending(workspace, projects):
    projects = set(projects)
    if not projects:
        return

    state_dir = pending_builds_dir(workspace)
    state_dir.mkdir(exist_ok=True)
    for project in projects:
        project_path = Path(project)
        if (
            not project
            or project in {".", ".."}
            or project_path.name != project
            or len(project_path.parts) != 1
        ):
            raise WorkspaceError(f"invalid project name for pending build: {project!r}")
        marker = state_dir / project
        if marker.is_symlink() or (marker.exists() and not marker.is_file()):
            raise WorkspaceError(f"invalid pending-build marker '{marker}'")
        marker.touch(exist_ok=True)


def clear_pending_project(workspace, project):
    state_dir = pending_builds_dir(workspace)
    marker = state_dir / project
    if marker.is_symlink() or (marker.exists() and not marker.is_file()):
        raise WorkspaceError(f"invalid pending-build marker '{marker}'")
    marker.unlink(missing_ok=True)
    try:
        state_dir.rmdir()
    except OSError:
        pass


def registered_worktree_paths(repo):
    """Resolved paths of every worktree currently registered for repo.

    Includes worktrees whose directory was deleted out-of-band (git reports
    them as "prunable"). Matching by path lets us target a specific worktree
    without guessing the .git/worktrees/<name> metadata dir, which git
    disambiguates with numeric suffixes when basenames collide across
    workspaces (e.g. aiter, aiter1, aiter3 for three workspaces).
    """
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), "worktree", "list", "--porcelain", "-z"],
            capture_output=True, text=True, check=False,
        )
    except OSError as exc:
        raise WorkspaceError(f"failed to list worktrees for '{repo}': {exc}") from exc

    if result.returncode != 0:
        detail = (
            (result.stderr or "").strip()
            or (result.stdout or "").strip()
            or "unknown git error"
        )
        raise WorkspaceError(f"failed to list worktrees for '{repo}': {detail}")

    paths = set()
    for field in result.stdout.split("\0"):
        if field.startswith("worktree "):
            paths.add(Path(field[len("worktree "):]).resolve())
    return paths


def git_absolute_path(repo, query):
    """Return one absolute path reported by ``git rev-parse``.

    Keep each path query in a separate invocation: Git terminates its answer
    with a newline, but a valid path can itself contain embedded newlines.  A
    broad ``strip`` or a multi-value query would therefore corrupt or
    ambiguously split the result.
    """
    try:
        result = subprocess.run(
            [
                "git", "-C", str(repo), "rev-parse",
                "--path-format=absolute", query,
            ],
            capture_output=True, text=True, check=False,
        )
    except OSError as exc:
        raise WorkspaceError(
            f"failed to inspect Git path '{query}' for '{repo}': {exc}"
        ) from exc

    if result.returncode != 0:
        detail = (
            (result.stderr or "").strip()
            or (result.stdout or "").strip()
            or "unknown git error"
        )
        raise WorkspaceError(
            f"failed to inspect Git path '{query}' for '{repo}': {detail}"
        )

    output = result.stdout
    if output.endswith("\n"):
        output = output[:-1]
        if output.endswith("\r"):
            output = output[:-1]
    if not output:
        raise WorkspaceError(
            f"Git returned an empty path for '{query}' in '{repo}'"
        )

    try:
        return Path(output).resolve()
    except (OSError, RuntimeError) as exc:
        raise WorkspaceError(
            f"failed to resolve Git path '{output}' for '{repo}': {exc}"
        ) from exc


def validate_linked_worktree(worktree_path, repo):
    """Prove that a directory is the expected linked worktree for *repo*.

    Worktree registration alone is insufficient: stale metadata can continue
    to name a path after its checkout was deleted and an unrelated directory
    was created in its place.
    """
    expected_top_level = worktree_path.resolve()
    actual_top_level = git_absolute_path(worktree_path, "--show-toplevel")
    if actual_top_level != expected_top_level:
        raise WorkspaceError(
            f"project directory '{worktree_path}' has Git top-level "
            f"'{actual_top_level}', not the expected linked worktree path"
        )

    actual_common_dir = git_absolute_path(worktree_path, "--git-common-dir")
    expected_common_dir = git_absolute_path(repo, "--git-common-dir")
    if actual_common_dir != expected_common_dir:
        raise WorkspaceError(
            f"project directory '{worktree_path}' is linked to Git common "
            f"directory '{actual_common_dir}', not expected repository '{repo}'"
        )


def git_output(cwd, args, action):
    """Run ``git -C cwd args`` and return its stdout.

    Raises:
        WorkspaceError: Git could not be run or exited non-zero; the message
            reads "failed to <action>: <git error>".
    """
    try:
        result = subprocess.run(
            ["git", "-C", str(cwd), *args],
            capture_output=True, text=True, check=False,
        )
    except OSError as exc:
        raise WorkspaceError(f"failed to {action}: {exc}") from exc

    if result.returncode != 0:
        detail = (
            (result.stderr or "").strip()
            or (result.stdout or "").strip()
            or "unknown git error"
        )
        raise WorkspaceError(f"failed to {action}: {detail}")
    return result.stdout


def unsaved_work(worktree_path, repo):
    """Describe the work that removing a linked worktree would lose.

    Removal deletes the checkout together with its HEAD and per-worktree refs,
    so a commit survives only if a ref stored in *repo* itself (a branch, tag,
    remote-tracking ref, stash, ...) reaches it.

    Returns:
        Human-readable problems; an empty list when removal loses nothing.
    """
    problems = []

    # Also reports submodules with changes or a HEAD moved off the commit
    # recorded by the superproject.
    status = git_output(
        worktree_path,
        [
            "status", "--porcelain", "-z",
            "--untracked-files=normal", "--ignore-submodules=none",
        ],
        f"check '{worktree_path}' for uncommitted changes",
    )
    if status:
        problems.append("uncommitted or untracked changes")

    head = git_output(
        worktree_path,
        ["rev-parse", "--verify", "--end-of-options", "HEAD^{commit}"],
        f"resolve HEAD of '{worktree_path}'",
    ).strip()
    # --single-worktree keeps the HEADs of other worktrees (other workspaces)
    # out of --all: they do not save this work in the central clone.
    unsaved_commits = int(git_output(
        repo,
        ["rev-list", "--count", "--single-worktree", head, "--not", "--all"],
        f"check '{worktree_path}' for unsaved commits",
    ))
    if unsaved_commits:
        problems.append(
            f"{unsaved_commits} commit(s) not on any branch, tag or "
            f"remote-tracking ref of '{repo}'"
        )
    return problems


def remove_worktrees(workspace, repos):
    # Complete every listing before removing anything.  If even one central
    # clone cannot be inspected, preserving the existing workspace is safer
    # than partially dismantling it and then recursively deleting it.
    repos = list(repos)
    worktree_paths = {repo: workspace / repo.name for repo in repos}
    for worktree_path in worktree_paths.values():
        if worktree_path.is_symlink():
            raise WorkspaceError(
                f"refusing to remove symbolic-link worktree path '{worktree_path}'"
            )
        if worktree_path.exists() and not worktree_path.is_dir():
            raise WorkspaceError(
                f"refusing to remove non-directory worktree path '{worktree_path}'"
            )
    registrations = {
        repo: registered_worktree_paths(repo)
        for repo in repos
    }

    # Validate every existing registered checkout before removing any of them.
    # This both prevents partial teardown and keeps `git worktree remove
    # --force` from recursively deleting an unrelated directory that replaced
    # a stale registered path or a checkout that still holds unsaved work.  A
    # missing registered path is safe to pass to Git so that its stale
    # metadata can be deregistered.
    unsaved = []
    for repo in repos:
        worktree_path = worktree_paths[repo]
        if (
            worktree_path.resolve() in registrations[repo]
            and worktree_path.exists()
        ):
            validate_linked_worktree(worktree_path, repo)
            unsaved.extend(
                f"  {worktree_path}: {problem}"
                for problem in unsaved_work(worktree_path, repo)
            )
    if unsaved:
        raise WorkspaceError(
            "refusing to remove worktrees with unsaved work:\n"
            + "\n".join(unsaved)
            + "\ncommit it to a branch, stash it, or discard it first"
        )

    removed = []

    for repo in repos:
        worktree_path = worktree_paths[repo]
        # Recheck immediately before invoking Git so a path swapped after the
        # preflight cannot redirect removal to a different registered worktree.
        if worktree_path.is_symlink():
            raise WorkspaceError(
                f"refusing to remove symbolic-link worktree path '{worktree_path}'"
            )
        if worktree_path.exists() and not worktree_path.is_dir():
            raise WorkspaceError(
                f"refusing to remove non-directory worktree path '{worktree_path}'"
            )
        resolved_worktree_path = worktree_path.resolve()

        # Only act on a worktree this repo actually has registered at our path.
        # Skipping unregistered paths avoids misleading "Removing..." output and
        # keeps a genuine removal failure (below) distinguishable from a no-op.
        if resolved_worktree_path not in registrations[repo]:
            continue

        if worktree_path.exists():
            validate_linked_worktree(worktree_path, repo)

        print(f"Removing worktree {worktree_path}...")
        # Double --force removes the worktree even if it is locked or dirty; for
        # a registration whose directory was deleted out-of-band, git drops the
        # stale entry too. We target by path and deliberately avoid the
        # repo-wide `worktree prune`, which would also drop other workspaces'
        # registrations if their directories happened to be transiently absent.
        try:
            result = subprocess.run(
                [
                    "git", "-C", str(repo), "worktree", "remove",
                    "--force", "--force", str(worktree_path),
                ],
                check=False, capture_output=True, text=True,
            )
        except OSError as exc:
            raise WorkspaceError(
                f"failed to remove worktree '{worktree_path}': {exc}"
            ) from exc

        if result.returncode != 0:
            detail = (
                (result.stderr or "").strip()
                or (result.stdout or "").strip()
                or "unknown git error"
            )
            raise WorkspaceError(
                f"failed to remove worktree '{worktree_path}': {detail}"
            )

        if resolved_worktree_path in registered_worktree_paths(repo):
            raise WorkspaceError(
                f"worktree '{worktree_path}' is still registered after removal"
            )
        removed.append(worktree_path)

    return removed


def initialize_required_submodules(repo_name, worktree_path):
    if repo_name in RECURSIVE_SUBMODULE_REPOS:
        print(f"Initializing recursive submodules for {repo_name}...")
        run([
            "git", "-C", str(worktree_path),
            "submodule", "update", "--init", "--recursive",
        ])


def add_worktree(workspace, repo, force=False):
    """Returns the project name if a worktree was added, otherwise None.

    With *force*, a registration whose directory was deleted out-of-band is
    cleared (even if locked) so the worktree can be re-added; without it, such
    a registration is an error.
    """
    repo_name = repo.name
    worktree_path = workspace / repo_name

    if worktree_path.exists() or worktree_path.is_symlink():
        if worktree_path.is_symlink() or not worktree_path.is_dir():
            raise WorkspaceError(
                f"existing project path '{worktree_path}' is not a worktree directory"
            )
        if worktree_path.resolve() not in registered_worktree_paths(repo):
            raise WorkspaceError(
                f"existing project directory '{worktree_path}' is not a worktree "
                f"registered by '{repo}'"
            )
        validate_linked_worktree(worktree_path, repo)
        initialize_required_submodules(repo_name, worktree_path)
        return None

    start_point = find_default_upstream_ref(repo)
    if start_point is None:
        print(f"Warning: no default upstream branch in {repo.name}, skipping.", file=sys.stderr)
        return None

    if worktree_path.resolve() in registered_worktree_paths(repo):
        if not force:
            raise WorkspaceError(
                f"project directory '{worktree_path}' is missing but still "
                f"registered by '{repo}'; rerun with --force to clear it"
            )
        remove_worktrees(workspace, [repo])

    print(f"Adding worktree for {repo_name} (detached at {start_point})...")
    run([
        "git", "-C", str(repo),
        "worktree", "add", "--detach",
        str(worktree_path),
        start_point,
    ])
    # Record retry state before any fallible post-add operation.  In
    # particular, a failed recursive submodule initialization leaves a valid,
    # registered worktree that update mode must still schedule for building.
    mark_projects_pending(workspace, {repo_name})
    initialize_required_submodules(repo_name, worktree_path)
    return repo_name


def setup_workspace(
    identifier, parent_dir, force=False, run_venv_setup=True, components=None,
):
    workspace = resolve_workspace_path(identifier, parent_dir)
    manifest, selected = load_components(components)

    ensure_repos(manifest, selected)

    # Use all repos for removal (cleans stale registrations from repos removed from
    # repos.txt), but only selected repos.txt-listed repos for adding (so removing
    # a URL from repos.txt immediately excludes it from new workspaces).
    # --force recreates the whole workspace, so it tears down every worktree
    # regardless of --components.
    all_repos = discover_repos()
    active_repos = discover_repos(selected)

    if force:
        if workspace.exists():
            print(f"Removing existing workspace: {workspace}")
        # Runs even when the workspace directory is gone: an out-of-band
        # `rm -rf` leaves registrations that make `git worktree add` fail.
        remove_worktrees(workspace, all_repos)
        if workspace.exists():
            shutil.rmtree(workspace)
    elif workspace.exists():
        raise WorkspaceError(
            f"workspace '{workspace}' already exists; use --force to recreate it"
        )

    print(f"Creating workspace: {workspace}")
    workspace.mkdir(parents=True)

    for repo in active_repos:
        add_worktree(workspace, repo)

    venv_path = workspace / "venv"
    print(f"Creating virtual environment at {venv_path}...")
    run(["uv", "venv", "--system-site-packages", "--prompt", identifier, str(venv_path)])
    validate_workspace_venv(venv_path)
    activate_venv(venv_path)

    if run_venv_setup:
        if SETUP_VENV_SCRIPT.exists():
            print(f"Running {SETUP_VENV_SCRIPT}...")
            run(["bash", str(SETUP_VENV_SCRIPT)])
        else:
            print(f"Warning: {SETUP_VENV_SCRIPT} not found, skipping venv setup.", file=sys.stderr)
    else:
        print("Skipping venv setup script (--skip-venv-setup).")

    post_setup(workspace, only_projects={repo.name for repo in active_repos})


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

    known_projects = {project for _, project, _ in scripts}
    if only_projects is None:
        requested_projects = pending_projects(workspace)
    else:
        requested_projects = set(only_projects)

    # A repository with no matching build script has no post-add work to retry.
    for project in requested_projects - known_projects:
        clear_pending_project(workspace, project)

    selected = []
    for priority, project, script in scripts:
        if only_projects is not None and project not in only_projects:
            continue

        source_dir = workspace / project
        if not source_dir.is_dir():
            print(f"Warning: source dir {source_dir} not found, skipping {script.name}.", file=sys.stderr)
            continue
        selected.append((priority, project, script, source_dir))

    mark_projects_pending(workspace, {project for _, project, _, _ in selected})
    last_script = {
        project: index
        for index, (_, project, _, _) in enumerate(selected)
    }

    for index, (_, project, script, source_dir) in enumerate(selected):
        build_dir = workspace / "build" / project
        install_dir = workspace / "install" / project

        build_dir.mkdir(parents=True, exist_ok=True)
        install_dir.mkdir(parents=True, exist_ok=True)

        print(f"\nRunning {script.name} (source={source_dir}, build={build_dir}, install={install_dir})...")
        run(["bash", str(script), str(source_dir), str(build_dir), str(install_dir)])
        if last_script[project] == index:
            clear_pending_project(workspace, project)

    print(f"\nWorkspace is ready at {workspace}")


def update_workspace(identifier, parent_dir, force=False, components=None):
    workspace = resolve_workspace_path(identifier, parent_dir)
    if not workspace.is_dir():
        raise WorkspaceError(f"workspace '{workspace}' does not exist")
    manifest, selected = load_components(components)

    ensure_repos(manifest, selected)

    active_repos = discover_repos(selected)
    active_projects = {repo.name for repo in active_repos}
    pending = pending_projects(workspace)
    projects_to_build = pending & active_projects

    # Pending builds of unselected components stay pending for a later run.
    listed_projects = {repo_name for _, repo_name in manifest}
    deferred = (pending & listed_projects) - active_projects
    if deferred:
        print(
            "Builds still pending outside --components: "
            + ", ".join(sorted(deferred))
        )

    for repo in active_repos:
        project = add_worktree(workspace, repo, force=force)
        if project is not None:
            projects_to_build.add(project)

    if not projects_to_build:
        scope = "workspace is" if components is None else "selected components are"
        print(f"No new worktrees added; {scope} already up to date.")
        return

    venv_path = workspace / "venv"
    validate_workspace_venv(venv_path)
    activate_venv(venv_path)

    post_setup(workspace, only_projects=projects_to_build)


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
        help=(
            "Remove existing workspace before creating a new one (stops if a "
            "worktree has uncommitted changes or commits not on any ref of its "
            "central clone); with --update, only clear stale registrations of "
            "deleted project directories"
        ),
    )
    parser.add_argument(
        "-u", "--update",
        action="store_true",
        help="Update an existing workspace: clone any new repos, add missing worktrees, and build them",
    )
    parser.add_argument(
        "-c", "--components", "--component",
        dest="components",
        action="extend",
        type=split_components,
        metavar="LIST",
        help=(
            f"Comma-separated repos from {REPOS_LIST.name} (basenames, e.g. "
            "triton,aiter) to clone, check out, and build; repeatable "
            "(default: all repos). -f without -u still recreates the whole "
            "workspace"
        ),
    )
    parser.add_argument(
        "--skip-venv-setup",
        action="store_true",
        help=f"Create the venv but skip running {SETUP_VENV_SCRIPT.name}",
    )
    args = parser.parse_args()
    try:
        if args.update:
            update_workspace(
                args.identifier,
                args.base_dir,
                force=args.force,
                components=args.components,
            )
        else:
            setup_workspace(
                args.identifier,
                args.base_dir,
                force=args.force,
                run_venv_setup=not args.skip_venv_setup,
                components=args.components,
            )
    except WorkspaceError as exc:
        parser.exit(1, f"Error: {exc}\n")


if __name__ == "__main__":
    main()
