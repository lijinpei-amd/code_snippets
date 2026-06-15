#!/usr/bin/env bash
# Rename a tmux session after its working directory. Invoked from the
# `session-created` hook in dot-tmux.conf:
#
#     set-hook -g session-created "run-shell \"~/.tmux/name-session.sh '#{session_id}'\""
#
# tmux expands #{session_id} to a stable identifier (e.g. "$3") before running
# this script, so we target that id explicitly and stay correct even if other
# sessions are created or renamed concurrently. The hook single-quotes the
# format so /bin/sh does not expand "$3" as a positional parameter -- see the
# comment in dot-tmux.conf.
#
# Naming scheme:
#   .../development/workspace/<NN>/...  ->  ws<NN>   (one session per worktree)
#   anything else                       ->  directory basename
# Many worktrees share the same leaf directory (llvm-project/llvm, .../clang),
# so the basename alone collapses them; the workspace number disambiguates and
# matches the existing ws<NN> naming convention.
#
# Set NAME_SESSION_FORCE=1 to skip the default-name guard below, e.g. to
# retro-name sessions that were created before this hook existed.
set -euo pipefail

sid="${1:-}"
[ -n "$sid" ] || exit 0

# Current (pre-rename) session name.
cur=$(tmux display-message -p -t "$sid" '#{session_name}' 2>/dev/null) || exit 0

# Only auto-name sessions that still carry tmux's default, auto-generated name
# (a bare integer like "0", "1", ...). A session created with an explicit
# `new-session -s NAME` has a non-numeric name; leave that intentional name
# alone rather than clobbering it. NAME_SESSION_FORCE=1 overrides this.
if [ "${NAME_SESSION_FORCE:-}" != 1 ]; then
  case "$cur" in
    '' | *[!0-9]*) exit 0 ;;
  esac
fi

# Working directory of the session's active pane. For a brand-new session this
# is the directory it was created in.
dir=$(tmux display-message -p -t "$sid" '#{pane_current_path}' 2>/dev/null) || exit 0
[ -n "$dir" ] || exit 0

case "$dir" in
  */development/workspace/*)
    seg=${dir#*/development/workspace/}   # drop everything up to the NN segment
    seg=${seg%%/*}                         # keep only that first path component
    base="ws$seg"
    ;;
  *)
    base=$(basename -- "$dir")
    ;;
esac

# tmux session names may not contain '.' or ':'; map both to '_'.
base=$(printf '%s' "$base" | tr '.:' '__')
[ -n "$base" ] || exit 0

# Already correctly named. Skipping here also stops the dedup loop below from
# matching the session against its own name and bumping it to "<name>-2".
if [ "$cur" = "$base" ]; then
  exit 0
fi

# Deduplicate: if the desired name is already taken by another session, append
# -2, -3, ... "=$name" forces an exact (non-fuzzy) has-session match.
name="$base"
n=2
while tmux has-session -t "=$name" 2>/dev/null; do
  name="$base-$n"
  n=$((n + 1))
done

# Guard the rename: the session may have been destroyed in the meantime, or a
# concurrent creation may have just taken "$name" (has-session -> rename is not
# atomic). Fail quietly rather than letting set -e surface a run-shell error.
tmux rename-session -t "$sid" "$name" 2>/dev/null || exit 0
