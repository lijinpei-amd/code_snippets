#!/usr/bin/env bash
# Codex PreToolUse hook for Bash. Re-introduces a confirmation gate for selected
# publishing actions even when Codex is running with bypass permissions.
#
# Codex currently supports PreToolUse "deny", but not Claude's "ask" decision.
# To keep confirmation semantics, this hook asks on /dev/tty when a terminal is
# available. Without a terminal, or on any internal error, it fails closed with a
# Codex deny decision.
#
# Posture: PROVE-OR-CONFIRM. A `git push` is permitted silently ONLY when ALL
# hold (otherwise CONFIRM):
#   * the push segment has no force form (--force/-f/--force-with-lease/+refspec),
#     no delete/rewrite (--delete/-d/--mirror/--prune/`:dst` refspec), and no
#     remote is configured to force-push (remote.*.push starting with `+`);
#   * the command does not ALSO create commits (commit/merge/rebase/cherry-pick/
#     revert/am) - those would be pushed but do not exist yet at hook time, so
#     their messages cannot be scanned for issue refs;
#   * the push targets the current branch on the branch's OWN upstream remote,
#     with no explicit/broad refspec we cannot map to a local commit range
#     (--all/--tags/`src:dst`/another branch/another remote);
#   * none of the commits it would send reference a GitHub issue
#     (#N, GH-N, owner/repo#N, or an issue/pull URL).
# `gh` -> CONFIRM for pr/issue create|comment|review|..., release/repo/gist/
# secret/variable/workflow writes, and `gh api` write requests.
#
# Compound commands (a && b ; c | d, and backslash-newline continuations) are
# normalized and split, and EVERY segment is evaluated - so a gh publish chained
# after a safe push, or a force push on a continued line, is still caught. The
# working directory is tracked across `cd` segments and per-segment `git -C` so
# the commit scan runs against the repo the push actually targets.

set -Eeuo pipefail

# ---- fail-closed output (works even if jq is missing) ----------------------
# Reasons must contain no " or \ (all call sites use static strings).
emit_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

confirm_or_deny() {
  local reason="$1"
  local reply=""

  if { exec 3<>/dev/tty; } 2>/dev/null; then
    printf '\nCodex publish guard: %s\n' "$reason" >&3
    printf 'Run this publishing command anyway? [y/N] ' >&3
    if IFS= read -r reply <&3; then
      case "$reply" in
        [yY]|[yY][eE][sS]) exit 0 ;;
      esac
    fi
    exec 3>&-
  fi

  emit_deny "$reason"
}

# Fail closed on any UNEXPECTED error - but only from the top-level shell.
# errtrace (-E) inherits this trap into $()/pipeline subshells; if it emitted
# there, the JSON would be captured by the command substitution instead of
# reaching real stdout (a silent leak). So emit only at BASH_SUBSHELL==0 - a
# sub-shell failure propagates out and re-triggers ERR here at the top level.
on_err() { [ "${BASH_SUBSHELL:-0}" -eq 0 ] && confirm_or_deny "publish-guard: internal error - confirm manually."; true; }
trap on_err ERR
ask() { confirm_or_deny "$1"; }

command -v jq  >/dev/null 2>&1 || confirm_or_deny "publish-guard: jq unavailable - confirm manually."
command -v git >/dev/null 2>&1 || confirm_or_deny "publish-guard: git unavailable - confirm manually."

input=$(cat) || confirm_or_deny "publish-guard: cannot read hook input - confirm manually."
[ -z "${input//[[:space:]]/}" ] && confirm_or_deny "publish-guard: empty hook input - confirm manually."
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) \
  || confirm_or_deny "publish-guard: cannot parse hook input - confirm manually."
[ -z "$cmd" ] && exit 0

# Normalize: collapse backslash-newline continuations to a space, turn any
# remaining real newlines into `;` so they split as separate commands.
norm=$(printf '%s' "$cmd" | sed -E ':a;N;$!ba; s/\\\n/ /g; s/\n/ ; /g')

# Resolve the starting repo dir from the payload cwd; `cd` segments and a
# per-segment `git -C` refine it below.
base=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) \
  || confirm_or_deny "publish-guard: cannot parse hook input - confirm manually."
[ -z "$base" ] && base=$PWD
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; s="${s%\"}"; s="${s#\"}"; s="${s%\'}"; s="${s#\'}"; printf '%s' "$s"; }
resolve_in() { case "$2" in /*) printf '%s' "$2";; *) printf '%s/%s' "$1" "$2";; esac; }

ISSUE_RE='#[0-9]+|[Gg][Hh]-[0-9]+|github\.com/[^[:space:]]+/(issues|pull)/[0-9]+'
PUSH_RE='(^|[^[:alnum:]_/.-])git([[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)'

# Does the WHOLE command create commits whose messages we cannot see yet?
creates_commits() {
  printf '%s' "$norm" | grep -Eq '(^|[^[:alnum:]_/.-])git([[:space:]]+[^[:space:]]+)*[[:space:]]+(commit|merge|rebase|cherry-pick|revert|am)([[:space:]]|$)'
}

# handle_push_segment SEGMENT CWD
handle_push_segment() {
  local seg="$1" cwd="$2"

  # Repo dir for THIS push: the tracked cwd, refined by a `git -C DIR` that
  # belongs to git in this very segment (so a `make -C dir` elsewhere is ignored).
  local gitdir="$cwd" gcdir
  gcdir=$(printf '%s' "$seg" | grep -oE '(^|[^[:alnum:]_/.-])git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -n1 | sed -E 's/.*-C[[:space:]]+//') || true
  [ -n "$gcdir" ] && gitdir=$(resolve_in "$cwd" "$(trim "$gcdir")")

  # (a) force push: rewrites remote history.
  if printf '%s' "$seg" | grep -Eq '(^|[[:space:]])(--force|--force-with-lease|--force-if-includes)([[:space:]=]|$)' \
     || printf '%s' "$seg" | grep -Eq '(^|[[:space:]])-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$)' \
     || printf '%s' "$seg" | grep -Eq '(^|[[:space:]])\+[^[:space:]:]+'; then
    ask "Force push may overwrite remote history or lose data. Confirm before running."
  fi
  # (b) delete / mirror / prune / colon-delete refspec: removes remote refs.
  if printf '%s' "$seg" | grep -Eq '(^|[[:space:]])(--delete|-d|--mirror|--prune)([[:space:]]|$)' \
     || printf '%s' "$seg" | grep -Eq '(^|[[:space:]]):[^[:space:]]+'; then
    ask "Push deletes, prunes, or mirrors remote refs. Confirm before running."
  fi
  # (c) a remote configured to force-push turns a plain push into a force push.
  local pcfg=""
  pcfg=$(git -C "$gitdir" config --get-regexp '^remote\..*\.push$' 2>/dev/null) || pcfg=""
  if printf '%s' "$pcfg" | grep -Eq '[[:space:]]\+'; then
    ask "A remote is configured to force-push with remote.*.push = +... Confirm before running."
  fi
  # (d) same-command commits do not exist yet -> their messages cannot be scanned.
  if creates_commits; then
    ask "Command also creates commits, so pushed commits cannot be scanned for issue refs yet. Confirm before running."
  fi

  # (e) only trust the HEAD-based range for a push of the CURRENT branch with no
  #     explicit/broad refspec; otherwise we cannot map the push to a local range.
  if printf '%s' "$seg" | grep -Eq '(^|[[:space:]])(--all|--tags|--mirror)([[:space:]]|$)'; then
    ask "Push targets multiple or all refs we cannot map to local commits. Confirm before running."
  fi
  local after npos saw_refspec cb cur tok remote_arg
  after=$(printf '%s' "$seg" | sed -E 's/.*[[:space:]]push([[:space:]]|$)/ /')
  npos=0; saw_refspec=0; cb=""; remote_arg=""
  cur=$(git -C "$gitdir" symbolic-ref --short HEAD 2>/dev/null) || cur=""
  for tok in $after; do
    case "$tok" in
      -*)  : ;;                                   # flag, ignore
      *:*) saw_refspec=1; npos=$((npos + 1)) ;;   # src:dst refspec -> cannot map
      *)   npos=$((npos + 1))
           [ "$npos" -eq 1 ] && remote_arg="$tok" # first positional is the remote
           case "$tok" in
             HEAD|@) cb="$cur" ;;                 # HEAD/@ == the current branch
             *)      cb="$tok" ;;
           esac ;;
    esac
  done
  if [ "$saw_refspec" -eq 1 ]; then
    ask "Push uses an explicit refspec we cannot map to local commits. Confirm before running."
  fi
  # npos 0 (= `git push`) or 1 (= `git push <remote>`) both push the current branch.
  # npos 2 is fine only when the 2nd positional is exactly the current branch.
  if [ "$npos" -ge 2 ] && ! { [ "$npos" -eq 2 ] && [ -n "$cur" ] && [ "$cb" = "$cur" ]; }; then
    ask "Push targets explicit refs we cannot map to local commits. Confirm before running."
  fi
  # An explicit remote that is not the branch's upstream means @{push}/@{upstream}
  # below would scan the WRONG remote's range; we cannot map it, so confirm.
  if [ -n "$remote_arg" ] && [ -n "$cur" ]; then
    local up_remote=""
    up_remote=$(git -C "$gitdir" config "branch.$cur.remote" 2>/dev/null) || up_remote=""
    if [ -n "$up_remote" ] && [ "$remote_arg" != "$up_remote" ]; then
      ask "Push targets a remote other than the branch's upstream; cannot map commits to a local range. Confirm before running."
    fi
  fi

  # (f) scan the commits that would actually be pushed for issue references.
  local msgs
  if   msgs=$(git -C "$gitdir" log --format=%B @{push}..HEAD     2>/dev/null); then :
  elif msgs=$(git -C "$gitdir" log --format=%B @{upstream}..HEAD 2>/dev/null); then :
  elif msgs=$(git -C "$gitdir" log --format=%B HEAD --not --remotes 2>/dev/null); then :
  else ask "Could not determine which commits would be pushed. Confirm before running."; fi
  if printf '%s' "$msgs" | grep -Eq "$ISSUE_RE"; then
    ask "A commit being pushed references a GitHub issue. Confirm before running."
  fi
  # proven safe for this push segment -> return; remaining segments still checked.
}

# Split into segments on && || | ; & and evaluate EACH (no early exit).
segs=$(printf '%s' "$norm" | sed -E 's/(\|\||&&|[;&|])/\n/g')
cwd="$base"
while IFS= read -r seg; do
  [ -z "${seg//[[:space:]]/}" ] && continue
  # Track `cd DIR` so later push segments resolve against the right working dir.
  cdtarget=$(printf '%s' "$seg" | sed -nE 's/^[[:space:]]*cd[[:space:]]+("?)([^"&;|]+)\1[[:space:]]*$/\2/p')
  if [ -n "$cdtarget" ]; then
    cwd=$(resolve_in "$cwd" "$(trim "$cdtarget")")
    continue
  fi
  if printf '%s' "$seg" | grep -Eq "$PUSH_RE"; then
    handle_push_segment "$seg" "$cwd"
  fi
  if printf '%s' "$seg" | grep -Eq '(^|[^[:alnum:]_/.-])gh[[:space:]]+(pr|issue)[[:space:]]+(create|comment|review|merge|close|reopen|edit|ready|lock|unlock)([[:space:]]|$)'; then
    ask "Publishing to a GitHub PR or issue. Confirm before running."
  fi
  # Other gh subcommands that publish or mutate remote GitHub state.
  if printf '%s' "$seg" | grep -Eq '(^|[^[:alnum:]_/.-])gh[[:space:]]+release[[:space:]]+(create|edit|delete|upload)([[:space:]]|$)' \
     || printf '%s' "$seg" | grep -Eq '(^|[^[:alnum:]_/.-])gh[[:space:]]+repo[[:space:]]+(create|delete|edit|rename|archive|unarchive|fork|sync|deploy-key)([[:space:]]|$)' \
     || printf '%s' "$seg" | grep -Eq '(^|[^[:alnum:]_/.-])gh[[:space:]]+gist[[:space:]]+(create|edit|delete)([[:space:]]|$)' \
     || printf '%s' "$seg" | grep -Eq '(^|[^[:alnum:]_/.-])gh[[:space:]]+(secret|variable)[[:space:]]+(set|delete|remove)([[:space:]]|$)' \
     || printf '%s' "$seg" | grep -Eq '(^|[^[:alnum:]_/.-])gh[[:space:]]+workflow[[:space:]]+(run|enable|disable)([[:space:]]|$)'; then
    ask "Publishing or modifying a GitHub resource via gh. Confirm before running."
  fi
  # gh api: only WRITE requests (explicit write method, field flags that force a
  # POST, or a GraphQL mutation). Read-only GETs are left alone.
  if printf '%s' "$seg" | grep -Eq '(^|[^[:alnum:]_/.-])gh[[:space:]]+api([[:space:]]|$)' \
     && { printf '%s' "$seg" | grep -Eq '(^|[[:space:]])(-X|--method)([[:space:]]+|=)?(POST|PUT|PATCH|DELETE)' \
          || printf '%s' "$seg" | grep -Eq '(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]]|=)' \
          || printf '%s' "$seg" | grep -Eq 'mutation'; }; then
    ask "gh api write request. Confirm before running."
  fi
done <<< "$segs"

exit 0
