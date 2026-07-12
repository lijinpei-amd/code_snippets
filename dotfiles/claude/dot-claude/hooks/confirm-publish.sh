#!/usr/bin/env bash
# PreToolUse hook (Bash). Fires even under `bypassPermissions`, re-introducing a
# confirmation prompt for selected publishing actions. FAIL-CLOSED: any internal
# error, or anything it cannot prove safe, emits an "ask" decision.
#
# Posture: PROVE-OR-ASK. A `git push` is permitted silently ONLY when ALL hold
# (otherwise ASK):
#   * the push segment has no force form (--force/-f/--force-with-lease/+refspec),
#     no delete/rewrite (--delete/-d/--mirror/--prune/`:dst` refspec), configured
#     remote push refspec, or multi-ref push.default mode;
#   * the command does not ALSO create commits (commit/merge/rebase/cherry-pick/
#     revert/am) — those would be pushed but don't exist yet at hook time, so
#     their messages can't be scanned for issue refs;
#   * the push targets the current branch on the branch's OWN upstream remote,
#     with no explicit/broad refspec we cannot map to a local commit range
#     (--all/--tags/`src:dst`/another branch/another remote);
#   * none of the commits it would send reference a GitHub issue
#     (#N, GH-N, owner/repo#N, or an issue/pull URL).
# `gh` -> ASK for pr/issue create|comment|review|..., release/repo/gist/secret/
# variable/workflow writes, and `gh api` write requests.
#
# Compound commands (a && b ; c | d, and backslash-newline continuations) are
# normalized and split, and EVERY segment is evaluated — so a gh publish chained
# after a safe push, or a force push on a continued line, is still caught. The
# working directory is tracked across `cd` segments and per-segment `git -C` so
# the commit scan runs against the repo the push actually targets.
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

# Resolve the starting repo dir from the payload cwd; `cd` segments and a
# per-segment `git -C` refine it below.
base=$(printf '%s' "$input" | jq -r '.cwd // empty') \
  || emit_ask "publish-guard: cannot parse hook input — confirm manually."
[ -z "$base" ] && base=$PWD
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; s="${s%\"}"; s="${s#\"}"; s="${s%\'}"; s="${s#\'}"; printf '%s' "$s"; }
resolve_in() { case "$2" in /*) printf '%s' "$2";; *) printf '%s/%s' "$1" "$2";; esac; }

ISSUE_RE='#[0-9]+|[Gg][Hh]-[0-9]+|github\.com/[^[:space:]]+/(issues|pull)/[0-9]+'

# Does the WHOLE command create commits whose messages we can't see yet?
creates_commits() {
  printf '%s' "$norm" | grep -Eq '(^|[[:space:]])([^[:space:]]*/)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+(commit|merge|rebase|cherry-pick|revert|am)([[:space:]]|$)'
}

# Return success only for unset/explicitly false Git boolean-style settings.
is_false_git_setting() {
  case "${1,,}" in ""|false|no|off|0) return 0 ;; *) return 1 ;; esac
}

# secure_handle_push_segment SEGMENT GITDIR [PUSH_ARG ...]
# This is deliberately stricter than Git's parser: only options whose effect on
# the pushed ref set is understood reach the destination-range proof below.
secure_handle_push_segment() {
  local seg="$1" gitdir="$2"
  shift 2
  local -a push_args=("$@") fetch_urls=() push_urls=() remotes=()
  local npos=0 cb="" cur="" tok remote_arg="" pcfg="" push_default=""
  local end_options=0 selected_remote="" up_remote="" up_merge=""
  local follow_tags="" push_recurse="" submodule_recurse="" mirror=""
  local fetch_text="" push_text="" receivepack_cfg="" push_url=""
  local listing="" oid="" ref="" extra="" msgs=""

  cur=$(git -C "$gitdir" symbolic-ref --short HEAD 2>/dev/null) || cur=""
  [ -n "$cur" ] || ask "Detached HEAD cannot be mapped to one destination branch. Confirm before running."
  if creates_commits; then
    ask "Command also creates commits, so the pushed commits can't be scanned for issue refs yet. Confirm before running."
  fi

  for tok in "${push_args[@]}"; do
    if [ "$end_options" -eq 0 ]; then
      case "$tok" in
        --force|--force=*|--force-w*|--force-i*)
          ask "Force push may overwrite remote history or lose data. Confirm before running." ;;
        --del*|--mi*|--pru*)
          ask "Push deletes, prunes, or mirrors remote refs. Confirm before running." ;;
        --al|--all|--br*|--ta*|--follow-tag*)
          ask "Push targets multiple branches or tags. Confirm before running." ;;
        --rep|--rep=*|--repo|--repo=*)
          ask "Push uses a --repo destination override we can't map safely. Confirm before running." ;;
        --recurse-submodules=no|--no-recurse-submodules)
          continue ;;
        --recurse-submodule*)
          ask "Recursive submodule pushing can publish commits outside the scanned range. Confirm before running." ;;
        --dry-run|--porcelain|--quiet|--verbose|--no-verify|--verify|--atomic|--no-atomic|--signed|--signed=*|--no-signed|--ipv4|--ipv6|--progress|--no-progress|--thin|--no-thin|--set-upstream)
          continue ;;
        --)
          end_options=1
          continue ;;
      esac
      if [[ "$tok" =~ ^-[A-Za-z]*[fF][A-Za-z]*$ ]]; then
        ask "Force push may overwrite remote history or lose data. Confirm before running."
      fi
      if [[ "$tok" =~ ^-[A-Za-z]*[dD][A-Za-z]*$ ]]; then
        ask "Push deletes remote refs. Confirm before running."
      fi
      if [[ "$tok" =~ ^-[nqv46u]+$ ]]; then
        continue
      fi
      if [[ "$tok" == -* ]]; then
        ask "Push uses an option the guard can't prove preserves one current-branch ref. Confirm before running."
      fi
    fi

    if [[ "$tok" == +* ]]; then
      ask "Force push may overwrite remote history or lose data. Confirm before running."
    fi
    if [[ "$tok" == :* ]]; then
      ask "Push deletes remote refs. Confirm before running."
    fi
    if [[ "$tok" == *:* ]]; then
      ask "Push uses an explicit refspec we can't map to one destination. Confirm before running."
    fi
    npos=$((npos + 1))
    [ "$npos" -eq 1 ] && remote_arg="$tok"
    case "$tok" in HEAD|@) cb="$cur" ;; *) cb="$tok" ;; esac
  done

  if [ "$npos" -ge 2 ] && ! { [ "$npos" -eq 2 ] && [ "$cb" = "$cur" ]; }; then
    ask "Push targets explicit refs we can't map to local commits. Confirm before running."
  fi

  if [ "$npos" -le 1 ]; then
    pcfg=$(git -C "$gitdir" config --get-regexp '^remote\..*\.push$' 2>/dev/null) || pcfg=""
    if printf '%s' "$pcfg" | grep -Eq '[[:space:]]\+'; then
      ask "A remote is configured to force-push with remote.*.push = +... Confirm before running."
    elif [ -n "$pcfg" ]; then
      ask "A remote has configured push refspecs that may select other branches. Confirm before running."
    fi
    push_default=$(git -C "$gitdir" config --get push.default 2>/dev/null) || push_default=""
    case "${push_default:-simple}" in
      current|simple|upstream|tracking) ;;
      matching) ask "push.default=matching may publish multiple branches. Confirm before running." ;;
      *) ask "The configured push.default mode can't be proven to publish only the current branch. Confirm before running." ;;
    esac
  fi

  follow_tags=$(git -C "$gitdir" config --get push.followTags 2>/dev/null) || follow_tags=""
  is_false_git_setting "$follow_tags" \
    || ask "push.followTags can publish tags outside the scanned branch range. Confirm before running."
  push_recurse=$(git -C "$gitdir" config --get push.recurseSubmodules 2>/dev/null) || push_recurse=""
  submodule_recurse=$(git -C "$gitdir" config --get submodule.recurse 2>/dev/null) || submodule_recurse=""
  is_false_git_setting "$push_recurse" && is_false_git_setting "$submodule_recurse" \
    || ask "Git configuration can recursively push submodule commits. Confirm before running."

  if [ -n "$remote_arg" ]; then
    up_remote=$(git -C "$gitdir" config "branch.$cur.remote" 2>/dev/null) || up_remote=""
    up_merge=$(git -C "$gitdir" config "branch.$cur.merge" 2>/dev/null) || up_merge=""
    [ -n "$up_remote" ] \
      || ask "Push names a remote but the current branch has no upstream; can't map commits to that destination. Confirm before running."
    [ "$remote_arg" = "$up_remote" ] \
      || ask "Push targets a remote other than the branch's upstream; can't map commits to a local range. Confirm before running."
    [ "$up_merge" = "refs/heads/$cur" ] \
      || ask "The current branch's upstream has a different name; can't map this push to one destination ref. Confirm before running."
    selected_remote="$remote_arg"
  else
    selected_remote=$(git -C "$gitdir" config "branch.$cur.pushRemote" 2>/dev/null) || selected_remote=""
    if [ -z "$selected_remote" ]; then
      selected_remote=$(git -C "$gitdir" config remote.pushDefault 2>/dev/null) || selected_remote=""
    fi
    if [ -z "$selected_remote" ]; then
      selected_remote=$(git -C "$gitdir" config "branch.$cur.remote" 2>/dev/null) || selected_remote=""
    fi
    if [ -z "$selected_remote" ]; then
      mapfile -t remotes < <(git -C "$gitdir" remote)
      [ "${#remotes[@]}" -eq 1 ] \
        || ask "The effective push remote is ambiguous. Confirm before running."
      selected_remote=${remotes[0]}
    fi
    if [ "${push_default:-simple}" != current ]; then
      up_remote=$(git -C "$gitdir" config "branch.$cur.remote" 2>/dev/null) || up_remote=""
      up_merge=$(git -C "$gitdir" config "branch.$cur.merge" 2>/dev/null) || up_merge=""
      [ -n "$up_remote" ] && [ "$up_merge" = "refs/heads/$cur" ] \
        || ask "The current branch has no same-name upstream for this push mode. Confirm before running."
    fi
  fi

  [ -n "$selected_remote" ] && [[ "$selected_remote" != -* ]] \
    || ask "The effective push remote is invalid. Confirm before running."
  git -C "$gitdir" remote | grep -Fx -- "$selected_remote" >/dev/null \
    || ask "The push destination isn't one configured remote. Confirm before running."

  mirror=$(git -C "$gitdir" config --get "remote.$selected_remote.mirror" 2>/dev/null) || mirror=""
  is_false_git_setting "$mirror" \
    || ask "The selected remote is configured as a mirror and can publish all refs. Confirm before running."
  if git -C "$gitdir" config --get-all "remote.$selected_remote.pushurl" >/dev/null 2>&1; then
    ask "The selected remote has a pushurl that can differ from fetched state. Confirm before running."
  fi
  receivepack_cfg=$(git -C "$gitdir" config --get "remote.$selected_remote.receivepack" 2>/dev/null) || receivepack_cfg=""
  [ -z "$receivepack_cfg" ] \
    || ask "The selected remote overrides receive-pack, so its destination can't be verified safely. Confirm before running."

  fetch_text=$(git -C "$gitdir" remote get-url --all "$selected_remote" 2>/dev/null) \
    || ask "Couldn't resolve the selected remote URL. Confirm before running."
  push_text=$(git -C "$gitdir" remote get-url --push --all "$selected_remote" 2>/dev/null) \
    || ask "Couldn't resolve the selected push URL. Confirm before running."
  [ -n "$fetch_text" ] && [ -n "$push_text" ] \
    || ask "The selected remote has no verifiable URL. Confirm before running."
  mapfile -t fetch_urls <<< "$fetch_text"
  mapfile -t push_urls <<< "$push_text"
  [ "${#fetch_urls[@]}" -eq 1 ] && [ "${#push_urls[@]}" -eq 1 ] \
    || ask "The selected remote has multiple fetch or push destinations. Confirm before running."
  push_url=${push_urls[0]}
  [ "$push_url" = "${fetch_urls[0]}" ] \
    || ask "The effective push URL differs from fetched state. Confirm before running."
  case "$push_url" in -*|*::*)
    ask "The effective push transport isn't safe to query automatically. Confirm before running." ;;
  esac

  command -v timeout >/dev/null 2>&1 \
    || ask "timeout is unavailable, so the push destination can't be queried safely. Confirm before running."
  listing=$(timeout 10s env GIT_TERMINAL_PROMPT=0 git -C "$gitdir" \
      ls-remote --refs -- "$push_url" "refs/heads/$cur" 2>/dev/null) \
    || ask "Couldn't query the actual push destination. Confirm before running."
  if [ -z "$listing" ]; then
    msgs=$(git -C "$gitdir" log --format=%B HEAD 2>/dev/null) \
      || ask "Couldn't scan commits for a new destination branch. Confirm before running."
  else
    [ "$(printf '%s\n' "$listing" | wc -l)" -eq 1 ] \
      || ask "The destination query returned an ambiguous ref. Confirm before running."
    read -r oid ref extra <<< "$listing"
    [[ "$oid" =~ ^[0-9a-fA-F]{40,64}$ ]] && [ "$ref" = "refs/heads/$cur" ] && [ -z "$extra" ] \
      || ask "The destination query returned an invalid ref. Confirm before running."
    git -C "$gitdir" cat-file -e "$oid^{commit}" 2>/dev/null \
      || ask "The destination commit isn't available locally for scanning. Confirm before running."
    git -C "$gitdir" merge-base --is-ancestor "$oid" HEAD 2>/dev/null \
      || ask "The destination branch isn't a local ancestor of HEAD. Confirm before running."
    msgs=$(git -C "$gitdir" log --format=%B "$oid..HEAD" 2>/dev/null) \
      || ask "Couldn't scan the actual pushed commit range. Confirm before running."
  fi
  if printf '%s' "$msgs" | grep -Eq "$ISSUE_RE"; then
    ask "A commit being pushed references a GitHub issue (adds noise to its timeline). Confirm before running."
  fi
}

# inspect_git_segment SEGMENT CWD
# Parse enough of Git's global-option grammar to identify the subcommand without
# executing it. Noncanonical forms are rejected only when they lead to push or a
# configured/unknown alias; ordinary commands such as status and log stay silent.
inspect_git_segment() {
  local seg="$1" cwd="$2" idx=0 i subcmd="" raw_subcmd="" alias_value="" gitdir="$cwd"
  local noncanonical=0 sensitive_env=0 global_unsafe=0 c_count=0 malformed=0
  local first="" wrapper="" exec_token="" c_arg=""
  local -a words=() global_args=()
  read -r -a words <<< "$seg"
  [ "${#words[@]}" -gt 0 ] || return 0

  # Leading shell assignments are permitted for ordinary Git commands, but any
  # push using them is noncanonical; GIT_* selectors get a more specific reason.
  while [ "$idx" -lt "${#words[@]}" ]       && [[ "${words[$idx]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    case "${words[$idx]}" in
      GIT_DIR=*|GIT_WORK_TREE=*|GIT_NAMESPACE=*|GIT_COMMON_DIR=*|GIT_OBJECT_DIRECTORY=*|GIT_ALTERNATE_OBJECT_DIRECTORIES=*|GIT_CONFIG*=*)
        sensitive_env=1 ;;
    esac
    noncanonical=1
    idx=$((idx + 1))
  done
  [ "$idx" -lt "${#words[@]}" ] || return 0
  exec_token=$(trim "${words[$idx]}")
  [ "$exec_token" = "${words[$idx]}" ] || noncanonical=1
  first=${exec_token##*/}

  case "$first" in
    git)
      [ "$exec_token" = git ] || noncanonical=1
      idx=$((idx + 1))
      ;;
    command)
      wrapper=command
      noncanonical=1
      idx=$((idx + 1))
      while [ "${words[$idx]:-}" = -p ] || [ "${words[$idx]:-}" = -- ]; do
        idx=$((idx + 1))
      done
      exec_token=$(trim "${words[$idx]:-}")
      [ "$exec_token" = "${words[$idx]:-}" ] || noncanonical=1
      [ "${exec_token##*/}" = git ] || return 0
      [ "$exec_token" = git ] || noncanonical=1
      idx=$((idx + 1))
      ;;
    env)
      wrapper=env
      noncanonical=1
      idx=$((idx + 1))
      while [ "$idx" -lt "${#words[@]}" ]; do
        case "${words[$idx]}" in
          --) idx=$((idx + 1)); break ;;
          -i|--ignore-environment|-0|--null) idx=$((idx + 1)) ;;
          -u|-C|--unset|--chdir)
            [ $((idx + 1)) -lt "${#words[@]}" ] || return 0
            idx=$((idx + 2))
            ;;
          --unset=*|--chdir=*) idx=$((idx + 1)) ;;
          [A-Za-z_][A-Za-z0-9_]*=*)
            case "${words[$idx]}" in
              GIT_DIR=*|GIT_WORK_TREE=*|GIT_NAMESPACE=*|GIT_COMMON_DIR=*|GIT_OBJECT_DIRECTORY=*|GIT_ALTERNATE_OBJECT_DIRECTORIES=*|GIT_CONFIG*=*)
                sensitive_env=1 ;;
            esac
            idx=$((idx + 1))
            ;;
          -*) idx=$((idx + 1)) ;;
          *) break ;;
        esac
      done
      exec_token=$(trim "${words[$idx]:-}")
      [ "$exec_token" = "${words[$idx]:-}" ] || noncanonical=1
      [ "${exec_token##*/}" = git ] || return 0
      [ "$exec_token" = git ] || noncanonical=1
      idx=$((idx + 1))
      ;;
    *)
      return 0
      ;;
  esac

  # Catch quoted/otherwise tokenized command-local selectors after recognizing a
  # real Git invocation; do not fire merely because an echo argument says GIT_DIR.
  if printf '%s' "$seg" | grep -Eq '(^|[[:space:]])GIT_(DIR|WORK_TREE|NAMESPACE|COMMON_DIR|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|CONFIG[^=[:space:]]*)(=|[[:space:]])'; then
    sensitive_env=1
  fi

  # Preserve the global arguments for an alias lookup in the exact selected repo.
  # A single, separate `-C DIR` is the only global form allowed for a push.
  while [ "$idx" -lt "${#words[@]}" ]; do
    case "${words[$idx]}" in
      -C)
        if [ $((idx + 1)) -ge "${#words[@]}" ]; then malformed=1; break; fi
        c_arg=$(trim "${words[$((idx + 1))]}")
        [ "$c_arg" = "${words[$((idx + 1))]}" ] || noncanonical=1
        global_args+=("-C" "$c_arg")
        gitdir=$(resolve_in "$gitdir" "$c_arg")
        c_count=$((c_count + 1))
        idx=$((idx + 2))
        ;;
      -c|--config-env|--git-dir|--work-tree|--namespace)
        if [ $((idx + 1)) -ge "${#words[@]}" ]; then malformed=1; break; fi
        global_args+=("${words[$idx]}" "${words[$((idx + 1))]}")
        global_unsafe=1
        idx=$((idx + 2))
        ;;
      -c?*|--config-env=*|--git-dir=*|--work-tree=*|--namespace=*|--bare|--no-replace-objects)
        global_args+=("${words[$idx]}")
        global_unsafe=1
        idx=$((idx + 1))
        ;;
      --)
        global_args+=("--")
        idx=$((idx + 1))
        break
        ;;
      -*)
        global_args+=("${words[$idx]}")
        global_unsafe=1
        idx=$((idx + 1))
        ;;
      *)
        break
        ;;
    esac
  done

  # If an unknown option's value confused the lightweight parser, a later literal
  # push token still makes the invocation fail closed.
  if [ "$global_unsafe" -eq 1 ] || [ "$c_count" -gt 1 ] || [ "$malformed" -eq 1 ]; then
    for ((i=idx; i<${#words[@]}; i++)); do
      if [ "${words[$i]}" = push ]; then
        ask "Git invocation uses unmodeled global options or multiple -C arguments. Confirm before running."
      fi
    done
  fi

  [ "$idx" -lt "${#words[@]}" ] || return 0
  raw_subcmd=${words[$idx]}
  subcmd=$(trim "$raw_subcmd")
  [ "$subcmd" = "$raw_subcmd" ] || noncanonical=1
  idx=$((idx + 1))
  if [ "$subcmd" = push ]; then
    [ "$sensitive_env" -eq 0 ]       || ask "Command-local Git environment can redirect or reconfigure the push. Confirm before running."
    [ "$noncanonical" -eq 0 ]       || ask "Noncanonical, wrapped, or path-qualified Git invocation can't be proven safe. Confirm before running."
    [ "$global_unsafe" -eq 0 ] && [ "$c_count" -le 1 ] && [ "$malformed" -eq 0 ]       || ask "Git invocation uses unmodeled global options or multiple -C arguments. Confirm before running."
    secure_handle_push_segment "$seg" "$gitdir" "${words[@]:$idx}"
    return 0
  fi

  # read -a does not honor shell quoting. If a quoted/escaped global argument
  # was split into several words, never let a later real push token disappear
  # behind the bogus subcommand selected above.
  for ((i=idx; i<${#words[@]}; i++)); do
    if [ "$(trim "${words[$i]}")" = push ]; then
      ask "Git invocation contains a later push token that couldn't be parsed canonically. Confirm before running."
    fi
  done

  alias_value=$(git -C "$cwd" "${global_args[@]}" config --get "alias.$subcmd" 2>/dev/null) || alias_value=""
  [ -z "$alias_value" ]     || ask "Configured Git alias invocation may hide a publishing command. Confirm before running."

  # Repository/config selectors may hide an alias in a context the lightweight
  # lookup could not reproduce (notably command-leading GIT_DIR/GIT_CONFIG_*).
  # Known built-ins cannot be replaced by aliases and remain silent.
  if [ "$sensitive_env" -eq 1 ] || [ "$global_unsafe" -eq 1 ] || [ "$malformed" -eq 1 ]; then
    case "$subcmd" in
      add|am|annotate|apply|archive|bisect|blame|branch|bundle|checkout|cherry|cherry-pick|clean|clone|commit|config|describe|diff|difftool|fetch|format-patch|fsck|gc|grep|help|init|log|maintenance|merge|merge-base|mv|notes|pull|range-diff|rebase|reflog|remote|reset|restore|rev-list|rev-parse|rm|show|show-branch|sparse-checkout|status|submodule|switch|tag|version|worktree)
        return 0 ;;
      *)
        ask "Unmodeled Git configuration may hide a publishing alias. Confirm before running." ;;
    esac
  fi
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
  inspect_git_segment "$seg" "$cwd"
  if printf '%s' "$seg" | grep -Eq '(^|[^[:alnum:]_/.-])gh[[:space:]]+(pr|issue)[[:space:]]+(create|comment|review|merge|close|reopen|edit|ready|lock|unlock)([[:space:]]|$)'; then
    ask "Publishing to a GitHub PR/issue. Confirm before running."
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
