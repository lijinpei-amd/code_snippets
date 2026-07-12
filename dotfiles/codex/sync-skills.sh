#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
timestamp="$(date +%Y%m%d-%H%M%S)"

canonicalize_path() {
    python3 -c 'import os, sys; print(os.path.realpath(os.path.abspath(sys.argv[1])))' "$1"
}

source_skills_dir="$(canonicalize_path "$script_dir/dot-codex/skills")"
codex_home="$(canonicalize_path "${CODEX_HOME:-$HOME/.codex}")"
target_skills_dir="$(canonicalize_path "$codex_home/skills")"

if [[ ! -d "$source_skills_dir" ]]; then
    echo "missing source skills directory: $source_skills_dir" >&2
    exit 1
fi

if [[ "$source_skills_dir" == "$target_skills_dir" \
      || "$source_skills_dir" == "$target_skills_dir"/* \
      || "$target_skills_dir" == "$source_skills_dir"/* ]]; then
    echo "source and target skill roots must not be identical or overlap:" >&2
    echo "  source: $source_skills_dir" >&2
    echo "  target: $target_skills_dir" >&2
    exit 1
fi

mkdir -p "$target_skills_dir"

backup_path() {
    local target="$1"
    local backup="$target.bak-$timestamp"
    local n=1

    while [[ -e "$backup" || -L "$backup" ]]; do
        backup="$target.bak-$timestamp-$n"
        n=$((n + 1))
    done

    printf '%s\n' "$backup"
}

for source_skill in "$source_skills_dir"/*; do
    [[ -d "$source_skill" ]] || continue

    skill_name="$(basename -- "$source_skill")"
    target_skill="$target_skills_dir/$skill_name"

    if [[ -L "$target_skill" \
          && "$(canonicalize_path "$target_skill")" == "$source_skill" ]]; then
        echo "ok: $target_skill -> $source_skill"
        continue
    fi

    if [[ -e "$target_skill" || -L "$target_skill" ]]; then
        backup="$(backup_path "$target_skill")"
        mv -- "$target_skill" "$backup"
        echo "backed up: $target_skill -> $backup"
    fi

    ln -s -- "$source_skill" "$target_skill"
    echo "linked: $target_skill -> $source_skill"
done
