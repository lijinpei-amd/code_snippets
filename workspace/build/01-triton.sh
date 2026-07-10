#!/usr/bin/env bash
set -euo pipefail
cd "$1"
uv pip install -U nanobind
uv pip install -e . --no-build-isolation
