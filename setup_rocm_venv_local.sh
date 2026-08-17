#!/usr/bin/env bash
set -euo pipefail

# Rootless sibling of setup_rocm_venv.sh: installs ROCm from the AMD wheel index
# into a venv at a path you choose, under your home dir, with no root and no
# system-global writes. Where the Docker-oriented script hardcodes
# /opt/rocm-venv, symlinks /opt/rocm, and drops /etc/profile.d/rocm.sh (all of
# which need root and are baked into the image ENV), this one keeps everything
# self-contained inside the venv: ROCM_PATH and env.sh point at the SDK root that
# lives in the venv's own site-packages.
#
# Integrity: same caveat as the sibling script -- the ~3 GiB of ROCm wheels are
# protected by TLS alone (AMD publishes no wheel signatures). For a reproducible
# install, compile a hashed lockfile and install with --require-hashes.
#
# usage: setup_rocm_venv_local.sh <venv-path> [rocm-version] [device-targets] [ubuntu-version]
#   e.g. setup_rocm_venv_local.sh ~/development/venv/01

if [[ $# -lt 1 || "${1:-}" == -h || "${1:-}" == --help ]]; then
    echo "usage: $(basename "$0") <venv-path> [rocm-version] [device-targets] [ubuntu-version]" >&2
    exit 2
fi

# Expand a leading ~ (a quoted "~/..." argument is not tilde-expanded by the
# shell) and resolve to an absolute path so the env.sh we write is portable.
ROCM_VENV="${1/#\~/$HOME}"
case "$ROCM_VENV" in
    /*) ;;
    *) ROCM_VENV="$PWD/$ROCM_VENV" ;;
esac

ROCM_VER="${2:-${ROCM_VER:-7.14.0}}"
# Device (pre-compiled GPU kernel) extras. Each device wheel is ~1.6 GiB, so
# "device-all" pulls tens of gigabytes; name only the targets you need.
ROCM_DEVICE_TARGETS="${3:-${ROCM_DEVICE_TARGETS:-device-gfx950}}"
UBUNTU_VER="${4:-${UBUNTU_VER:-26.04}}"
ROCM_INDEX_URL="${ROCM_INDEX_URL:-https://repo.amd.com/rocm/whl-multi-arch/}"

if ! [[ "$ROCM_DEVICE_TARGETS" =~ ^device-(all|gfx[0-9a-z]+)(,device-(all|gfx[0-9a-z]+))*$ ]]; then
    echo "error: ROCM_DEVICE_TARGETS must be a comma-separated list of" >&2
    echo "       device-all / device-gfx<target>, got: $ROCM_DEVICE_TARGETS" >&2
    exit 2
fi

# TLS is the only thing standing between the build and a tampered wheel; don't
# let an override quietly drop it.
case "$ROCM_INDEX_URL" in
    https://*) ;;
    *)
        echo "error: ROCM_INDEX_URL must be an https:// URL, got: $ROCM_INDEX_URL" >&2
        exit 2
        ;;
esac

# shellcheck source=resolve_python.sh
source "$(dirname "${BASH_SOURCE[0]}")/resolve_python.sh"

# No --seed: seeding pip resolves against uv's default index (PyPI), which
# would make this install depend on a second registry. uv is the installer here;
# add packages later with `uv pip install --python $ROCM_VENV/bin/python ...`.
uv venv --python "$PYTHON" "$ROCM_VENV"

# The `rocm` meta package is published as an sdist only: it is built locally
# and its setup.py resolves the device extras. The AMD index mirrors
# setuptools, so --index-url (not --extra-index-url) is enough for the build.
# --no-cache avoids leaving a multi-gigabyte uv cache behind.
uv pip install --no-cache \
    --python "$ROCM_VENV/bin/python" \
    --index-url "$ROCM_INDEX_URL" \
    "rocm[libraries,devel,${ROCM_DEVICE_TARGETS}]==${ROCM_VER}"

# rocm[devel] ships its tree as a tarball that is unpacked into site-packages on
# first use. Do it now so the multi-gigabyte write happens here, once.
"$ROCM_VENV/bin/rocm-sdk" init

# The unpacked root lives under a versioned site-packages directory inside the
# venv. Unlike the Docker script we do NOT symlink it to /opt/rocm (needs root,
# and is global); consumers read the real path from env.sh below.
ROCM_ROOT="$("$ROCM_VENV/bin/rocm-sdk" path --root)"

# Drop an env.sh next to the venv's activate: sourcing it exports the ROCm
# environment (pointed at the in-venv SDK root) and activates the venv in one
# step. No /etc/profile.d equivalent -- this is the only entry point.
cat > "$ROCM_VENV/bin/env.sh" << EOF
export ROCM_PATH="$ROCM_ROOT"
export HIP_PATH="$ROCM_ROOT"
export PATH="$ROCM_ROOT/bin:\$PATH"
source "$ROCM_VENV/bin/activate"
EOF
chmod 0644 "$ROCM_VENV/bin/env.sh"

"$ROCM_VENV/bin/rocm-sdk" version
# Informational: this imports the core package to read its target manifest, and
# is not worth failing a multi-gigabyte install over.
"$ROCM_VENV/bin/rocm-sdk" targets \
    || echo "warning: could not query installed device targets" >&2
echo "ROCm $ROCM_VER installed at $ROCM_ROOT (venv: $ROCM_VENV)"
echo "activate with: source $ROCM_VENV/bin/env.sh"
