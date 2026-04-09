#!/usr/bin/env bash
set -euo pipefail
cd "$1"
uv pip install -U pybind11
uv pip install -e . --no-build-isolation
