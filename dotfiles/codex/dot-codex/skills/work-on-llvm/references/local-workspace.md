# Local LLVM Workspace Notes

Use this reference before running heavy LLVM commands, doing A/B comparisons, swapping worktrees, or preparing commits in this machine's LLVM checkouts.

## Worktrees

The LLVM setup uses many worktrees under:

```text
/mnt/nvme2/jinpli/workspace/home/jinpli/development/workspace/<NN>/llvm-project
/mnt/nvme2/jinpli/workspace/home/jinpli/development/repos/llvm-project
```

Multiple sessions may work in different worktrees concurrently, often on detached HEADs. Check:

```bash
git status --short --branch
git worktree list
```

Never use `git stash` here. The stash stack is shared by all worktrees using the common `.git`, so stash/pop can move another session's changes into the current worktree. Use one of these instead:

- Save a patch under `/tmp` with `git diff > /tmp/name.patch`, restore only files you own, then reapply with `git apply`.
- Make a temporary local WIP commit in the current worktree and undo it with non-destructive commands after comparison.
- Copy only the input/output artifacts needed for an A/B test into `/tmp`.

## Build Directories And Tools

Prefer the build directory already associated with the checkout. Common forms are:

```text
<llvm-project>/build/bin/opt
<llvm-project>/../build/llvm-project/bin/opt
<llvm-project>/build/bin/llc
<llvm-project>/build/bin/clang
<llvm-project>/build/bin/mlir-opt
```

Discover the build instead of guessing:

```bash
find .. -maxdepth 3 \( -name opt -o -name build.ninja -o -name CMakeCache.txt \) -print
grep -E "CMAKE_BUILD_TYPE|LLVM_ENABLE_ASSERTIONS|LLVM_TARGETS_TO_BUILD|LLVM_ENABLE_PROJECTS|COMPILER_LAUNCHER" <build>/CMakeCache.txt
```

Typical rebuilds:

```bash
ninja -C build opt
ninja -C build llc
ninja -C build clang
ninja -C build mlir-opt
```

Build narrow targets, preferably with assertions enabled. If a binary seems stale while iterating, force a fresh compile with `CCACHE_DISABLE=1 ninja -C build <tool>`.

Typical focused tests:

```bash
build/bin/llvm-lit -q llvm/test/Transforms/InstCombine/foo.ll
build/bin/llvm-lit -q llvm/test/CodeGen/AMDGPU/foo.ll
build/bin/llvm-lit -q clang/test/CodeGenCXX/foo.cpp
build/bin/llvm-lit -q mlir/test/Conversion/GPUToNVVM/foo.mlir
```

Use `-sv` while debugging a failing single test, and `-q` for clean final reporting.

Broader tests:

```bash
ninja -C build check-llvm
ninja -C build check-clang
ninja -C build check-mlir
```

## Shared Library Build

This LLVM build links tools against shared `libLLVM*.so` libraries. Tool binaries such as `build/bin/llc`, `opt`, and `clang` may be thin wrappers. Copying only `build/bin/llc` does not snapshot behavior; the copy still loads the current shared library.

For A/B testing a CodeGen or transform change:

1. Build the changed version.
2. Copy the relevant `build/lib/libLLVM*.so*` files into a `/tmp` directory.
3. Restore/rebuild the base version without using `git stash`.
4. Run with `LD_LIBRARY_PATH=/tmp/changed-libs build/bin/llc ...` versus the base libs.

This is especially useful for backend pass changes where relinking the shared library changes behavior while the tool binary itself may not change.

## Ccache And PCH

The workspace shares ccache across worktrees. Object files are intended to share well, but PCH files can be invalid across worktree paths.

If clang reports a stale `cmake_pch.hxx.pch` input path from another worktree:

```bash
find build -name '*.pch' -delete
CCACHE_RECACHE=1 ninja -C build <affected-pch-targets>
```

For a durable local fix, configure with `-DLLVM_ENABLE_PCH=OFF` if the build keeps serving stale PCH artifacts.

## Generated Checks

Use the update script from the source tree, not a hand-edited approximation:

```bash
python3 llvm/utils/update_test_checks.py --opt-binary build/bin/opt path/to/test.ll
python3 llvm/utils/update_llc_test_checks.py --llc-binary build/bin/llc path/to/test.ll
python3 clang/utils/update_cc_test_checks.py --clang build/bin/clang path/to/test.cpp
```

Adjust arguments to match the test's RUN lines. After regenerating, inspect the diff for noisy unrelated changes.

## Final Local Checks

Before reporting completion:

```bash
git diff --check
git status --short --branch
```

State exactly which tool rebuilds and lit targets were run.

When committing and pushing upstream work:

```bash
git clang-format --binary build/bin/clang-format HEAD~1 -- <files>
git push --force-with-lease lijinpei-amd <branch>
```

Use branch names like `YYYY-MM-DD-short-topic` when creating new branches for this workflow.
