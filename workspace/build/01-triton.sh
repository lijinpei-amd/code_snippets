#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/venv.sh"

cd "$1"
uv_install 'nanobind==2.10.2'
uv_install -e . --no-build-isolation
