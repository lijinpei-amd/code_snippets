#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/sync-skills-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

fixture="$tmp/codex-dotfiles"
source_skills="$fixture/dot-codex/skills"
mkdir -p "$source_skills/demo"
cp -- "$repo_root/dotfiles/codex/sync-skills.sh" "$fixture/sync-skills.sh"

# Exact equality used to move the source aside and replace it with a self-link.
if CODEX_HOME="$fixture/dot-codex" bash "$fixture/sync-skills.sh" >/dev/null 2>&1; then
    echo "sync-skills accepted identical source and target roots" >&2
    exit 1
fi
[[ -d "$source_skills/demo" && ! -L "$source_skills" ]]

# Reject a target nested inside the source before mkdir creates anything.
nested_home="$source_skills/nested-home"
if CODEX_HOME="$nested_home" bash "$fixture/sync-skills.sh" >/dev/null 2>&1; then
    echo "sync-skills accepted a target nested inside its source" >&2
    exit 1
fi
[[ ! -e "$nested_home" ]]

# Also reject a source nested inside a symlink-resolved target.
mkdir -p "$tmp/overlap-home"
ln -s -- "$fixture/dot-codex" "$tmp/overlap-home/skills"
if CODEX_HOME="$tmp/overlap-home" bash "$fixture/sync-skills.sh" >/dev/null 2>&1; then
    echo "sync-skills accepted a source nested inside its target" >&2
    exit 1
fi
[[ -d "$source_skills/demo" ]]

# A disjoint destination still links normally and is idempotent.
CODEX_HOME="$tmp/normal-home" bash "$fixture/sync-skills.sh" >/dev/null
target="$tmp/normal-home/skills/demo"
[[ -L "$target" ]]
[[ "$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$target")" \
   == "$source_skills/demo" ]]
CODEX_HOME="$tmp/normal-home" bash "$fixture/sync-skills.sh" >/dev/null

echo "sync-skills overlap checks passed"
