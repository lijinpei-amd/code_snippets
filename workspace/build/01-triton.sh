#!/usr/bin/env bash
set -euo pipefail

if [ -z "${VIRTUAL_ENV:-}" ] \
    || [ ! -f "$VIRTUAL_ENV/pyvenv.cfg" ] \
    || [ ! -x "$VIRTUAL_ENV/bin/python" ]; then
    echo "error: a complete workspace virtual environment is required to build Triton" >&2
    exit 1
fi

VENV_PYTHON="$VIRTUAL_ENV/bin/python"

# Bind uv to the workspace interpreter even if the caller normally asks uv or
# pip to install into a system, target, prefix, user, or alternate environment.
# Keep ordinary build/compiler variables (including PYTHONPATH) intact, but do
# not let environment-selection variables override the validated venv or the
# source directory below. --no-config also prevents a user/project uv.toml from
# reintroducing those overrides.
uv_install() {
    env \
        -u UV_SYSTEM_PYTHON \
        -u UV_TARGET \
        -u UV_PREFIX \
        -u UV_PYTHON \
        -u UV_PROJECT_ENVIRONMENT \
        -u UV_WORKING_DIR \
        -u UV_PROJECT \
        -u PIP_TARGET \
        -u PIP_PREFIX \
        -u PIP_ROOT \
        -u PIP_USER \
        -u PIP_PYTHON_PATH \
        -u PYTHONHOME \
        -u PYTHONUSERBASE \
        uv --no-config pip install --python "$VENV_PYTHON" "$@"
}

cd "$1"
uv_install 'nanobind==2.10.2'
uv_install -e . --no-build-isolation
