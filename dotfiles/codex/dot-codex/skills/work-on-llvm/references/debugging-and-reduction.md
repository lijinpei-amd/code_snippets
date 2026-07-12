# LLVM Debugging And Reduction

Use this reference when investigating LLVM crashes, wrong-code, missed optimizations, or pass behavior questions.

## Pass Debugging

Use the narrow tool and pass pipeline first:

```bash
build/bin/opt -S -passes=<pass> repro.ll
build/bin/opt -passes=<pass> -disable-output repro.ll
build/bin/opt -passes=<pass>,verify -disable-output repro.ll
build/bin/opt -passes=<pass> -verify-each -disable-output repro.ll
```

Useful tracing:

```bash
build/bin/opt -passes=<pass> -debug-only=<pass> -disable-output repro.ll
build/bin/opt -passes=<pipeline> -print-after=<pass> -S repro.ll
build/bin/opt -passes=<pipeline> -print-changed=diff -disable-output repro.ll
build/bin/opt -passes=<pipeline> -stats -disable-output repro.ll
```

For backend/ISel:

```bash
build/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx900 -debug-only=isel -o /dev/null repro.ll
build/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx942 -debug-only=machine-scheduler -o /dev/null repro.ll
```

Slice large logs with `sed` around named phases rather than reading full output.

Temporary `errs() << "DBG<issue>"` prints are acceptable locally, but grep for the tag and remove all of them before committing.

## Reduction

Use `llvm-reduce`, not bugpoint, for modern LLVM IR reductions.

```bash
reduce_dir=$(mktemp -d "${TMPDIR:-/tmp}/llvm-reduce.XXXXXX")
trap 'rm -rf -- "$reduce_dir"' EXIT
cat > "$reduce_dir/interesting.sh" <<'EOF'
#!/usr/bin/env bash
out=$(/abs/build/bin/opt -passes=instcombine -disable-output "$1" 2>&1)
printf '%s' "$out" | grep -q 'exact assert text'
EOF
chmod 700 "$reduce_dir/interesting.sh"
build/bin/llvm-reduce --test="$reduce_dir/interesting.sh" crash.ll -o reduced.ll
```

The interestingness script must match the exact failure mode, not merely "nonzero exit", unless the crash is the only possible failure. After automated reduction, hand-finish for readability.

Good reduced tests:

- Keep the IR valid unless the bug is specifically invalid-IR handling.
- Avoid `br i1 false` and other constant-control-flow scaffolding.
- Replace magic constants with function arguments when that keeps the same dataflow.
- Drop target triple/datalayout unless required; if required, explain why.
- Keep original reproducer coverage when reviewers may worry about lost edge cases.

## Correctness Tools

Use Alive2 for IR transform soundness when applicable:

```bash
alive-tv repro.ll
alive-tv src.ll tgt.ll
```

Use llubi for execution-style IR checks when applicable:

```bash
llubi --deterministic --verbose repro.ll
llubi --seed=1 repro.ll
```

Use `llvm-diff a.ll b.ll` to compare intended IR equivalence across a refactor or pass output.

## Issue Intake And History

Fetch live context:

```bash
gh issue view <N> -R llvm/llvm-project --comments
gh pr view <N> -R llvm/llvm-project --comments
gh pr diff <N> -R llvm/llvm-project
```

Search history:

```bash
git log -S'<symbol or text>' -- <paths>
git log -G'<regex>' -- <paths>
git blame <file>
```

If a Godbolt shortlink is the only reproducer, fetch or decode it before guessing
at the source. Keep downloaded source and reduced IR in a private `mktemp -d`
directory rather than predictable shared `/tmp` filenames.

## Old Versus New

For subtle behavior claims, compare actual binaries or shared libraries:

- Build the pre-fix version and confirm the crash/miscompile/missed fold.
- Build the post-fix version and confirm the changed behavior.
- In this shared-library build, snapshot the relevant `libLLVM*.so*` files or rebuild each side. Do not copy only `build/bin/opt` or `build/bin/llc` and assume behavior is frozen.

For bisect scripts, remember Git's convention: `0` means good, `1` means bad, `125` means skip.
