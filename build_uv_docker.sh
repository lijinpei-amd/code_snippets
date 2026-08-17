#!/usr/bin/env bash
set -euo pipefail

# Prepares a base image for the ROCm-from-wheels install: installs the system
# packages and the uv binary used later. The actual ROCm virtualenv is built by
# setup_rocm_venv.sh, which is intentionally NOT run from here so the two can be
# split across Dockerfile layers (system + uv baked once, ROCm rebuilt often).
#
# See setup_rocm_venv.sh for the ROCm wheel install and its integrity notes.
#
# usage: build_uv_docker.sh [ubuntu-version]

UBUNTU_VER="${1:-${UBUNTU_VER:-26.04}}"

UV_VERSION="0.12.4"
UV_TARBALL="uv-x86_64-unknown-linux-gnu.tar.gz"
UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_TARBALL}"
# Upstream's published checksum for the release above, not a credential.
UV_SHA256="c8c60f47e6f88d18dbf6f33d7279fb1fbf7ae76631768152cf5578c3d65729b4"  # pragma: allowlist secret

# shellcheck source=resolve_python.sh
source "$(dirname "${BASH_SOURCE[0]}")/resolve_python.sh"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    tzdata ca-certificates curl \
    "$PYTHON" "$PYTHON-dev" "$PYTHON-venv" \
    cmake ninja-build g++ \
    libatomic1 libquadmath0
ln -fs /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
dpkg-reconfigure --frontend noninteractive tzdata
rm -rf /var/lib/apt/lists/*

tmpdir=$(mktemp -d)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

curl -fSL --retry 3 -o "$tmpdir/$UV_TARBALL" "$UV_URL"
actual_sha256=$(sha256sum "$tmpdir/$UV_TARBALL" | awk '{print $1}')
if [ "$actual_sha256" != "$UV_SHA256" ]; then
    echo "error: uv $UV_VERSION SHA-256 mismatch: $actual_sha256" >&2
    exit 1
fi
tar -xzf "$tmpdir/$UV_TARBALL" -C "$tmpdir"
install -m 0755 "$tmpdir/uv-x86_64-unknown-linux-gnu/uv" /usr/local/bin/uv
install -m 0755 "$tmpdir/uv-x86_64-unknown-linux-gnu/uvx" /usr/local/bin/uvx
uv --version
