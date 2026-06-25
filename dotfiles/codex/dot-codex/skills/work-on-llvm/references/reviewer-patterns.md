# LLVM Reviewer Patterns

Use this reference when preparing LLVM PR text, responding to review, or deciding whether a proposed patch is reviewer-ready.

## Motivation And Scope

- Reviewers ask for motivation when a PR only describes mechanics. Include both "why this matters" and "what this patch changes."
- For optimizer changes, show where the motivating pattern comes from in real code when possible. A short IR excerpt plus the source context is often enough.
- For target changes, state the architecture boundary. If a property changed across gfx generations, constrain the patch or explain why all targets share the property.
- For performance-motivated changes, separate measured results from theory. Do not assume a microarchitectural argument is universal across VMEM, LDS, SMEM, TDM, or gfx generations.
- If the PR is stacked, say exactly what remains in this PR and which follow-up PR contains the next semantic step.

## Correctness Bar

- Functional correctness must be represented in the program model, not in an optional pass hook. For scheduling dependencies, prefer explicit MIR/operand state such as implicit def-use of a modeling register over a DAG mutation that every scheduler must remember to install.
- Do not use a hardware-counter name for an abstract dependency if future operations may use different counters. Names should describe the modeled state, not one current implementation detail.
- Preserve mandatory dependencies for future users, not only today's known instructions. Reviewers specifically flag asyncmark/wait_asyncmark interactions with future TDM/tensor count operations.
- If an API can be misused, decide whether caller responsibility or defensive API behavior is intended before changing the interface. Ask when uncertain.
- If a proposed transform can introduce poison, UB, or side-effect changes, prove the relevant value is non-poison, not merely non-zero or non-null.
- Preserve flags when folding if the replacement is meant to retain the same semantic guarantees.

## Test Expectations

- Use update scripts for generated checks. Common reviewer requests:
  - `llvm/utils/update_test_checks.py` for IR transform tests.
  - `llvm/utils/update_llc_test_checks.py` for codegen tests.
  - `clang/utils/update_cc_test_checks.py` for Clang CodeGen tests.
- Follow InstCombine precommit-test style when changing an optimization: include tests that show the before/after delta clearly.
- Avoid filler instructions that only exploit an implementation cutoff. Build a dataflow/control-flow shape that makes the information genuinely unavailable where needed.
- If a target triple is only present to bias cost modeling, prefer a pass option that forces the path, then move the test out of a target-specific directory if possible.
- For crash fixes, include the original reproducer if it is valid and a smaller regression if useful. If the original reproducer is invalid, say so and test the valid boundary.
- Avoid `undef` in new tests. Use `poison` or a function argument for an arbitrary value. If an earlier pass creates `undef`, keep the initial IR clean and run the pipeline that creates it.
- Do not remove FileCheck assertions casually. A compile-only RUN line is acceptable only when output is inherently unstable and the test's historical purpose was crash coverage.
- Precommit the test when practical, especially for InstCombine and transform patches, so reviewers can see the exact check delta caused by the fix.
- Test cases should be minimal and readable: avoid branch-on-constant scaffolding, magic constants when function arguments can model the same behavior, and unneeded triples/datalayouts.

## Code Shape

- Take reviewer suggestions that simplify to existing idioms: `isa<AssumeInst>`, `replaceUsesWithIf`, direct operand flags, `SaveAndRestore`, generated ODS accessors, and typed helper APIs.
- If code needs a new helper, prefer a general helper parallel to existing LLVM style rather than a one-off special case.
- Avoid weakening APIs to accept null or malformed values unless that is the actual contract. Prefer a separate optional wrapper around a stricter helper.
- Split unrelated NFC churn, constification, and naming cleanup out of bug-fix patches.
- Keep comments short and specific. Reviewers may call out verbose AI-looking comments; remove prose that only restates code.
- Put detailed rationale in the commit message or PR description rather than long code comments.

## PR Etiquette

- Include the original LLVM issue URL in the commit message using `Fixes:`.
- Use commit subjects like `[InstCombine] Fix assertion in ...` or `[AMDGPU] Preserve ...`.
- Add a release note for user-visible Clang changes when requested, especially diagnostics or frontend crash fixes.
- If a buildbot or premerge failure appears unrelated, inspect enough to say why. Do not ignore it if it plausibly touches your area.
- If closing a PR, leave the reason in the PR conversation.
- Ping at a courteous cadence, roughly weekly for normal review. For blocked main or premerge failures, explain the urgency.
- After approval and green CI, ask a reviewer to merge if the author lacks commit access.
- Do not add Claude attribution such as `Co-Authored-By: Claude` or "Generated with Claude" to LLVM commits.

## Communication

- Prefer "I tested X and observed Y" over speculation.
- When correcting a reviewer assumption, quote the relevant IR/MIR, pass output, or target rule and keep the tone direct.
- If the requested change would broaden scope, propose a follow-up and keep the current patch focused.
- When uncertain, ask a concrete question with 2-3 viable semantics instead of implementing a guessed policy.
