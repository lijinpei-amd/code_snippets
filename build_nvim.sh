#!/usr/bin/env bash
set -euo pipefail

PREFIX="$HOME/proot/nvim"
BUILD_DIR="$(mktemp -d)"
NVIM_VERSION="0.11.7"
NVIM_REVISION="cd90ec7cdcdc55b617dfae5317b2c24b76b4148a"
NVIM_SHA256="f1847925a551ca307eeb3c33ffed3f1ffe45adcfea88976f1a55fe8cdbf1a9c5"
NVIM_URL="https://codeload.github.com/neovim/neovim/tar.gz/${NVIM_REVISION}"

cleanup() {
    echo "Cleaning up build directory: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

archive="$BUILD_DIR/neovim-${NVIM_VERSION}.tar.gz"
echo "==> Downloading neovim ${NVIM_VERSION} (${NVIM_REVISION})..."
curl -fSL --retry 3 -o "$archive" "$NVIM_URL"
actual_sha256=$(sha256sum "$archive" | awk '{print $1}')
if [ "$actual_sha256" != "$NVIM_SHA256" ]; then
    echo "error: neovim source archive SHA-256 mismatch" >&2
    echo "       expected: $NVIM_SHA256" >&2
    echo "       actual:   $actual_sha256" >&2
    exit 1
fi
mkdir "$BUILD_DIR/neovim"
tar xzf "$archive" --strip-components=1 -C "$BUILD_DIR/neovim"

cd "$BUILD_DIR/neovim"

echo "==> Configuring and building neovim (install prefix: $PREFIX)..."
make CMAKE_BUILD_TYPE=Release CMAKE_INSTALL_PREFIX="$PREFIX" -j"$(nproc)"

echo "==> Installing neovim to $PREFIX..."
make install

echo "==> Done. Neovim installed to $PREFIX"
echo "    Add $PREFIX/bin to your PATH to use it:"
echo "    export PATH=\"$PREFIX/bin:\$PATH\""
