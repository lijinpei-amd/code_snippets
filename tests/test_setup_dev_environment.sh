#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKER_BIN="${DOCKER:-docker}"

UBUNTU_IMAGE="${SETUP_TEST_UBUNTU_IMAGE:-ubuntu:24.04}"
ARCH_IMAGE="${SETUP_TEST_ARCH_IMAGE:-archlinux:latest}"

CONTEXT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/setup-dev-environment-context.XXXXXX")
DOCKERFILE="$CONTEXT_DIR/tests/setup_dev_environment.Dockerfile"
IMAGE_TAGS=()

cleanup() {
    local status=$?
    local tag

    trap - EXIT
    for tag in "${IMAGE_TAGS[@]}"; do
        "$DOCKER_BIN" image rm --force "$tag" >/dev/null 2>&1 || true
    done
    rm -rf "$CONTEXT_DIR"
    exit "$status"
}
trap cleanup EXIT

test_activate_staged_tree_stops_when_old_tree_cannot_move() (
    local tmp staged destination fault_destination failed_move=0
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/activate-staged-tree-test.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT
    staged="$tmp/staged"
    destination="$tmp/destination"
    fault_destination=$destination
    mkdir "$staged" "$destination"
    printf '%s\n' new > "$staged/new"
    printf '%s\n' old > "$destination/old"

    # Source only the helper definitions. The script's guarded main must not run.
    # shellcheck source=../setup_dev_environment.sh
    source "$REPO_ROOT/setup_dev_environment.sh"

    # Model a mount point or another destination whose rename is rejected while
    # allowing the helper's other moves to proceed normally.
    mv() {
        local source target
        source=${@: -2:1}
        target=${@: -1}
        if [ "$source" = "$fault_destination" ] && [[ "$target" == "$tmp"/.destination.backup.*/tree ]]; then
            failed_move=1
            return 73
        fi
        command mv "$@"
    }

    if activate_staged_tree "$staged" "$destination"; then
        echo "error: activation succeeded after the existing destination rename failed" >&2
        return 1
    fi

    [ "$(cat "$destination/old")" = old ]
    [ ! -e "$destination/new" ]
    [ "$failed_move" -eq 1 ]
    ! find "$tmp" -path '*/.destination.backup.*/tree' -print -quit | grep -q .
    ! find "$destination" -mindepth 1 -name '.activate-stage.*' -print -quit | grep -q .
)

test_stow_pkg_rolls_back_partial_backup_failure() (
    local tmp backup_moves=0 stow_called=0
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/stow-partial-backup-test.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT

    # shellcheck source=../setup_dev_environment.sh
    source "$REPO_ROOT/setup_dev_environment.sh"
    HOME="$tmp/home"
    STOW_DIR="$tmp/dotfiles"
    mkdir -p "$HOME" "$STOW_DIR/sample"
    printf '%s\n' managed-one > "$STOW_DIR/sample/dot-one"
    printf '%s\n' managed-two > "$STOW_DIR/sample/dot-two"
    printf '%s\n' original-one > "$HOME/.one"
    printf '%s\n' original-two > "$HOME/.two"

    resolve_stow() { return 0; }
    mock_stow() { stow_called=1; return 0; }
    STOW_BIN=mock_stow
    mv() {
        local target
        target=${@: -1}
        if [[ "$target" == "$HOME"/*.bak-* ]]; then
            backup_moves=$((backup_moves + 1))
            if [ "$backup_moves" -eq 2 ]; then
                return 73
            fi
        fi
        command mv "$@"
    }

    if stow_pkg sample; then
        echo "error: stow_pkg succeeded after its second backup move failed" >&2
        return 1
    fi

    [ "$backup_moves" -eq 2 ]
    [ "$stow_called" -eq 0 ]
    [ "$(cat "$HOME/.one")" = original-one ]
    [ "$(cat "$HOME/.two")" = original-two ]
    ! find "$HOME" -name '*.bak-*' -print -quit | grep -q .
)

test_stow_pkg_preserves_replacement_during_partial_rollback() (
    local tmp backup_moves=0 first_target="" first_backup=""
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/stow-concurrent-replacement-test.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT

    # shellcheck source=../setup_dev_environment.sh
    source "$REPO_ROOT/setup_dev_environment.sh"
    HOME="$tmp/home"
    STOW_DIR="$tmp/dotfiles"
    mkdir -p "$HOME" "$STOW_DIR/sample"
    printf '%s\n' managed-one > "$STOW_DIR/sample/dot-one"
    printf '%s\n' managed-two > "$STOW_DIR/sample/dot-two"
    printf '%s\n' original-one > "$HOME/.one"
    printf '%s\n' original-two > "$HOME/.two"

    resolve_stow() { return 0; }
    mock_stow() { return 99; }
    STOW_BIN=mock_stow
    mv() {
        local source target
        source=${@: -2:1}
        target=${@: -1}
        if [[ "$target" == "$HOME"/*.bak-* ]]; then
            backup_moves=$((backup_moves + 1))
            if [ "$backup_moves" -eq 1 ]; then
                first_target=$source
                first_backup=$target
            elif [ "$backup_moves" -eq 2 ]; then
                printf '%s\n' concurrent-replacement > "$first_target"
                return 73
            fi
        fi
        command mv "$@"
    }

    if stow_pkg sample; then
        echo "error: stow_pkg succeeded after a backup move failed" >&2
        return 1
    fi

    [ "$(cat "$first_target")" = concurrent-replacement ]
    [[ "$(cat "$first_backup")" == original-* ]]
    [ "$(find "$HOME" -name '*.bak-*' -type f | wc -l)" -eq 1 ]
)

test_activate_staged_tree_rejects_reappeared_destination() (
    local tmp staged destination fault_destination old_backup=""
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/activate-staged-tree-race-test.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT
    staged="$tmp/staged"
    destination="$tmp/destination"
    fault_destination=$destination
    mkdir "$staged" "$destination"
    printf '%s\n' new > "$staged/new"
    printf '%s\n' old > "$destination/old"

    # shellcheck source=../setup_dev_environment.sh
    source "$REPO_ROOT/setup_dev_environment.sh"
    mv() {
        local source target
        source=${@: -2:1}
        target=${@: -1}
        if [ "$source" = "$fault_destination" ] && [[ "$target" == "$tmp"/.destination.backup.*/tree ]]; then
            old_backup=$target
            command mv "$@"
            return 0
        elif [ "$target" = "$fault_destination" ] && [[ "$source" == "$tmp"/.activate-stage.*/tree ]]; then
            mkdir "$fault_destination"
            printf '%s\n' concurrent > "$fault_destination/replacement"
        fi
        command mv "$@"
    }

    if activate_staged_tree "$staged" "$destination"; then
        echo "error: activation overwrote or nested into a reappeared destination" >&2
        return 1
    fi

    [ "$(cat "$destination/replacement")" = concurrent ]
    [ "$(cat "$old_backup/old")" = old ]
    [ ! -e "$destination/tree" ]
    [ ! -e "$destination/new" ]
)

test_build_stow_exact_moves_preserve_reappeared_destinations() (
    local tmp staged destination backup fault_mode fault_staged fault_destination fault_backup
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/build-stow-move-race-test.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT

    # build_stow.sh is source-guarded so its transaction helpers can be tested
    # without downloading or compiling Stow.
    # shellcheck source=../build_stow.sh
    source "$REPO_ROOT/build_stow.sh"
    staged="$tmp/staged"
    destination="$tmp/destination"
    backup="$tmp/backup"
    fault_staged=$staged
    fault_destination=$destination
    fault_backup=$backup
    mkdir "$staged"
    printf '%s\n' new > "$staged/new"

    fault_mode=activate
    mv() {
        local source target
        source=${@: -2:1}
        target=${@: -1}
        if [ "$fault_mode" = activate ] && [ "$source" = "$fault_staged" ] && [ "$target" = "$fault_destination" ]; then
            mkdir "$fault_destination"
            printf '%s\n' concurrent > "$fault_destination/replacement"
        elif [ "$fault_mode" = restore ] && [ "$source" = "$fault_backup" ] && [ "$target" = "$fault_destination" ]; then
            mkdir "$fault_destination"
            printf '%s\n' concurrent-restore > "$fault_destination/replacement"
        fi
        command mv "$@"
    }

    if move_tree_exact_noreplace "$staged" "$destination"; then
        echo "error: exact activation accepted a destination that reappeared" >&2
        return 1
    fi
    [ -e "$staged/new" ]
    [ "$(cat "$destination/replacement")" = concurrent ]
    [ ! -e "$destination/staged" ]

    rm -rf "$destination"
    mkdir "$backup"
    printf '%s\n' old > "$backup/old"
    PREFIX="$destination"
    BACKUP_PREFIX="$backup"
    fault_mode=restore
    if restore_previous_stow_prefix; then
        echo "error: exact restore accepted a destination that reappeared" >&2
        return 1
    fi
    [ -e "$backup/old" ]
    [ "$(cat "$destination/replacement")" = concurrent-restore ]
    [ ! -e "$destination/backup" ]
)

prepare_context() {
    local path
    local -a inputs=(
        .pre-commit-config.yaml
        .secrets.baseline
        build_stow.sh
        setup_dev_environment.sh
        dotfiles
        tests/setup_dev_environment.Dockerfile
    )

    # Copy only the tracked files needed by the installer. In particular, this
    # excludes .git plus every ignored or untracked file (including local
    # credential files) from both the Docker context and image layers.
    while IFS= read -r -d '' path; do
        case "$path" in
            .git|.git/*)
                echo "error: refusing to add Git metadata to Docker context" >&2
                return 1
                ;;
        esac
        mkdir -p "$CONTEXT_DIR/$(dirname "$path")"
        cp -a -- "$REPO_ROOT/$path" "$CONTEXT_DIR/$path"
    done < <(git -C "$REPO_ROOT" ls-files -z -- "${inputs[@]}")

    test -f "$CONTEXT_DIR/setup_dev_environment.sh"
    test -f "$DOCKERFILE"
    if find "$CONTEXT_DIR" -name .git -print -quit | grep -q .; then
        echo "error: temporary Docker context contains Git metadata" >&2
        return 1
    fi
}

run_test() {
    local name="$1"
    local image="$2"
    local tag="setup-dev-environment-test:${name}-$$"

    IMAGE_TAGS+=("$tag")

    echo "==> testing setup_dev_environment.sh on ${image}"
    "$DOCKER_BIN" build \
        --pull \
        --force-rm \
        --file "$DOCKERFILE" \
        --build-arg "BASE_IMAGE=$image" \
        --tag "$tag" \
        "$CONTEXT_DIR"
}

test_activate_staged_tree_stops_when_old_tree_cannot_move
test_stow_pkg_rolls_back_partial_backup_failure
test_stow_pkg_preserves_replacement_during_partial_rollback
test_activate_staged_tree_rejects_reappeared_destination
test_build_stow_exact_moves_preserve_reappeared_destinations
prepare_context
run_test ubuntu "$UBUNTU_IMAGE"
run_test archlinux "$ARCH_IMAGE"
