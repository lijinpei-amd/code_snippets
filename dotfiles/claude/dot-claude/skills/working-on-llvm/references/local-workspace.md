# Local LLVM Workspace Notes

Read before running heavy LLVM commands, doing A/B comparisons, swapping worktrees,
or preparing commits in this machine's checkouts.

## Worktrees

Many worktrees live under:
```
~/development/workspace/<NN>/llvm-project      # NN = 01,02,…
~/development/repos/llvm-project               # main checkout
```
Multiple sessions may work concurrently in different worktrees, often on detached
HEADs. Always start with:
```bash
git status --short --branch
git worktree list
```
Treat unrelated dirty changes as belonging to another session — don't touch them.

Housekeeping the user does: create with `git worktree add -b <branch> <path> HEAD`;
before removing a worktree with dangling work, commit it to a `YYYY-MM-DD-tmp-topic`
branch and `git push --force-with-lease lijinpei-amd <branch>`; then
`git worktree remove <path>` / `git worktree prune -v`.

## Never `git stash`

The stash stack is shared by all worktrees on the common `.git`, so stash/pop can
move another session's changes into the current worktree. Instead:
- `git diff > /tmp/name.patch`, restore only files you own, reapply with `git apply`.
- Or make a temporary WIP commit and undo it non-destructively after comparison.
- Or copy only the input/output artifacts needed for the A/B test into `/tmp`.

## Discover the build dir (don't assume)

Layout differs per worktree — either `<llvm-project>/build/` or a sibling
`<NN>/build/llvm-project/`. Locate it and clone its config:
```bash
find .. -maxdepth 2 \( -name opt -o -name build.ninja -o -name CMakeCache.txt \) -print
grep -E "CMAKE_BUILD_TYPE|LLVM_ENABLE_ASSERTIONS|LLVM_TARGETS_TO_BUILD|LLVM_ENABLE_PROJECTS|COMPILER_LAUNCHER|LLVM_USE_SPLIT_DWARF" <build>/CMakeCache.txt
```
Invariant across configs: `LLVM_ENABLE_ASSERTIONS=ON`, ccache launcher, `-fuse-ld=lld`,
often `LLVM_USE_SPLIT_DWARF=ON`. Build type is Debug or Release depending on the tree;
throwaway bisect builds use Release with `-DLLVM_INCLUDE_TESTS=OFF` etc.

Typical rebuilds (narrow targets only, truncate logs):
```bash
ninja -C build opt 2>&1 | tail -1     # or llc / clang / mlir-opt / FileCheck
```

## Shared-library A/B testing

This build links tools against shared `libLLVM*.so`. Tool binaries (`build/bin/opt`,
`llc`, `clang`) are thin — copying only the binary does **not** snapshot behavior; it
still loads the current `.so`. To A/B a CodeGen/transform change:
1. Build the changed version.
2. Copy `build/lib/libLLVM*.so*` into a `/tmp` dir.
3. Restore/rebuild the base version (without `git stash`).
4. `LD_LIBRARY_PATH=/tmp/changed-libs build/bin/llc …` vs. the base libs.

## ccache / PCH staleness across worktrees

ccache is shared across worktrees; object files share well but PCH files can be
invalid across paths. If clang reports a stale `cmake_pch.hxx.pch` from another
worktree:
```bash
find build -name '*.pch' -delete
CCACHE_RECACHE=1 ninja -C build <affected-targets>
```
Durable fix: configure with `-DLLVM_ENABLE_PCH=OFF`. Use `CCACHE_DISABLE=1 ninja …`
when you need a guaranteed-fresh binary.

## alive2 / llubi

Built against an LLVM build tree (`-DBUILD_TV=1`, `-DCMAKE_PREFIX_PATH=<llvm-build>`),
producing `alive-tv`; `llubi` lives under `~/development/alive2*` /
`~/development/alive2-working/<date-slug>/build/bin/`. Run with the matching
`LD_LIBRARY_PATH=<build>/lib` when needed.

## Generated checks

Always regenerate from the source-tree script pointed at this build, then inspect
the diff for noisy unrelated changes:
```bash
llvm/utils/update_test_checks.py     --opt-binary build/bin/opt   path/to/test.ll
llvm/utils/update_llc_test_checks.py --llc-binary build/bin/llc   path/to/test.ll
clang/utils/update_cc_test_checks.py --clang build/bin/clang      path/to/test.cpp
```
(`--reset-variable-names` when value names churn.)

## Misc environment

- `find` is aliased to `bfs` (rejects GNU-find-only flags) — use globs/`ls` when
  scripting fails. `vim` is `nvim`. Heavy `rg` use for code search.
- Python: a venv is active; install with `uv`. Some `.py` can't run on this host —
  if told so, review without executing.

## Final local checks

Before reporting completion:
```bash
git diff --check
git status --short --branch
```
State exactly which tool rebuilds and lit targets were run.
