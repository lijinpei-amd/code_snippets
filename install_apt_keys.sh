#!/usr/bin/env bash
#
# Install the OpenPGP signing keys for the third-party apt repositories that
# setup_dev_environment.sh adds (apt.llvm.org and cli.github.com).
#
# Why the keys are committed rather than downloaded:
# an apt signing key is not a versioned artifact. Once it lands in
# /etc/apt/trusted.gpg.d or is named by a signed-by= line, it authorises every
# package that repository will ever serve -- far beyond anything the sibling
# setup_dev_environment.lock records after the fact. That makes the key the one
# thing which has to be reviewed *before* use, so it lives in apt_keys/ where a
# change shows up as a diff in code review instead of arriving silently over the
# wire on some future run. Fetching it and checking a fingerprint at run time
# only proves the download matched a constant that was already in the script.
#
# The fingerprints below are still checked on every install. They are cheap and
# they cover the case the committed file itself is wrong -- a bad merge, a
# corrupted checkout, or an edit that swapped the bytes without swapping these.
#
# Both files are ASCII-armored so they diff and review as text. Upstream serves
# apt.llvm.org's key armored already (stored verbatim); cli.github.com serves a
# binary keyring, and `gpg --dearmor` on the stored armor reproduces upstream's
# bytes exactly, which is what gets written to the keyring path.
#
# Refreshing a key (rotation, added subkey). apt.llvm.org serves armor already,
# so it is a straight copy. cli.github.com serves a binary keyring, which has to
# be armored through a THROWAWAY keyring -- a bare `gpg --import && gpg --export`
# would write into your real ~/.gnupg and then export every public key you hold,
# silently authorising all of them to sign packages from that repo:
#   curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key > apt_keys/apt.llvm.org.asc
#   tmp=$(mktemp -d) && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
#     | GNUPGHOME="$tmp" gpg --batch --import \
#     && GNUPGHOME="$tmp" gpg --batch --armor --export \
#        > apt_keys/githubcli-archive-keyring.asc && rm -rf "$tmp"
# then update the fingerprints here and review the diff before committing.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_DIR="$SCRIPT_DIR/apt_keys"

KEYS=(llvm gh)

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# key_spec NAME — populate KEY_* for one repository. KEY_MODE is "armored" to
# install the stored bytes as-is (trusted.gpg.d accepts .asc) or "dearmor" to
# convert to a binary keyring for a signed-by= reference.
key_spec() {
    case "$1" in
        llvm)
            # trusted.gpg.d is global: a key here can validate the Release file of
            # ANY apt source on the host, unlike the signed-by= scoping used for
            # gh below. That is not a preference -- upstream llvm.sh hardcodes
            # "Signed-By: /etc/apt/trusted.gpg.d/apt.llvm.org.asc" in the source
            # entry it writes, and also skips fetching its own copy of the key
            # only when that exact path already exists. Writing it anywhere else
            # would both break its source entry and let it install an unverified
            # key over the wire. Revisit if we ever write the LLVM source entry
            # ourselves instead of delegating to llvm.sh.
            KEY_SOURCE="apt.llvm.org.asc"
            KEY_DEST="/etc/apt/trusted.gpg.d/apt.llvm.org.asc"
            KEY_MODE=armored
            KEY_FINGERPRINTS=(6084F3CF814B57C1CF12EFD515CF4D18AF4F7421)  # pragma: allowlist secret  gitleaks:allow
            ;;
        gh)
            KEY_SOURCE="githubcli-archive-keyring.asc"
            KEY_DEST="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
            KEY_MODE=dearmor
            KEY_FINGERPRINTS=(  # pragma: allowlist secret  gitleaks:allow
                2C6106201985B60E6C7AC87323F3D4EA75716059
                7F38BBB59D064DBCB3D84D725612B36462313325
            )
            ;;
        *)
            echo "error: unknown key: $1" >&2
            echo "known keys: ${KEYS[*]}" >&2
            return 1
            ;;
    esac
}

# Verify the ordered primary-key fingerprints in an OpenPGP key or keyring.
# A private temporary GNUPGHOME avoids modifying the caller's keyring.
verify_openpgp_fingerprints() {
    local key_file="$1" gnupg_home actual expected
    shift
    gnupg_home=$(mktemp -d)
    chmod 700 "$gnupg_home"
    actual=$(
        GNUPGHOME="$gnupg_home" gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null \
            | awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }'
    )
    rm -rf "$gnupg_home"
    expected=$(printf '%s\n' "$@")
    if [ "$actual" != "$expected" ]; then
        echo "error: unexpected OpenPGP primary-key fingerprints in $key_file" >&2
        echo "expected:" >&2
        printf '  %s\n' "$@" >&2
        echo "actual:" >&2
        printf '  %s\n' "$actual" >&2
        return 1
    fi
}

install_key() {
    local name="$1" source tmp
    key_spec "$name" || return 1
    source="$KEY_DIR/$KEY_SOURCE"

    [ -r "$source" ] || {
        echo "error: missing key file: $source" >&2
        return 1
    }
    command -v gpg >/dev/null 2>&1 || {
        echo "error: gpg is required to install apt keys (install the gnupg package)" >&2
        return 1
    }
    verify_openpgp_fingerprints "$source" "${KEY_FINGERPRINTS[@]}" || return 1

    as_root mkdir -p -m 755 "$(dirname "$KEY_DEST")"
    case "$KEY_MODE" in
        armored)
            as_root install -m 0644 "$source" "$KEY_DEST"
            ;;
        dearmor)
            # Write the binary keyring through a temp file so a failed dearmor
            # cannot leave a truncated key at the destination apt reads.
            tmp=$(mktemp)
            if ! gpg --batch --dearmor < "$source" > "$tmp"; then
                rm -f "$tmp"
                echo "error: could not dearmor $source" >&2
                return 1
            fi
            as_root install -m 0644 "$tmp" "$KEY_DEST" || { rm -f "$tmp"; return 1; }
            rm -f "$tmp"
            ;;
    esac
    echo "installed $name key -> $KEY_DEST"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [KEY...]

Install committed OpenPGP signing keys for third-party apt repositories.
With no arguments, installs every known key.

Keys:
  llvm   apt.llvm.org      -> /etc/apt/trusted.gpg.d/apt.llvm.org.asc
  gh     cli.github.com    -> /etc/apt/keyrings/githubcli-archive-keyring.gpg

Options:
  -h, --help   Show this help.
EOF
}

main() {
    local selected=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --) shift; break ;;
            -*)
                echo "error: unknown option: $1" >&2
                usage >&2
                exit 2
                ;;
            *) selected+=("$1"); shift ;;
        esac
    done
    [ $# -gt 0 ] && selected+=("$@")
    [ "${#selected[@]}" -eq 0 ] && selected=("${KEYS[@]}")

    local k
    for k in "${selected[@]}"; do install_key "$k"; done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
