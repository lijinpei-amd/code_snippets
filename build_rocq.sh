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
# Idempotent: a no-op if the switch already has a working coqc at the target
# version. Re-running is safe (the platform script itself is re-runnable).
#
set -euo pipefail

PLATFORM_TAG="2025.08.3"            # git tag of rocq-prover/platform to use
PLATFORM_PICK="9.0~2025.08"         # package-pick selecting Rocq 9.0.x
ROCQ_SWITCH="CP.2025.08.0~9.0~2025.08"
ROCQ_VERSION_RE="9\.0\."           # accept any 9.0.x patch level
PREFIX="$HOME/proot/rocq"          # = OPAMROOT
export OPAMROOT="$PREFIX"

COQC="$PREFIX/$ROCQ_SWITCH/bin/coqc"

# Already built at the right version? Keeps re-runs of the setup fast and
# offline-safe instead of recloning + recompiling OCaml and Rocq.
if [ -x "$COQC" ] && "$COQC" --version 2>/dev/null | grep -qE "version ${ROCQ_VERSION_RE}"; then
    echo "Rocq $("$COQC" --version | grep -oE "version [0-9.]+") already installed at $PREFIX/$ROCQ_SWITCH; nothing to do."
    exit 0
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

echo "==> Cloning rocq-prover/platform @ ${PLATFORM_TAG}..."
git clone --branch "$PLATFORM_TAG" --depth 1 \
    https://github.com/rocq-prover/platform.git "$BUILD_DIR/platform"
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

echo "==> Installing coq-simple-io (needed by the SF Extraction chapter)..."
eval "$(opam env --switch="$ROCQ_SWITCH" --set-switch)"
opam install -y coq-simple-io

# Verify the installed binary actually runs before declaring success.
"$COQC" --version

echo "==> Done. Rocq installed to $PREFIX/$ROCQ_SWITCH"
echo "    The env vars are managed by dotfiles/env/dot-env_stow.sh (stowed via"
echo "    'setup_dev_environment.sh --components env'); open a new shell to pick"
echo "    them up, or for a one-off:"
echo "      export OPAMROOT=\"$PREFIX\""
echo "      eval \"\$(opam env --switch='$ROCQ_SWITCH' --set-switch)\""
