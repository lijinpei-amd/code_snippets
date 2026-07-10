#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILE="$SCRIPT_DIR/setup_dev_environment.Dockerfile"
DOCKER_BIN="${DOCKER:-docker}"

UBUNTU_IMAGE="${SETUP_TEST_UBUNTU_IMAGE:-ubuntu:24.04}"
ARCH_IMAGE="${SETUP_TEST_ARCH_IMAGE:-archlinux:latest}"

run_test() {
    local name="$1"
    local image="$2"
    local tag="setup-dev-environment-test:${name}"

    echo "==> testing setup_dev_environment.sh on ${image}"
    "$DOCKER_BIN" build \
        --pull \
        --file "$DOCKERFILE" \
        --build-arg "BASE_IMAGE=$image" \
        --tag "$tag" \
        "$REPO_ROOT"
}

run_test ubuntu "$UBUNTU_IMAGE"
run_test archlinux "$ARCH_IMAGE"
