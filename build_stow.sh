#!/usr/bin/env bash
#
# Build GNU Stow 2.4.1 and install it to ~/proot/stow.
#
# Why not the distro package? Ubuntu 24.04 only ships stow 2.3.1, whose
# --dotfiles option mis-translates a "dot-" prefixed *directory* under
# --no-folding: it fails to link the directory's contents (or hard-errors when
# the target directory already exists). 2.4.0 fixes this, so the dotfiles
# packages can use the "dot-" convention uniformly (dot-config, dot-claude,
# dot-codex) instead of literal dotted directory names.
#
# Idempotent: a no-op if $PREFIX already has the target version. On failure the
# partially-installed prefix is removed so callers never invoke a broken stow.
#
set -euo pipefail

STOW_VERSION="2.4.1"
STOW_URL="https://ftp.gnu.org/gnu/stow/stow-${STOW_VERSION}.tar.gz"
STOW_MIRROR_URL="https://ftpmirror.gnu.org/stow/stow-${STOW_VERSION}.tar.gz"
PREFIX="$HOME/proot/stow"

# Already installed at the right version? Nothing to do (keeps re-runs of the
# setup fast and offline-safe instead of re-downloading + recompiling).
if [ -x "$PREFIX/bin/stow" ] \
    && "$PREFIX/bin/stow" --version 2>/dev/null | grep -q "version ${STOW_VERSION}\b"; then
    echo "stow ${STOW_VERSION} already installed at $PREFIX; nothing to do."
    exit 0
fi

BUILD_DIR="$(mktemp -d)"
INSTALL_STARTED=0
INSTALL_DONE=0

cleanup() {
    echo "Cleaning up build directory: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
    # If install began but did not finish, the prefix is half-populated and a
    # bare bin/stow there would fail at runtime loading its Perl modules. Remove
    # it so the next run rebuilds cleanly and callers fall back instead.
    if [ "$INSTALL_DONE" -eq 0 ] && [ "$INSTALL_STARTED" -eq 1 ]; then
        echo "Install did not complete; removing partial $PREFIX" >&2
        rm -rf "$PREFIX"
    fi
}
trap cleanup EXIT

tarball="$BUILD_DIR/stow-${STOW_VERSION}.tar.gz"
echo "==> Downloading stow ${STOW_VERSION}..."
curl -fSL --retry 3 -o "$tarball" "$STOW_URL" \
    || curl -fSL --retry 3 -o "$tarball" "$STOW_MIRROR_URL"

echo "==> Extracting..."
tar xzf "$tarball" -C "$BUILD_DIR"

srcdir="$BUILD_DIR/stow-${STOW_VERSION}"
[ -d "$srcdir" ] || { echo "error: expected source dir $srcdir after extraction" >&2; exit 1; }
cd "$srcdir"

echo "==> Configuring and building stow (install prefix: $PREFIX)..."
./configure --prefix="$PREFIX"
make -j"$(nproc)"

echo "==> Installing stow to $PREFIX..."
INSTALL_STARTED=1
make install

# Verify the installed binary actually runs (loads its Perl modules) before
# declaring success; otherwise the cleanup trap removes the broken prefix.
"$PREFIX/bin/stow" --version
INSTALL_DONE=1

echo "==> Done. Stow installed to $PREFIX"
echo "    Add $PREFIX/bin to your PATH to use it:"
echo "    export PATH=\"$PREFIX/bin:\$PATH\""
