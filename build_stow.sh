#!/usr/bin/env bash
#
# Build GNU Stow 2.4.1 and install it to ~/proot/stow.
#
# Why not the distro package? Ubuntu 24.04 only ships stow 2.3.1, whose
# --dotfiles option mis-translates a "dot-" prefixed *directory* under
# --no-folding: it fails to link the directory's contents (or hard-errors when
# the target directory already exists). 2.4.0 fixes this, so the dotfiles
# packages can use the "dot-" convention uniformly (for example, dot-config and
# dot-codex) instead of literal dotted directory names.
#
# Idempotent: a no-op if $PREFIX already has the target version. Upgrades are
# installed under a staging root and swapped into place only after the staged
# installation is complete; a failed activation restores the previous prefix.
#
set -euo pipefail

STOW_VERSION="2.4.1"
STOW_URL="https://ftpmirror.gnu.org/stow/stow-${STOW_VERSION}.tar.gz"
STOW_MIRROR_URL="https://ftp.gnu.org/gnu/stow/stow-${STOW_VERSION}.tar.gz"
STOW_SHA256="2a671e75fc207303bfe86a9a7223169c7669df0a8108ebdf1a7fe8cd2b88780b"
PREFIX="$HOME/proot/stow"

path_present() {
    [ -e "$1" ] || [ -L "$1" ]
}

# Move a tree only when the destination does not exist. GNU mv's -T prevents
# an existing directory from turning the operation into an accidental nested
# move, while -n preserves an object that appears between our checks. Since -n
# reports success when it skips a move, the source must disappear as well.
move_tree_exact_noreplace() {
    local source="$1" destination="$2"

    mv -Tn -- "$source" "$destination" || return 1
    ! path_present "$source"
}

restore_previous_stow_prefix() {
    if ! path_present "$BACKUP_PREFIX"; then
        echo "warning: previous stow backup disappeared: $BACKUP_PREFIX" >&2
        return 1
    fi
    if path_present "$PREFIX"; then
        echo "warning: not overwriting replacement at $PREFIX; previous stow remains at $BACKUP_PREFIX" >&2
        return 1
    fi
    if ! move_tree_exact_noreplace "$BACKUP_PREFIX" "$PREFIX"; then
        echo "warning: could not restore $BACKUP_PREFIX to $PREFIX; backup remains in place" >&2
        return 1
    fi
}

path_identity() {
    stat -c '%d:%i:%F' -- "$1" 2>/dev/null
}

BUILD_DIR=""
PREFIX_PARENT=""
STAGE_ROOT=""
STAGED_PREFIX=""
BACKUP_ROOT=""
BACKUP_PREFIX=""
OLD_MOVED=0
NEW_ACTIVATED=0
NEW_PREFIX_ID=""
INSTALL_DONE=0

cleanup() {
    local current_prefix_id=""

    if [ -n "$BUILD_DIR" ]; then
        echo "Cleaning up build directory: $BUILD_DIR"
        rm -rf -- "$BUILD_DIR" || true
    fi

    if [ "$INSTALL_DONE" -eq 0 ]; then
        if [ "$NEW_ACTIVATED" -eq 1 ] && path_present "$PREFIX"; then
            current_prefix_id=$(path_identity "$PREFIX" || true)
            if [ -n "$NEW_PREFIX_ID" ] && [ "$current_prefix_id" = "$NEW_PREFIX_ID" ]; then
                echo "Activation failed; removing the new stow prefix" >&2
                rm -rf -- "$PREFIX" || true
            else
                echo "warning: not removing replacement at $PREFIX after activation failure" >&2
            fi
        fi
        if [ "$OLD_MOVED" -eq 1 ] && path_present "$BACKUP_PREFIX"; then
            echo "Restoring the previous stow prefix" >&2
            restore_previous_stow_prefix || true
        fi
    fi

    [ -z "$STAGE_ROOT" ] || rm -rf -- "$STAGE_ROOT" || true
    if [ -n "$BACKUP_ROOT" ] && ! path_present "$BACKUP_PREFIX"; then
        rm -rf -- "$BACKUP_ROOT" || true
    fi
}

main() {
    local tarball actual_sha256 srcdir staged_perl_lib

    # Already installed at the right version? Nothing to do (keeps re-runs of
    # setup fast and offline-safe instead of re-downloading + recompiling).
    if [ -x "$PREFIX/bin/stow" ] \
        && "$PREFIX/bin/stow" --version 2>/dev/null | grep -q "version ${STOW_VERSION}\b"; then
        echo "stow ${STOW_VERSION} already installed at $PREFIX; nothing to do."
        return 0
    fi

    BUILD_DIR=$(mktemp -d)
    PREFIX_PARENT=$(dirname "$PREFIX")
    mkdir -p "$PREFIX_PARENT"
    STAGE_ROOT=$(mktemp -d "$PREFIX_PARENT/.stow-stage.XXXXXX")
    STAGED_PREFIX="${STAGE_ROOT}${PREFIX}"
    BACKUP_ROOT=$(mktemp -d "$PREFIX_PARENT/.stow-backup.XXXXXX")
    BACKUP_PREFIX="$BACKUP_ROOT/previous"
    trap cleanup EXIT

    tarball="$BUILD_DIR/stow-${STOW_VERSION}.tar.gz"
    echo "==> Downloading stow ${STOW_VERSION}..."
    curl -fSL --retry 3 -o "$tarball" "$STOW_URL" \
        || curl -fSL --retry 3 -o "$tarball" "$STOW_MIRROR_URL"

    actual_sha256=$(sha256sum "$tarball" | awk '{print $1}')
    if [ "$actual_sha256" != "$STOW_SHA256" ]; then
        echo "error: stow tarball SHA-256 mismatch" >&2
        echo "       expected: $STOW_SHA256" >&2
        echo "       actual:   $actual_sha256" >&2
        return 1
    fi

    echo "==> Extracting..."
    tar xzf "$tarball" -C "$BUILD_DIR"

    srcdir="$BUILD_DIR/stow-${STOW_VERSION}"
    [ -d "$srcdir" ] || {
        echo "error: expected source dir $srcdir after extraction" >&2
        return 1
    }
    cd "$srcdir"

    echo "==> Configuring and building stow (final prefix: $PREFIX)..."
    ./configure --prefix="$PREFIX"
    make -j"$(nproc)"

    echo "==> Staging stow installation..."
    make install DESTDIR="$STAGE_ROOT"

    # The configured prefix remains $PREFIX; DESTDIR only redirects installation
    # writes. PERL5LIB lets this pre-activation check load the staged modules.
    [ -x "$STAGED_PREFIX/bin/stow" ]
    staged_perl_lib=$(dirname "$(find "$STAGED_PREFIX" -type f -name Stow.pm -print -quit)")
    [ -f "$staged_perl_lib/Stow.pm" ]
    PERL5LIB="$staged_perl_lib${PERL5LIB:+:$PERL5LIB}" \
        "$STAGED_PREFIX/bin/stow" --version | grep -q "version ${STOW_VERSION}\b"

    echo "==> Activating staged stow at $PREFIX..."
    if path_present "$PREFIX"; then
        if ! move_tree_exact_noreplace "$PREFIX" "$BACKUP_PREFIX"; then
            echo "error: could not move the existing stow prefix to $BACKUP_PREFIX" >&2
            return 1
        fi
        OLD_MOVED=1
    fi

    if ! move_tree_exact_noreplace "$STAGED_PREFIX" "$PREFIX"; then
        echo "error: could not activate staged stow; refusing to overwrite $PREFIX" >&2
        return 1
    fi
    NEW_ACTIVATED=1
    NEW_PREFIX_ID=$(path_identity "$PREFIX" || true)
    [ -n "$NEW_PREFIX_ID" ] || {
        echo "error: activated stow prefix disappeared before verification" >&2
        return 1
    }

    # Verify the installed binary actually runs (loads its Perl modules) before
    # declaring success; otherwise the cleanup trap restores the old prefix.
    "$PREFIX/bin/stow" --version | grep -q "version ${STOW_VERSION}\b"
    INSTALL_DONE=1

    if [ "$OLD_MOVED" -eq 1 ]; then
        rm -rf -- "$BACKUP_PREFIX"
        OLD_MOVED=0
    fi
    rmdir "$BACKUP_ROOT"

    echo "==> Done. Stow installed to $PREFIX"
    echo "    Add $PREFIX/bin to your PATH to use it:"
    echo "    export PATH=\"$PREFIX/bin:\$PATH\""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
