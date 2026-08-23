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

test_config_nvim_skips_without_managed_config() (
    local tmp nvim_called=0
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/config-nvim-no-config-test.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT

    # shellcheck source=../setup_dev_environment.sh
    source "$REPO_ROOT/setup_dev_environment.sh"
    HOME="$tmp/home"
    XDG_DATA_HOME="$HOME/.local/share"
    mkdir -p "$XDG_DATA_HOME/nvim/site/autoload"
    printf '%s\n' '" vim-plug fixture' > "$XDG_DATA_HOME/nvim/site/autoload/plug.vim"

    nvim() { nvim_called=1; return 99; }

    config_nvim 2>"$tmp/stderr"
    [ "$nvim_called" -eq 0 ]
    grep -Fq 'run chezmoi apply first' "$tmp/stderr"
)

# The reason the apt signing keys are committed rather than downloaded is that a
# bad key is caught before it can authorise a repository. Prove the check fires,
# both for a well-formed key with the wrong identity and for unreadable bytes.
test_install_key_rejects_wrong_or_corrupt_key() (
    local tmp installed=0
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/apt-key-reject-test.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT

    # shellcheck source=../install_apt_keys.sh
    source "$REPO_ROOT/install_apt_keys.sh"
    KEY_DIR="$tmp/keys"
    mkdir "$KEY_DIR"
    as_root() { installed=1; }

    # A real, valid OpenPGP key -- but the wrong one for this slot.
    cp "$REPO_ROOT/apt_keys/apt.llvm.org.asc" "$KEY_DIR/githubcli-archive-keyring.asc"
    if install_key gh 2>"$tmp/wrong.err"; then
        echo "error: install_key accepted a key with the wrong fingerprints" >&2
        return 1
    fi
    grep -Fq 'unexpected OpenPGP primary-key fingerprints' "$tmp/wrong.err"
    [ "$installed" -eq 0 ]

    # Bytes gpg cannot parse at all must fail closed, not fall through.
    printf '%s\n' 'not a key' > "$KEY_DIR/apt.llvm.org.asc"
    if install_key llvm 2>"$tmp/corrupt.err"; then
        echo "error: install_key accepted unparseable key material" >&2
        return 1
    fi
    [ "$installed" -eq 0 ]

    # A missing file is an error too, not a silent skip.
    rm -f "$KEY_DIR/apt.llvm.org.asc"
    if install_key llvm 2>/dev/null; then
        echo "error: install_key accepted a missing key file" >&2
        return 1
    fi
    [ "$installed" -eq 0 ]
)

# The committed keys must actually satisfy the fingerprints declared beside them,
# and the gh key must reach its destination as a binary keyring (apt's signed-by=
# reference), not as the armor stored in the repo.
test_install_key_accepts_committed_keys() (
    # Deliberately not named "tmp": install_key declares its own local tmp, which
    # would shadow this one inside the as_root stub it calls.
    local sandbox
    sandbox=$(mktemp -d "${TMPDIR:-/tmp}/apt-key-accept-test.XXXXXX")
    trap 'rm -rf "$sandbox"' EXIT

    # shellcheck source=../install_apt_keys.sh
    source "$REPO_ROOT/install_apt_keys.sh"
    # Redirect the privileged install into the sandbox, leaving key_spec's real
    # KEY_DEST values under test rather than stubbing them out.
    as_root() {
        case "$1" in
            mkdir) : ;;
            install) command install -m 0644 "${@: -2:1}" "$sandbox/${KEY_DEST##*/}" ;;
        esac
    }

    install_key llvm >/dev/null
    install_key gh >/dev/null

    # llvm is installed as the stored armor; gh is dearmored to a binary keyring,
    # which is what apt's signed-by= reference needs.
    grep -Fq 'BEGIN PGP PUBLIC KEY BLOCK' "$sandbox/apt.llvm.org.asc"
    if grep -Fq 'BEGIN PGP PUBLIC KEY BLOCK' "$sandbox/githubcli-archive-keyring.gpg"; then
        echo "error: gh keyring was installed as armor, not dearmored binary" >&2
        return 1
    fi
    GNUPGHOME="$sandbox/gnupg"
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    export GNUPGHOME
    gpg --batch --show-keys "$sandbox/githubcli-archive-keyring.gpg" >/dev/null
)

# The collision this OS column exists to prevent: one component installed through
# two different package managers must keep a row each.
test_record_lock_keeps_a_row_per_os() (
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/record-lock-test.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT

    # shellcheck source=../setup_dev_environment.sh
    source "$REPO_ROOT/setup_dev_environment.sh"
    LOCK_FILE="$tmp/lock"

    OS_TAG=ubuntu-24.04 ; record_lock_os llvm 22 -
    OS_TAG=arch         ; record_lock_os llvm 21 -
    record_lock nvim 0.12.4 sha256:aaa

    [ "$(awk -F'\t' '$2 == "llvm"' "$LOCK_FILE" | wc -l)" -eq 2 ]
    [ "$(awk -F'\t' '$1 == "ubuntu-24.04" && $2 == "llvm" {print $3}' "$LOCK_FILE")" = 22 ]
    [ "$(awk -F'\t' '$1 == "arch" && $2 == "llvm" {print $3}' "$LOCK_FILE")" = 21 ]

    # Re-recording the same pair replaces in place and keeps a prior checksum
    # when the caller has nothing to hash.
    record_lock nvim 0.13.0 -
    [ "$(awk -F'\t' '$2 == "nvim"' "$LOCK_FILE" | wc -l)" -eq 1 ]
    [ "$(awk -F'\t' '$2 == "nvim" {print $4}' "$LOCK_FILE")" = sha256:aaa ]

    # Rows left by the older three-column format are dropped, not carried
    # through misaligned.
    printf 'legacy\t9.9.9\t-\n' >> "$LOCK_FILE"
    record_lock uv 1.0 -
    if grep -q legacy "$LOCK_FILE"; then
        echo "error: a stale three-column row survived a lockfile write" >&2
        return 1
    fi
)

test_lock_version_scoping_and_exit_status() (
    local tmp rc
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/lock-version-test.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT

    # shellcheck source=../setup_dev_environment.sh
    source "$REPO_ROOT/setup_dev_environment.sh"
    OS_TAG=ubuntu-24.04

    # Absent lockfile is fatal for --locked (2); an absent row is merely "no pin
    # available" (1). The two OS-scoped installers rely on telling them apart.
    LOCK_FILE="$tmp/missing"
    rc=0 ; lock_version node >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ]

    LOCK_FILE="$tmp/lock"
    printf '# h\n# h\nall\tgh\t2.50.0\t-\nubuntu-24.04\tgh\t2.97.0\t-\nall\tnode\tv1\t-\n' > "$LOCK_FILE"
    rc=0 ; lock_version nosuch >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ]

    # A row for this exact OS wins over an "all" row, and exactly one value is
    # printed -- awk runs END even after `exit`, so the fallback must be
    # suppressed on an exact hit.
    [ "$(lock_version gh)" = 2.97.0 ]
    [ "$(lock_version gh | wc -l)" -eq 1 ]

    # On an OS with no specific row, the "all" row still applies.
    # shellcheck disable=SC2034  # read by the sourced lock_version
    OS_TAG=arch
    [ "$(lock_version gh)" = 2.50.0 ]
    [ "$(lock_version node)" = v1 ]
)

test_os_tag_branches() (
    local sandbox
    sandbox=$(mktemp -d "${TMPDIR:-/tmp}/os-tag-test.XXXXXX")
    trap 'rm -rf "$sandbox"' EXIT

    # shellcheck source=../setup_dev_environment.sh
    source "$REPO_ROOT/setup_dev_environment.sh"
    DEBIAN_VERSION_FILE="$sandbox/debian_version"
    : > "$DEBIAN_VERSION_FILE"
    # shellcheck disable=SC2034  # read by the sourced os_tag as its last resort
    DISTRO=fallback-distro

    # os_tag reads the os-release fields as globals, so feed them as a prefix
    # assignment scoped to the call: ID VERSION_ID VERSION_CODENAME BUILD_ID.
    probe() { ID="$1" VERSION_ID="$2" VERSION_CODENAME="$3" BUILD_ID="$4" os_tag; }

    # Rolling wins over VERSION_ID: Arch's /etc/os-release carries a snapshot
    # date that would otherwise look like a new OS on every sync.
    [ "$(probe arch 20260816.0.574111 '' rolling)" = arch ]

    [ "$(probe ubuntu 24.04 noble '')" = ubuntu-24.04 ]
    [ "$(probe ubuntu 26.04 resolute '')" = ubuntu-26.04 ]
    [ "$(probe debian 12 bookworm '')" = debian-12 ]

    # Debian unstable has no VERSION_ID and a codename naming the *next* release,
    # so it is pinned to the stable "sid" label via /etc/debian_version.
    printf 'forky/sid\n' > "$DEBIAN_VERSION_FILE"
    [ "$(probe debian '' forky '')" = debian-sid ]

    # The same marker under a non-Debian ID must not yield "<id>-sid".
    [ "$(probe ubuntu '' noble '')" = ubuntu-noble ]

    # Released Debian keeps its VERSION_ID even though the marker file exists.
    [ "$(probe debian 12 bookworm '')" = debian-12 ]

    # A codename-less, version-less ID degrades to the bare ID.
    printf '12.15\n' > "$DEBIAN_VERSION_FILE"
    [ "$(probe someos '' '' '')" = someos ]

    # No usable os-release at all falls back to the coarse DISTRO.
    [ "$(probe '' '' '' '')" = fallback-distro ]
)

prepare_context() {
    local path
    local -a inputs=(
        .pre-commit-config.yaml
        .secrets.baseline
        setup_dev_environment.sh
        install_apt_keys.sh
        apt_keys
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
test_activate_staged_tree_rejects_reappeared_destination
test_config_nvim_skips_without_managed_config
test_install_key_rejects_wrong_or_corrupt_key
test_install_key_accepts_committed_keys
test_record_lock_keeps_a_row_per_os
test_lock_version_scoping_and_exit_status
test_os_tag_branches
prepare_context
run_test ubuntu "$UBUNTU_IMAGE"
run_test archlinux "$ARCH_IMAGE"
