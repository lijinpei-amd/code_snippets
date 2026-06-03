#!/usr/bin/env bash
# PreToolUse hook (Bash). Fires even under `bypassPermissions`, re-introducing a
# confirmation prompt for selected publishing actions. FAIL-CLOSED: any internal
# error, or anything it cannot prove safe, emits an "ask" decision.
#
# Posture: PROVE-OR-ASK. A `git push` is permitted silently ONLY when ALL hold
# (otherwise ASK):
#   * the push segment has no force form (--force/-f/--force-with-lease/+refspec),
#     no delete/rewrite (--delete/-d/--mirror/--prune/`:dst` refspec), and no
#     remote is configured to force-push (remote.*.push starting with `+`);
#   * the command does not ALSO create commits (commit/merge/rebase/cherry-pick/
#     revert/am) — those would be pushed but don't exist yet at hook time, so
#     their messages can't be scanned for issue refs;
#   * the push targets the current branch with no explicit/broad refspec we
#     cannot map to a local commit range (--all/--tags/`src:dst`/another branch);
#   * none of the commits it would send reference a GitHub issue
#     (#N, GH-N, owner/repo#N, or an issue/pull URL).
# `gh` -> ASK for pr/issue create|comment|review|... and `gh api` writes.
#
# Compound commands (a && b ; c | d, and backslash-newline continuations) are
# normalized and split, and EVERY segment is evaluated — so a gh publish chained
# after a safe push, or a force push on a continued line, is still caught.
#
# Emits permissionDecision "ask". (Swap emit_ask's body for `exit 2` if you want
# a hard, unapprovable block instead of a prompt.)

set -Eeuo pipefail

# ---- fail-closed output (works even if jq is missing) ----------------------
# Reasons must contain no " or \ (all call sites use static strings).
emit_ask() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}
# Fail closed on any UNEXPECTED error — but only from the top-level shell.
# errtrace (-E) inherits this trap into $()/pipeline subshells; if it emitted
# there, the JSON would be captured by the command substitution instead of
# reaching real stdout (a silent leak). So emit only at BASH_SUBSHELL==0 — a
# sub-shell failure propagates out and re-triggers ERR here at the top level.
on_err() { [ "${BASH_SUBSHELL:-0}" -eq 0 ] && emit_ask "publish-guard: internal error — confirm manually."; true; }
trap on_err ERR
ask() { emit_ask "$1"; }

command -v jq  >/dev/null 2>&1 || emit_ask "publish-guard: jq unavailable — confirm manually."
command -v git >/dev/null 2>&1 || emit_ask "publish-guard: git unavailable — confirm manually."

input=$(cat) || emit_ask "publish-guard: cannot read hook input — confirm manually."
[ -z "${input//[[:space:]]/}" ] && emit_ask "publish-guard: empty hook input — confirm manually."
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty') \
  || emit_ask "publish-guard: cannot parse hook input — confirm manually."
[ -z "$cmd" ] && exit 0

# Normalize: collapse backslash-newline continuations to a space, turn any
# remaining real newlines into `;` so they split as separate commands.
norm=$(printf '%s' "$cmd" | sed -E ':a;N;$!ba; s/\\\n/ /g; s/\n/ ; /g')

# Resolve the repo dir: payload cwd, then a leading `cd DIR`, then `git -C DIR`.
base=$(printf '%s' "$input" | jq -r '.cwd // empty') \
  || emit_ask "publish-guard: cannot parse hook input — confirm manually."
[ -z "$base" ] && base=$PWD
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; s="${s%\"}"; s="${s#\"}"; s="${s%\'}"; s="${s#\'}"; printf '%s' "$s"; }
resolve() { case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$base" "$1";; esac; }
cdpart=$(printf '%s' "$norm" | sed -nE 's/^[[:space:]]*cd[[:space:]]+([^&;|]+)(&&|;|\|).*/\1/p')
[ -n "$cdpart" ] && base=$(resolve "$(trim "$cdpart")")
gitdir="$base"
cdir=$(printf '%s' "$norm" | grep -oE '(^|[[:space:]])-C[[:space:]]+[^[:space:]]+' | head -n1 | sed -E 's/.*-C[[:space:]]+//') || true
[ -n "$cdir" ] && gitdir=$(resolve "$(trim "$cdir")")

ISSUE_RE='#[0-9]+|[Gg][Hh]-[0-9]+|github\.com/[^[:space:]]+/(issues|pull)/[0-9]+'
PUSH_RE='(^|[^[:alnum:]_/.-])git([[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)'

# Does the WHOLE command create commits whose messages we can't see yet?
creates_commits() {
  printf '%s' "$norm" | grep -Eq '(^|[^[:alnum:]_/.-])git([[:space:]]+[^[:space:]]+)*[[:space:]]+(commit|merge|rebase|cherry-pick|revert|am)([[:space:]]|$)'
}

handle_push_segment() {
  local seg="$1"

  # (a) force push: rewrites remote history.
  if printf '%s' "$seg" | grep -Eq '(^|[[:space:]])(--force|--force-with-lease|--force-if-includes)([[:space:]=]|$)' \
     || printf '%s' "$seg" | grep -Eq '(^|[[:space:]])-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$)' \
     || printf '%s' "$seg" | grep -Eq '(^|[[:space:]])\+[^[:space:]:]+'; then
    ask "Force push — may overwrite remote history / lose data. Confirm before running."
  fi
  # (b) delete / mirror / prune / colon-delete refspec: removes remote refs.
  if printf '%s' "$seg" | grep -Eq '(^|[[:space:]])(--delete|-d|--mirror|--prune)([[:space:]]|$)' \
     || printf '%s' "$seg" | grep -Eq '(^|[[:space:]]):[^[:space:]]+'; then
    ask "Push deletes/prunes/mirrors remote refs — may remove remote data. Confirm before running."
  fi
  # (c) a remote configured to force-push turns a plain push into a force push.
  local pcfg=""
  pcfg=$(git -C "$gitdir" config --get-regexp '^remote\..*\.push$' 2>/dev/null) || pcfg=""
  if printf '%s' "$pcfg" | grep -Eq '[[:space:]]\+'; then
    ask "A remote is configured to force-push (remote.*.push = +…). Confirm before running."
  fi
  # (d) same-command commits don't exist yet -> their messages can't be scanned.
  if creates_commits; then
    ask "Command also creates commits, so the pushed commits can't be scanned for issue refs yet. Confirm before running."
  fi

  # (e) only trust the HEAD-based range for a push of the CURRENT branch with no
  #     explicit/broad refspec; otherwise we can't map the push to a local range.
  if printf '%s' "$seg" | grep -Eq '(^|[[:space:]])(--all|--tags|--mirror)([[:space:]]|$)'; then
    ask "Push targets multiple/all refs we can't map to local commits. Confirm before running."
  fi
  local after npos saw_refspec cb cur tok
  after=$(printf '%s' "$seg" | sed -E 's/.*[[:space:]]push([[:space:]]|$)/ /')
  npos=0; saw_refspec=0; cb=""
  cur=$(git -C "$gitdir" symbolic-ref --short HEAD 2>/dev/null) || cur=""
  for tok in $after; do
    case "$tok" in
      -*)  : ;;                                  # flag, ignore
      *:*) saw_refspec=1; npos=$((npos + 1)) ;;  # src:dst refspec -> can't map
      *)   npos=$((npos + 1)); cb="$tok" ;;      # positional (remote or branch)
    esac
  done
  if [ "$saw_refspec" -eq 1 ]; then
    ask "Push uses an explicit refspec we can't map to local commits. Confirm before running."
  fi
  # npos 0 (=`git push`) or 1 (=`git push <remote>`) both push the current branch.
  # npos 2 is fine only when the 2nd positional is exactly the current branch.
  if [ "$npos" -ge 2 ] && ! { [ "$npos" -eq 2 ] && [ -n "$cur" ] && [ "$cb" = "$cur" ]; }; then
    ask "Push targets explicit refs we can't map to local commits. Confirm before running."
  fi

  # (f) scan the commits that would actually be pushed for issue references.
  local msgs
  if   msgs=$(git -C "$gitdir" log --format=%B @{push}..HEAD     2>/dev/null); then :
  elif msgs=$(git -C "$gitdir" log --format=%B @{upstream}..HEAD 2>/dev/null); then :
  elif msgs=$(git -C "$gitdir" log --format=%B HEAD --not --remotes 2>/dev/null); then :
  else ask "Couldn't determine which commits would be pushed. Confirm before running."; fi
  if printf '%s' "$msgs" | grep -Eq "$ISSUE_RE"; then
    ask "A commit being pushed references a GitHub issue (adds noise to its timeline). Confirm before running."
  fi
  # proven safe for this push segment -> return; remaining segments still checked.
}

# Split into segments on && || | ; & and evaluate EACH (no early exit).
segs=$(printf '%s' "$norm" | sed -E 's/(\|\||&&|[;&|])/\n/g')
while IFS= read -r seg; do
  [ -z "${seg//[[:space:]]/}" ] && continue
  if printf '%s' "$seg" | grep -Eq "$PUSH_RE"; then
    handle_push_segment "$seg"
  fi
  if printf '%s' "$seg" | grep -Eq '(^|[^[:alnum:]_/.-])gh[[:space:]]+(pr|issue)[[:space:]]+(create|comment|review|merge|close|reopen|edit|ready)([[:space:]]|$)'; then
    ask "Publishing to a GitHub PR/issue. Confirm before running."
  fi
  if printf '%s' "$seg" | grep -Eq '(^|[^[:alnum:]_/.-])gh[[:space:]]+api[[:space:]].*(comments|/pulls|/issues)'; then
    ask "gh api write to comments/pulls/issues. Confirm before running."
  fi
done <<< "$segs"

exit 0
