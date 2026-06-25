---
name: work-on-llvm
description: Practical LLVM contributor workflow for investigating GitHub issues, editing llvm-project, reducing .ll/.mir/MLIR tests, running LLVM/Clang/MLIR/AMDGPU builds, using llvm-reduce/alive2/llubi, preparing commits and PRs, and addressing reviewer comments. Use when Codex works on LLVM, Clang, MLIR, AMDGPU, CodeGen, InstCombine, SelectionDAG/ISel, Attributor, SCEV/LSR, JumpThreading, lit/FileCheck tests, upstream LLVM GitHub issues or PRs, reviewer feedback, or LLVM contribution hygiene.
---

# Work on LLVM

## Operating Model

Work like an upstream LLVM contributor: prove the failure first, make the smallest defensible change, preserve existing style, and leave behind a focused regression test plus a PR-ready explanation.

Before touching files:

- Identify the checkout root and build directory. Do not assume layout: it may be `llvm-project/build` or a sibling such as `../build/llvm-project`.
- Run `git status --short --branch`; assume unrelated dirty changes belong to another session or the user.
- Do not use `git stash` in this workspace. Read [local-workspace.md](references/local-workspace.md) before A/B testing, moving between worktrees, copying LLVM tools, or handling build cache issues.
- If the task mentions a GitHub issue or PR, fetch the live issue/PR body and comments with `gh issue view` or `gh pr view` before relying on memory.
- If the task is about reviewer feedback or PR polish, read [reviewer-patterns.md](references/reviewer-patterns.md).
- If the task requires crash reduction, pass tracing, Alive2/llubi, or old-vs-new comparison, read [debugging-and-reduction.md](references/debugging-and-reduction.md).

## Investigation Workflow

1. Reproduce the reported behavior with the narrowest local tool: `opt`, `llc`, `llvm-as`, `clang`, `mlir-opt`, `alive-tv`, `llubi`, or the relevant unit/lit test.
2. Reduce only as far as useful. Keep enough structure to make the bug believable and reviewable; over-reduction that hides the real mechanism is not always better.
3. Locate the responsible pass by comparing direct tools and pass pipelines. If `llvm-as` already crashes, do not blame InstCombine; if a backend test is scheduler-sensitive, inspect the schedule/debug output before changing checks.
4. Explain the mechanism in LLVM terms: dominance, poison/undef, flags, side effects, value availability, target cost, MIR dependency, dialect attribute ownership, or pass pipeline ordering.
5. Validate both pre-fix and post-fix behavior empirically. Temporarily recreating old behavior is acceptable, but restore the tree and rebuild before finishing.

## Patch Workflow

Prefer existing LLVM APIs and local patterns over bespoke logic. In particular:

- Use structured APIs such as `IRBuilder`, `NamedAttrList::set`, `replaceUsesWithIf`, verifier helpers, `SaveAndRestore`, generated ODS accessors, and target helpers when they match the problem.
- Add a shared helper when the review direction points to an existing abstraction gap, such as an `IRBuilder` helper parallel to an existing one.
- Split NFC refactors, TableGen cleanup, constification, or terminology changes away from semantic fixes when they make review noisy.
- Preserve semantic flags and metadata unless the proof says they must be dropped.
- Avoid verbose comments in code and tests. Add at most a concise one-line comment for a non-obvious correctness constraint; put broader rationale in the commit message or PR text.
- Do not make functional correctness depend on optional scheduler DAG mutations or pass registration. Model mandatory ordering in the IR/MIR/instruction representation so later passes see it by construction.
- Prefer adding an overload or stricter helper over weakening an existing public API for one corner case.

## Tests

A good LLVM fix usually has a lit regression that fails before the patch and passes after it.

- Use the test update script expected by the area: `llvm/utils/update_test_checks.py`, `llvm/utils/update_llc_test_checks.py`, or `clang/utils/update_cc_test_checks.py`.
- For InstCombine and transform tests, prefer precommit-style tests that make it obvious which checks change because of the patch.
- Avoid filler instructions that depend on incidental scan limits when a control-flow or dataflow shape can express the same condition directly.
- Avoid target triples only used to bias a cost model if a pass flag can force the path. If a target is required, make that reason explicit.
- For CodeGen tests, use an appropriate subtarget and generated checks when reviewers expect codegen assertions.
- For Clang user-visible diagnostics/crashes, test both the original reproducer when valid and the distilled regression. Add release notes when reviewers request them or the change is user-visible.
- Avoid new `undef` in tests unless truly required. Prefer `poison`, function arguments, or source IR that naturally produces `undef` through an earlier pass.
- Do not weaken a test to "compiles successfully" unless the output is inherently unstable and that tradeoff is explicit.
- Do not commit `-verify-machineinstrs`, extra `verify` passes, branch-on-constant scaffolding, or unneeded target triples/datalayouts.

Run the narrowest tests first, then broaden according to blast radius:

- Rebuild only the needed tool first, for example `ninja -C build opt`, `llc`, `clang`, or `mlir-opt`.
- Run the exact lit file with `build/bin/llvm-lit -q path/to/test`.
- Run directory suites for shared lowering or reusable interfaces.
- For correctness-sensitive transforms, run Alive2 or llubi when applicable.
- Run `ninja -C build check-mlir`, `check-clang`, or `check-llvm` when touching broad infrastructure or when the user asks for all tests.
- Always run `git diff --check` before finalizing.

## PR And Commit Hygiene

LLVM reviewers repeatedly ask for the same PR basics:

- State the motivation and what the PR does. Include the real-world source of the bug or performance issue when known.
- Include `Fixes: https://github.com/llvm/llvm-project/issues/<number>` in commit messages for issue fixes.
- Mention target/architecture boundaries such as gfx generation constraints when behavior is not universal.
- Use commit subjects of the form `[Component] Imperative summary`.
- Prefer two commits for optimizer/codegen fixes when practical: a precommit test/NFC commit, then the fix commit that changes checks.
- Search for duplicate or competing open issues/PRs before posting a new upstream PR.
- When closing a PR, leave a concrete reason. Do not silently close or abandon context.
- Ping politely and no more than about weekly unless the PR is blocking main or premerge.
- If approved and green but lacking commit access, ask a reviewer to merge.
- Do not add `Co-Authored-By: Claude`, "Generated with Claude", or similar Claude attribution to LLVM commits. Do not add AI attribution automatically; if the user explicitly asks for LLVM policy disclosure, use an `Assisted-by:` trailer instead of `Co-Authored-By:`.

## Reviewer Response Style

When responding to review:

- Answer the precise concern with evidence: local reproduction, pass output, generated IR/MIR, target docs, or a reduced example.
- If the reviewer points to a better abstraction or naming, usually take it.
- If unsure about intended API behavior, ask a concise semantics question and list viable behaviors.
- When a comment implies a broader follow-up, separate the current fix from the follow-up unless the current patch is incomplete without it.
- Avoid overclaiming performance or correctness; state what was tested and what remains a tradeoff.

For detailed review patterns observed from prior LLVM PRs, read [reviewer-patterns.md](references/reviewer-patterns.md).

## Closing Checklist

Before finishing LLVM work, verify:

- Pre-fix behavior was reproduced and post-fix behavior was observed locally.
- Checks were regenerated with the relevant update script, then inspected.
- No stray debug prints, verbose comments, `verify`/`-verify-machineinstrs`, or unneeded target setup remain.
- Relevant lit tests and any applicable Alive2/llubi checks passed.
- Commits, if created, are split logically, use `[Component]` subjects, include `Fixes:` where appropriate, and avoid Claude attribution.
