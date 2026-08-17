#!/usr/bin/env bash
set -euo pipefail

# Installs ROCm from the AMD Python wheel index (the "pip install" path in
# https://rocm.docs.amd.com/en/latest/install/rocm.html), using uv as the
# installer. No apt repository: everything lands in a virtualenv. Expects the
# system packages and the uv binary from build_uv_docker.sh to already be
# present; this script is deliberately not invoked by that one so the two can
# live in separate Dockerfile layers.
#
# Integrity: the apt path this replaced verified a pinned GPG key and then let
# apt check every package signature. AMD publishes no signatures for these
# wheels, so while the uv binary is SHA-256 pinned (in build_uv_docker.sh),
# the ~3 GiB of ROCm wheels are protected by TLS alone. For a verified,
# reproducible build, generate a lockfile with `uv pip compile
# --generate-hashes` and install it with --require-hashes.
#
# usage: setup_rocm_venv.sh [rocm-version] [device-targets] [ubuntu-version]

ROCM_VER="${1:-${ROCM_VER:-7.14.0}}"
# Device (pre-compiled GPU kernel) extras. Each device wheel is ~1.6 GiB, so
# "device-all" pulls tens of gigabytes; name only the targets you need.
ROCM_DEVICE_TARGETS="${2:-${ROCM_DEVICE_TARGETS:-device-gfx950}}"
UBUNTU_VER="${3:-${UBUNTU_VER:-26.04}}"
ROCM_INDEX_URL="${ROCM_INDEX_URL:-https://repo.amd.com/rocm/whl-multi-arch/}"
# Deliberately not configurable: the Dockerfile bakes this path into ENV PATH,
# and the two would drift silently. Keep both in sync if you move it.
ROCM_VENV="/opt/rocm-venv"

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
# would make this build depend on a second registry. uv is the installer here;
# add packages later with `uv pip install --python $ROCM_VENV/bin/python ...`.
uv venv --python "$PYTHON" "$ROCM_VENV"

# The `rocm` meta package is published as an sdist only: it is built locally
# and its setup.py resolves the device extras. The AMD index mirrors
# setuptools, so --index-url (not --extra-index-url) is enough for the build.
# --no-cache avoids leaving a multi-gigabyte uv cache in the image layer.
uv pip install --no-cache \
    --python "$ROCM_VENV/bin/python" \
    --index-url "$ROCM_INDEX_URL" \
    "rocm[libraries,devel,${ROCM_DEVICE_TARGETS}]==${ROCM_VER}"

# Note: the bare `device` extra silently falls back to a default gfx target
# when no GPU is visible (as during a container build), which is why the
# explicit device-gfx<target> extras above are required.

# rocm[devel] ships its tree as a tarball that is unpacked into site-packages
# on first use. Do it now so it happens in this layer rather than as a
# multi-gigabyte self-modifying write inside a running container.
"$ROCM_VENV/bin/rocm-sdk" init

# The unpacked root lives under a versioned site-packages directory; pin a
# stable path so consumers can hardcode ROCM_PATH.
ROCM_ROOT="$("$ROCM_VENV/bin/rocm-sdk" path --root)"
ln -sfn "$ROCM_ROOT" /opt/rocm

# Auto-applied to login shells inside the image (the Dockerfile also sets these
# via ENV; this covers login shells that bypass ENV).
cat > /etc/profile.d/rocm.sh << EOF
export ROCM_PATH=/opt/rocm
export HIP_PATH=/opt/rocm
export PATH="$ROCM_VENV/bin:/opt/rocm/bin:\$PATH"
EOF
chmod 0644 /etc/profile.d/rocm.sh

# Drop an env.sh next to the venv's activate: sourcing it exports the ROCm
# environment and then activates the venv in one step.
cat > "$ROCM_VENV/bin/env.sh" << EOF
export ROCM_PATH=/opt/rocm
export HIP_PATH=/opt/rocm
export PATH="/opt/rocm/bin:\$PATH"
source "$ROCM_VENV/bin/activate"
EOF
chmod 0644 "$ROCM_VENV/bin/env.sh"

"$ROCM_VENV/bin/rocm-sdk" version
# Informational: this imports the core package to read its target manifest, and
# is not worth failing a multi-gigabyte build over.
"$ROCM_VENV/bin/rocm-sdk" targets \
    || echo "warning: could not query installed device targets" >&2
echo "ROCm $ROCM_VER installed at $ROCM_ROOT (via /opt/rocm, venv: $ROCM_VENV)"
