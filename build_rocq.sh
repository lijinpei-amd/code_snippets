#!/usr/bin/env bash
#
# Build the Rocq prover (formerly Coq) 9.0.x from source via the Rocq Platform
# scripts + opam, installing into a dedicated opam root at ~/proot/rocq.
#
# Why the platform scripts (and not `apt install coq`)? Ubuntu's packaged Coq
# lags well behind, and Software Foundations (lf) pins Rocq 9.0.0+. The platform
# "compile from sources using scripts / opam" method builds a matching toolchain
# (OCaml + Rocq + coq-simple-io for the Extraction chapter) in its own switch,
# without disturbing any system OCaml/opam setup.
#
# Layout decisions (must stay in sync with dotfiles/env/dot-env_stow.sh):
#   - OPAMROOT = ~/proot/rocq        (opam couples build tree + install prefix in
#                                     one switch, so this is THE install dest)
#   - switch   = CP.2025.08.0~9.0~2025.08
#   - the platform repo is cloned into a throwaway temp dir (only its scripts are
#     needed; everything durable lands under OPAMROOT)
#
# Fully unattended: COQREGTESTING=y skips the intro prompt and the bubblewrap
# sandbox prompt (auto --disable-sandboxing, since bwrap is absent on stock
# Ubuntu); every other choice is passed as a flag. The script `sudo apt install`s
# its system prerequisites, so passwordless sudo (or an interactive sudo) is
# required the first time.
#
# Idempotent: a no-op only if the switch has both a working coqc at the target
# version and the pinned coq-simple-io package. A partial earlier run that
# omitted coq-simple-io repairs just that package instead of rebuilding Rocq.
#
set -euo pipefail

PLATFORM_TAG="2025.08.3"            # git tag of rocq-prover/platform to use
PLATFORM_REVISION="03c9920c99370e10cade113fb91c89b34f678e1f"
PLATFORM_SHA256="e8c898cb4d15594b1d774cecce7e89930d9f0d500eeba33099bca8e9f4bbb50f"
PLATFORM_URL="https://codeload.github.com/rocq-prover/platform/tar.gz/${PLATFORM_REVISION}"
PLATFORM_PICK="9.0~2025.08"         # package-pick selecting Rocq 9.0.x
ROCQ_SWITCH="CP.2025.08.0~9.0~2025.08"
ROCQ_VERSION_RE="9\.0\."           # accept any 9.0.x patch level
COQ_SIMPLE_IO_VERSION="1.11.0"
PREFIX="$HOME/proot/rocq"          # = OPAMROOT
export OPAMROOT="$PREFIX"

COQC="$PREFIX/$ROCQ_SWITCH/bin/coqc"

rocq_installed() {
    [ -x "$COQC" ] \
        && "$COQC" --version 2>/dev/null | grep -qE "version ${ROCQ_VERSION_RE}"
}

simple_io_installed() {
    command -v opam >/dev/null 2>&1 \
        && [ "$(opam var --switch="$ROCQ_SWITCH" 'coq-simple-io:version' 2>/dev/null)" \
            = "$COQ_SIMPLE_IO_VERSION" ]
}

# Keep complete re-runs fast and offline-safe. Do not return early for the
# partial state where coqc exists but coq-simple-io does not.
if rocq_installed && simple_io_installed; then
    echo "Rocq $("$COQC" --version | grep -oE "version [0-9.]+") already installed at $PREFIX/$ROCQ_SWITCH; nothing to do."
    exit 0
fi

NEED_PLATFORM_BUILD=1
if rocq_installed; then
    NEED_PLATFORM_BUILD=0
    echo "Rocq is installed but coq-simple-io ${COQ_SIMPLE_IO_VERSION} is missing; repairing it."
fi

# opam (invoked by the platform script below) refuses to operate without unzip,
# which it uses to unpack source archives -- it aborts with
#   [ERROR] Missing dependencies -- the following commands are required ...: unzip
# before reaching the platform script's own `sudo apt install` of prerequisites.
# setup_dev_environment.sh's install_base normally provides it, but ensure it
# here too so this script stands alone on a fresh machine.
if ! command -v unzip >/dev/null 2>&1; then
    echo "==> Installing unzip (required by opam)..."
    if   command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y unzip
    elif command -v pacman  >/dev/null 2>&1; then sudo pacman -S --needed --noconfirm unzip
    else echo "error: cannot install unzip: no apt-get or pacman found" >&2; exit 1
    fi
fi

# -jobs is capped at 16 by the platform script's argument validator.
JOBS=$(nproc); [ "$JOBS" -gt 16 ] && JOBS=16

BUILD_DIR="$(mktemp -d)"
cleanup() { echo "Cleaning up build directory: $BUILD_DIR"; rm -rf "$BUILD_DIR"; }
trap cleanup EXIT

if [ "$NEED_PLATFORM_BUILD" -eq 1 ]; then
    archive="$BUILD_DIR/platform-${PLATFORM_TAG}.tar.gz"
    echo "==> Downloading rocq-prover/platform ${PLATFORM_TAG} (${PLATFORM_REVISION})..."
    curl -fSL --retry 3 -o "$archive" "$PLATFORM_URL"
    actual_sha256=$(sha256sum "$archive" | awk '{print $1}')
    if [ "$actual_sha256" != "$PLATFORM_SHA256" ]; then
        echo "error: Rocq Platform archive SHA-256 mismatch" >&2
        echo "       expected: $PLATFORM_SHA256" >&2
        echo "       actual:   $actual_sha256" >&2
        exit 1
    fi
    mkdir "$BUILD_DIR/platform"
    tar xzf "$archive" --strip-components=1 -C "$BUILD_DIR/platform"
    cd "$BUILD_DIR/platform"

    echo "==> Building Rocq (extent=base, pick=${PLATFORM_PICK}, jobs=${JOBS}) into $PREFIX ..."
    echo "    (this runs 'sudo apt install' for prerequisites and compiles OCaml + Rocq; ~10-40 min)"
    # COQREGTESTING=y  -> non-interactive: skips intro + sandbox prompts, auto --disable-sandboxing
    # -extent=b        -> base Coq only (also forces -large=e: no VST/UniMath/fiat-crypto)
    # -set-switch=n    -> do not touch any global default opam switch
    # -switch=d        -> if the switch already exists (partial prior run), recreate it
    COQREGTESTING=y OPAMYES=1 \
        ./coq_platform_make.sh \
            -extent=b -large=e -compcert=n -vst=n -unimath=n -fiatcrypto=n \
            -parallel=p -jobs="$JOBS" -switch=d -set-switch=n \
            -pick="$PLATFORM_PICK"
fi

echo "==> Installing coq-simple-io (needed by the SF Extraction chapter)..."
command -v opam >/dev/null 2>&1 || {
    echo "error: opam is required to install coq-simple-io" >&2
    exit 1
}
eval "$(opam env --switch="$ROCQ_SWITCH" --set-switch)"
opam install -y "coq-simple-io.${COQ_SIMPLE_IO_VERSION}"

# Verify both parts before declaring success.
"$COQC" --version
if ! simple_io_installed; then
    echo "error: coq-simple-io ${COQ_SIMPLE_IO_VERSION} was not installed in $ROCQ_SWITCH" >&2
    exit 1
fi

echo "==> Done. Rocq installed to $PREFIX/$ROCQ_SWITCH"
echo "    The env vars are managed by dotfiles/env/dot-env_stow.sh (stowed via"
echo "    'setup_dev_environment.sh --components env'); open a new shell to pick"
echo "    them up, or for a one-off:"
echo "      export OPAMROOT=\"$PREFIX\""
echo "      eval \"\$(opam env --switch='$ROCQ_SWITCH' --set-switch)\""
