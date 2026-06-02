#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOW_DIR="$SCRIPT_DIR/dotfiles"
# The "dot-" directory convention (dot-config, dot-claude, ...) needs GNU Stow
# >= 2.4.0: 2.3.1's --dotfiles mistranslates a "dot-" prefixed *directory* under
# --no-folding. install_base builds 2.4.x into ~/proot/stow (see build_stow.sh);
# resolve_stow() prefers that build but accepts any new-enough stow on PATH, so
# --config-only works on hosts that already have a suitable stow.
STOW_BIN="$HOME/proot/stow/bin/stow"

# stow_at_least_24 BIN — true if BIN is a stow with version >= 2.4.0.
stow_at_least_24() {
    local v major minor
    v=$("$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) || return 1
    [ -n "$v" ] || return 1
    major=${v%%.*}; minor=${v#*.}; minor=${minor%%.*}
    [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 4 ]; }
}

# resolve_stow — point STOW_BIN at a usable (>= 2.4.0) stow, or fail clearly.
# Prefers ~/proot/stow, then falls back to a new-enough stow on PATH.
resolve_stow() {
    if [ -x "$STOW_BIN" ] && stow_at_least_24 "$STOW_BIN"; then return 0; fi
    local path_stow
    path_stow=$(command -v stow 2>/dev/null || true)
    if [ -n "$path_stow" ] && stow_at_least_24 "$path_stow"; then
        STOW_BIN="$path_stow"; return 0
    fi
    echo "error: GNU Stow >= 2.4.0 not found (needed for --dotfiles directory packages);" >&2
    echo "       run $SCRIPT_DIR/build_stow.sh to build it into ~/proot/stow" >&2
    return 1
}

# stow_pkg PACKAGE
# Symlink the files in dotfiles/PACKAGE/ into $HOME. Every package uses stow's
# --dotfiles convention: a "dot-" prefix on a file OR directory is rewritten to
# a leading "." at the target (dot-bashrc_stow -> ~/.bashrc_stow,
# dot-config/nvim/... -> ~/.config/nvim/..., dot-claude/... -> ~/.claude/...).
# This requires GNU Stow >= 2.4.0 (provided via ~/proot/stow). Any pre-existing
# real (non-symlink) file at a target path is moved aside to <path>.bak-<timestamp>
# first, so both first-time runs and re-runs are idempotent. --no-folding keeps
# stow from symlinking entire directories like ~/.config (which would capture
# other tools' configs); only individual files become symlinks.
stow_pkg() {
    local pkg="$1"
    local pkg_dir="$STOW_DIR/$pkg"
    [ -d "$pkg_dir" ] || { echo "error: missing stow package $pkg_dir" >&2; exit 1; }
    resolve_stow || exit 1
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    while IFS= read -r -d '' f; do
        local rel="${f#"$pkg_dir"/}"
        # Mirror stow's --dotfiles rewrite (leading "dot-" and any "/dot-"
        # component -> ".") to find the real target path.
        local link_rel="${rel/#dot-/.}"
        local target="$HOME/${link_rel//\/dot-//.}"
        if [ -e "$target" ] && [ ! -L "$target" ]; then
            mv "$target" "$target.bak-$ts"
            echo "    backed up $target -> $target.bak-$ts"
        fi
    done < <(find "$pkg_dir" -type f -print0)
    "$STOW_BIN" --dir="$STOW_DIR" --target="$HOME" --dotfiles --no-folding --restow "$pkg"
}

# json_patch FILE [JQ_ARGS...] — atomically apply a jq filter to a JSON file,
# seeding with {} if the file does not exist yet.
json_patch() {
    local file="$1"; shift
    mkdir -p "$(dirname "$file")"
    local input='{}'
    [ -f "$file" ] && input=$(cat "$file")
    local tmp
    tmp=$(mktemp)
    printf '%s' "$input" | jq "$@" > "$tmp" && mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Distro detection + package abstraction
# ---------------------------------------------------------------------------

DISTRO=

detect_distro() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    fi
    case "${ID:-}${ID_LIKE:-}" in
        *arch*)            DISTRO=arch ;;
        *debian*|*ubuntu*) DISTRO=debian ;;
        *)
            if   command -v pacman  >/dev/null 2>&1; then DISTRO=arch
            elif command -v apt-get >/dev/null 2>&1; then DISTRO=debian
            else
                echo "Unsupported distro: cannot find pacman or apt-get" >&2
                exit 1
            fi
            ;;
    esac
}

pkg_name() {
    case "$DISTRO:$1" in
        arch:python3-neovim)    echo python-pynvim ;;
        arch:silversearcher-ag) echo the_silver_searcher ;;
        arch:gh)                echo github-cli ;;
        *)                      echo "$1" ;;
    esac
}

pkg_install() {
    local pkgs=()
    local p
    for p in "$@"; do pkgs+=("$(pkg_name "$p")"); done
    case "$DISTRO" in
        arch)   sudo pacman -S --needed --noconfirm "${pkgs[@]}" ;;
        debian) sudo apt-get install -y "${pkgs[@]}" ;;
    esac
}

# ---------------------------------------------------------------------------
# Components: install_<name> and/or config_<name>
# ---------------------------------------------------------------------------

ALL_COMPONENTS=(base zsh env bash inputrc tmux nvim git llvm node codex claude gh uv hf)

install_base() {
    # make + perl are build deps for stow (GNU Stow is a Perl program).
    pkg_install zsh git curl python3-neovim silversearcher-ag wget tmux jq ccache make perl
    # Build GNU Stow >= 2.4.0 into ~/proot/stow; the distro package is 2.3.1,
    # which mistranslates "dot-" prefixed directories under --dotfiles --no-folding.
    # build_stow.sh is idempotent (no-op if the right version is already installed).
    "$SCRIPT_DIR/build_stow.sh"
}

install_zsh() {
    if [ -d "${ZSH:-$HOME/.oh-my-zsh}" ]; then
        echo "oh-my-zsh already installed, skipping"
        return 0
    fi
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
}

# Stows ~/.zshenv_stow (environment for all shells) and ~/.zshrc_stow
# (interactive prompt); the user is expected to source each from their own
# ~/.zshenv and ~/.zshrc. We don't touch ~/.zshenv or ~/.zshrc themselves.
config_zsh() {
    stow_pkg zsh
    sudo usermod -s "$(which zsh)" "$(id -un)"
}

config_env()     { stow_pkg env; }
config_bash()    { stow_pkg bash; }
config_inputrc() { stow_pkg inputrc; }
config_tmux()    { stow_pkg tmux; }

install_nvim() {
    sh -c 'curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/autoload/plug.vim --create-dirs \
       https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
}

config_nvim() {
    stow_pkg nvim
    local plug_vim="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/autoload/plug.vim"
    if [ -f "$plug_vim" ] && command -v nvim >/dev/null 2>&1; then
        nvim -c PlugUpgrade -c 'PlugInstall --sync' -c qall
    else
        echo "    (skipping PlugUpgrade/PlugInstall: vim-plug or nvim not installed)" >&2
    fi
}

config_git() {
    git config --global user.name "Li Jinpei"
    git config --global user.email "jinpli@amd.com"
    git config --global core.excludesfile "$HOME/.gitignore"
    stow_pkg git
}

install_llvm() {
    case "$DISTRO" in
        arch)   pkg_install llvm clang lld ;;
        debian)
            local v=22
            wget -qO- https://apt.llvm.org/llvm.sh | sudo bash -s -- "$v"
            sudo update-alternatives --install /usr/bin/clang   clang   "/usr/bin/clang-$v"   100
            sudo update-alternatives --install /usr/bin/clang++ clang++ "/usr/bin/clang++-$v" 100
            sudo update-alternatives --set clang   "/usr/bin/clang-$v"
            sudo update-alternatives --set clang++ "/usr/bin/clang++-$v"
            ;;
    esac
}

install_node() {
    wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    nvm install node
    npm install -g @anthropic-ai/claude-code
    npm install -g @openai/codex
}

config_codex() { stow_pkg codex; }

config_claude() {
    json_patch ~/.claude.json '.hasCompletedOnboarding = true'
    # The stowed settings.json deliberately omits the gateway endpoint and
    # secret (ANTHROPIC_BASE_URL / ANTHROPIC_API_KEY / ANTHROPIC_CUSTOM_HEADERS);
    # those are provided out-of-band (e.g. exported from the personal ~/.env.sh)
    # so no credential lands in the repo.
    stow_pkg claude
}

install_gh() {
    case "$DISTRO" in
        arch)
            pkg_install gh
            ;;
        debian)
            local keyring=/etc/apt/keyrings/githubcli-archive-keyring.gpg
            local sources=/etc/apt/sources.list.d/github-cli.list
            local tmp
            tmp=$(mktemp)
            sudo mkdir -p -m 755 /etc/apt/keyrings /etc/apt/sources.list.d
            wget -nv -O "$tmp" https://cli.github.com/packages/githubcli-archive-keyring.gpg
            sudo tee "$keyring" >/dev/null < "$tmp"
            sudo chmod go+r "$keyring"
            echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://cli.github.com/packages stable main" \
                | sudo tee "$sources" >/dev/null
            sudo apt-get update
            sudo apt-get install -y gh
            ;;
    esac
}

install_uv() {
    curl -LsSf https://astral.sh/uv/install.sh | sh
}

install_hf() {
    curl -LsSf https://hf.co/cli/install.sh | bash
}

# ---------------------------------------------------------------------------
# Driver: arg parsing, validation, dispatch
# ---------------------------------------------------------------------------

DO_INSTALL=1
DO_CONFIG=1
COMPONENTS=()

has_fn() { declare -F "$1" >/dev/null; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

  --config-only          Skip install steps; run only config steps.
  --install-only         Skip config steps; run only install steps.
  --components LIST      Comma-separated component names to act on.
                         Default: all components.
  --list-components      Print available components and exit.
  -h, --help             Show this help.

--config-only and --install-only are mutually exclusive.
--components is independent: it narrows which components run, in either mode.

Available components:
  ${ALL_COMPONENTS[*]}
EOF
}

list_components() {
    local c
    for c in "${ALL_COMPONENTS[@]}"; do
        local has_install=no has_config=no
        has_fn "install_$c" && has_install=yes
        has_fn  "config_$c" && has_config=yes
        printf '  %-10s  install=%-3s  config=%-3s\n' "$c" "$has_install" "$has_config"
    done
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --config-only)   DO_INSTALL=0; shift ;;
            --install-only)  DO_CONFIG=0;  shift ;;
            --components)
                [ $# -ge 2 ] || { echo "error: --components needs an argument" >&2; exit 2; }
                IFS=, read -r -a COMPONENTS <<< "$2"
                shift 2
                ;;
            --components=*)
                IFS=, read -r -a COMPONENTS <<< "${1#--components=}"
                shift
                ;;
            --list-components) list_components; exit 0 ;;
            -h|--help)         usage; exit 0 ;;
            --) shift; break ;;
            *)
                echo "error: unknown option: $1" >&2
                usage >&2
                exit 2
                ;;
        esac
    done
    if [ "$DO_INSTALL" -eq 0 ] && [ "$DO_CONFIG" -eq 0 ]; then
        echo "error: --config-only and --install-only are mutually exclusive" >&2
        exit 2
    fi
}

validate_components() {
    local known c
    declare -A known=()
    for c in "${ALL_COMPONENTS[@]}"; do known[$c]=1; done
    for c in "$@"; do
        if [ -z "${known[$c]:-}" ]; then
            echo "error: unknown component: $c" >&2
            echo "known components: ${ALL_COMPONENTS[*]}" >&2
            exit 2
        fi
    done
}

run_component() {
    local name="$1"
    if [ "$DO_INSTALL" -eq 1 ] && has_fn "install_$name"; then
        echo "==> install: $name"
        "install_$name"
    fi
    if [ "$DO_CONFIG" -eq 1 ] && has_fn "config_$name"; then
        echo "==> config:  $name"
        "config_$name"
    fi
}

main() {
    parse_args "$@"
    detect_distro
    local mode_label
    if   [ "$DO_INSTALL" -eq 0 ]; then mode_label=config-only
    elif [ "$DO_CONFIG"  -eq 0 ]; then mode_label=install-only
    else mode_label=full; fi
    echo "==> distro: $DISTRO   mode: $mode_label"

    local selected
    if [ "${#COMPONENTS[@]}" -eq 0 ]; then
        selected=("${ALL_COMPONENTS[@]}")
    else
        selected=("${COMPONENTS[@]}")
    fi
    validate_components "${selected[@]}"

    local c
    for c in "${selected[@]}"; do run_component "$c"; done
}

main "$@"
