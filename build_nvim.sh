#!/usr/bin/env bash
set -euo pipefail

PREFIX="$HOME/proot/nvim"
BUILD_DIR="$(mktemp -d)"

cleanup() {
    echo "Cleaning up build directory: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

echo "==> Cloning neovim..."
git clone --depth 1 https://github.com/neovim/neovim.git "$BUILD_DIR/neovim"

cd "$BUILD_DIR/neovim"

echo "==> Configuring and building neovim (install prefix: $PREFIX)..."
make CMAKE_BUILD_TYPE=Release CMAKE_INSTALL_PREFIX="$PREFIX" -j"$(nproc)"

echo "==> Installing neovim to $PREFIX..."
make install

echo "==> Done. Neovim installed to $PREFIX"
echo "    Add $PREFIX/bin to your PATH to use it:"
echo "    export PATH=\"$PREFIX/bin:\$PATH\""
