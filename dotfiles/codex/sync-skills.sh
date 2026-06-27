#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source_skills_dir="$script_dir/dot-codex/skills"
codex_home="${CODEX_HOME:-$HOME/.codex}"
target_skills_dir="$codex_home/skills"
timestamp="$(date +%Y%m%d-%H%M%S)"

if [[ ! -d "$source_skills_dir" ]]; then
    echo "missing source skills directory: $source_skills_dir" >&2
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

    if [[ -L "$target_skill" && "$(readlink -- "$target_skill")" == "$source_skill" ]]; then
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
