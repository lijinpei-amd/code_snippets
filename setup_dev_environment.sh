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
path_present() {
    [ -e "$1" ] || [ -L "$1" ]
}

# GNU mv -T prevents a directory destination from silently nesting the source;
# -n preserves anything that appears between the caller's check and the move.
# Because -n reports success when it skips, also require the source to vanish.
move_path_exact_noreplace() {
    local source="$1" destination="$2"

    mv -Tn -- "$source" "$destination" || return 1
    ! path_present "$source"
}

rollback_stow_backups() {
    local remove_managed_links="$1"
    local -n targets_ref="$2" backups_ref="$3" sources_ref="$4"
    local i target backup expected actual expected_real

    for ((i=${#targets_ref[@]} - 1; i >= 0; i--)); do
        target=${targets_ref[$i]}
        backup=${backups_ref[$i]}
        expected=${sources_ref[$i]}

        # A failed Stow invocation may have installed some of its own links
        # before returning. Remove only the exact managed link; never clobber a
        # file or link that appeared concurrently.
        if [ "$remove_managed_links" -eq 1 ] && [ -L "$target" ]; then
            actual=$(readlink -f -- "$target" || true)
            expected_real=$(readlink -f -- "$expected" || true)
            if [ -n "$expected_real" ] && [ "$actual" = "$expected_real" ]; then
                if ! rm -- "$target"; then
                    echo "warning: could not remove managed symlink at $target; backup remains at $backup" >&2
                    continue
                fi
            else
                echo "warning: not overwriting unexpected symlink at $target; backup remains at $backup" >&2
                continue
            fi
        elif path_present "$target"; then
            echo "warning: not overwriting unexpected replacement at $target; backup remains at $backup" >&2
            continue
        fi

        if ! path_present "$backup"; then
            echo "warning: backup disappeared before rollback: $backup" >&2
            continue
        fi

        # GNU mv -n can report success when it declines to overwrite a target.
        # Check that the source actually disappeared so a destination created
        # during rollback cannot turn this into either data loss or nesting.
        if ! move_path_exact_noreplace "$backup" "$target"; then
            echo "warning: could not restore $backup to $target; backup remains in place" >&2
        fi
    done
}

stow_pkg() {
    local pkg="$1"
    local pkg_dir="$STOW_DIR/$pkg"
    local -a moved_targets=() backup_paths=() source_paths=()
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
            local backup="$target.bak-$ts" suffix=0
            while [ -e "$backup" ] || [ -L "$backup" ]; do
                suffix=$((suffix + 1))
                backup="$target.bak-$ts.$suffix"
            done
            if ! move_path_exact_noreplace "$target" "$backup"; then
                echo "error: could not back up $target; restoring earlier user files" >&2
                if path_present "$backup"; then
                    echo "warning: the original may remain at $backup; it will not be overwritten" >&2
                fi
                rollback_stow_backups 0 moved_targets backup_paths source_paths
                return 1
            fi
            moved_targets+=("$target")
            backup_paths+=("$backup")
            source_paths+=("$f")
            echo "    backed up $target -> $backup"
        fi
    done < <(find "$pkg_dir" -type f -print0)
    if ! "$STOW_BIN" --dir="$STOW_DIR" --target="$HOME" --dotfiles --no-folding --restow "$pkg"; then
        echo "error: stowing $pkg failed; restoring moved user files" >&2
        rollback_stow_backups 1 moved_targets backup_paths source_paths
        return 1
    fi
}

# json_patch FILE [JQ_ARGS...] — atomically apply a jq filter to a JSON file,
# seeding with {} if the file does not exist yet.
json_patch() {
    local file="$1"; shift
    local parent
    parent=$(dirname "$file")
    mkdir -p "$parent"
    local input='{}'
    [ -f "$file" ] && input=$(cat "$file")
    local tmp
    tmp=$(mktemp "$parent/.${file##*/}.XXXXXX")
    if printf '%s' "$input" | jq "$@" > "$tmp"; then
        mv -T -- "$tmp" "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

# Download a pinned artifact and reject it before use unless its bytes match the
# reviewed digest. Callers provide immutable release/commit URLs where upstream
# offers them; the digest also protects mirrors and accidental tag replacement.
download_verified() {
    local url="$1" expected_sha256="$2" output="$3" actual_sha256

    curl --proto '=https' --tlsv1.2 -fSL --retry 3 -o "$output" "$url"
    actual_sha256=$(sha256sum "$output" | awk '{print $1}')
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        echo "error: SHA-256 mismatch for $url" >&2
        echo "       expected: $expected_sha256" >&2
        echo "       actual:   $actual_sha256" >&2
        rm -f "$output"
        return 1
    fi
}

download_verified_sha512() {
    local url="$1" expected_sha512="$2" output="$3" actual_sha512

    curl --proto '=https' --tlsv1.2 -fSL --retry 3 -o "$output" "$url"
    actual_sha512=$(sha512sum "$output" | awk '{print $1}')
    if [ "$actual_sha512" != "$expected_sha512" ]; then
        echo "error: SHA-512 mismatch for $url" >&2
        echo "       expected: $expected_sha512" >&2
        echo "       actual:   $actual_sha512" >&2
        rm -f "$output"
        return 1
    fi
}

# Verify the ordered primary-key fingerprints in an OpenPGP key or keyring.
# A private temporary GNUPGHOME avoids modifying the user's keyring.
verify_openpgp_fingerprints() {
    local key_file="$1" gnupg_home actual expected
    shift
    gnupg_home=$(mktemp -d)
    chmod 700 "$gnupg_home"
    actual=$(
        GNUPGHOME="$gnupg_home" gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null \
            | awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }'
    )
    rm -rf "$gnupg_home"
    expected=$(printf '%s\n' "$@")
    if [ "$actual" != "$expected" ]; then
        echo "error: unexpected OpenPGP primary-key fingerprints in $key_file" >&2
        echo "expected:" >&2
        printf '  %s\n' "$@" >&2
        echo "actual:" >&2
        printf '  %s\n' "$actual" >&2
        return 1
    fi
}

# Atomically replace a disposable tool tree with a verified commit archive.
install_verified_tree() {
    local name="$1" url="$2" sha256="$3" revision="$4" destination="$5" required_file="$6"
    local parent tmp archive staged

    if [ -f "$destination/.codex-pinned-revision" ] \
        && [ "$(cat "$destination/.codex-pinned-revision")" = "$revision" ] \
        && [ -e "$destination/$required_file" ]; then
        echo "$name $revision already installed; nothing to do."
        return 0
    fi

    parent=$(dirname "$destination")
    mkdir -p "$parent"
    tmp=$(mktemp -d "$parent/.${name}.stage.XXXXXX")
    archive="$tmp/source.tar.gz"
    staged="$tmp/staged"
    mkdir "$staged"
    download_verified "$url" "$sha256" "$archive" || { rm -rf "$tmp"; return 1; }
    tar xzf "$archive" --strip-components=1 -C "$staged" || { rm -rf "$tmp"; return 1; }
    [ -e "$staged/$required_file" ] || {
        echo "error: $name archive lacks $required_file" >&2
        rm -rf "$tmp"
        return 1
    }
    printf '%s\n' "$revision" > "$staged/.codex-pinned-revision"

    activate_staged_tree "$staged" "$destination" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
}

activate_staged_tree() {
    local staged="$1" destination="$2" backup="" backup_root=""
    local parent destination_name transfer transfer_root

    parent=$(dirname "$destination")
    destination_name=${destination##*/}
    mkdir -p "$parent"
    transfer_root=$(mktemp -d "$parent/.activate-stage.XXXXXX")
    transfer="$transfer_root/tree"
    if ! move_path_exact_noreplace "$staged" "$transfer"; then
        rm -rf "$transfer_root"
        return 1
    fi

    if path_present "$destination"; then
        backup_root=$(mktemp -d "$parent/.${destination_name}.backup.XXXXXX")
        backup="$backup_root/tree"
        if ! move_path_exact_noreplace "$destination" "$backup"; then
            if path_present "$backup"; then
                echo "error: destination changed while being moved; previous tree remains at $backup" >&2
            else
                echo "error: could not move existing destination aside: $destination" >&2
            fi
            rm -rf "$transfer_root"
            if ! path_present "$backup"; then
                rm -rf "$backup_root"
            fi
            return 1
        fi
    fi
    if ! move_path_exact_noreplace "$transfer" "$destination"; then
        rm -rf "$transfer_root"
        if [ -n "$backup" ]; then
            if path_present "$destination"; then
                echo "error: destination reappeared during activation; previous tree remains at $backup" >&2
            elif ! move_path_exact_noreplace "$backup" "$destination"; then
                echo "error: activation failed and previous tree could not be restored; it remains at $backup" >&2
            else
                rmdir "$backup_root"
            fi
        fi
        return 1
    fi
    rmdir "$transfer_root"
    [ -z "$backup_root" ] || rm -rf "$backup_root"
}

# ---------------------------------------------------------------------------
# Distro detection + package abstraction
# ---------------------------------------------------------------------------

DISTRO=
APT_UPDATED=0

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

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
        arch:python3-neovim|arch:python3-pynvim) echo python-pynvim ;;
        arch:silversearcher-ag)                   echo the_silver_searcher ;;
        arch:gh)                                  echo github-cli ;;
        arch:usermod)                             echo shadow ;;
        debian:ninja)                             echo ninja-build ;;
        debian:python3-neovim)                    echo python3-pynvim ;;
        debian:usermod)                           echo passwd ;;
        *)                                        echo "$1" ;;
    esac
}

apt_update_once() {
    [ "$APT_UPDATED" -eq 1 ] && return 0
    as_root apt-get update
    APT_UPDATED=1
}

pkg_install() {
    local pkgs=()
    local p
    for p in "$@"; do pkgs+=("$(pkg_name "$p")"); done
    case "$DISTRO" in
        arch)   as_root pacman -S --needed --noconfirm "${pkgs[@]}" ;;
        debian)
            apt_update_once
            as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Components: install_<name> and/or config_<name>
# ---------------------------------------------------------------------------

# DEFAULT_COMPONENTS run on a plain (no --components) invocation.
DEFAULT_COMPONENTS=(base zsh env bash inputrc tmux nvim git llvm ccache gdb node codex claude gh uv precommit hf)
# OPT_IN_COMPONENTS are recognised by --components but excluded from the default
# run. rocq builds a dedicated opam + OCaml + Rocq/Coq toolchain (~10-40 min,
# heavy) needed only for the Software Foundations volumes, so it must be asked
# for explicitly: setup_dev_environment.sh --components rocq
OPT_IN_COMPONENTS=(rocq)
# Full set of valid component names (default + opt-in); used for validation and
# --list-components.
ALL_COMPONENTS=("${DEFAULT_COMPONENTS[@]}" "${OPT_IN_COMPONENTS[@]}")

install_base() {
    # make + perl are build deps for stow (GNU Stow is a Perl program).
    # (opam's unzip dependency lives in build_rocq.sh, which is opt-in.)
    pkg_install zsh git curl ca-certificates python3-pynvim silversearcher-ag wget tmux jq ccache gdb make perl sudo usermod cmake ninja fzf
    # Build GNU Stow >= 2.4.0 into ~/proot/stow; the distro package is 2.3.1,
    # which mistranslates "dot-" prefixed directories under --dotfiles --no-folding.
    # build_stow.sh is idempotent (no-op if the right version is already installed).
    "$SCRIPT_DIR/build_stow.sh"
}

install_zsh() {
    local zsh_dir="${ZSH:-$HOME/.oh-my-zsh}"
    local revision="677a4592b18c08ddea737f8aca70bac0e9fc9313"
    local sha256="f8c4c980bf28c77db703e083b5d395a2c42403abddbd36467c41a50a476fd841"
    local url="https://codeload.github.com/ohmyzsh/ohmyzsh/tar.gz/${revision}"

    # Preserve existing installations and their custom themes/plugins. Fresh
    # installs use a reviewed commit archive instead of executing master/main.
    if [ -d "$zsh_dir" ]; then
        echo "oh-my-zsh already installed, skipping"
        return 0
    fi
    install_verified_tree oh-my-zsh "$url" "$sha256" "$revision" "$zsh_dir" oh-my-zsh.sh
}

# Stows ~/.zshenv_stow (environment for all shells) and ~/.zshrc_stow
# (interactive prompt). Existing ~/.zshrc content is retained and the managed
# fragment is appended only when no active source command already references it.
# Oh My Zsh must load first because the managed prompt uses its color and Git
# helpers. Existing user initialization is honored; otherwise a guarded block is
# inserted immediately before an existing managed-fragment source or appended.
config_zsh() {
    local zshrc="$HOME/.zshrc" zshenv="$HOME/.zshenv" tmp

    stow_pkg zsh

    # Resolve a pre-existing symlink so insertion rewrites its target rather
    # than replacing the user's link.
    if [ -L "$zshrc" ]; then
        zshrc=$(readlink -f "$zshrc")
    fi

    if ! [ -f "$zshrc" ] \
        || ! grep -Eq '^[[:space:]]*(source|\.)[[:space:]].*oh-my-zsh\.sh' "$zshrc"; then
        if [ -f "$zshrc" ] \
            && grep -Eq '^[[:space:]]*(source|\.)[[:space:]].*\.zshrc_stow' "$zshrc"; then
            tmp=$(mktemp "$(dirname "$zshrc")/.zshrc.XXXXXX")
            awk '
                !inserted && $0 ~ /^[[:space:]]*(source|\.)[[:space:]].*\.zshrc_stow/ {
                    print "# Initialize the pinned Oh My Zsh tree before managed prompt config."
                    print "if [ -z \"${CODE_SNIPPETS_OMZ_LOADED:-}\" ]; then"
                    print "    : \"${ZSH:=$HOME/.oh-my-zsh}\""
                    print "    export ZSH"
                    print "    if [ -s \"$ZSH/oh-my-zsh.sh\" ]; then"
                    print "        source \"$ZSH/oh-my-zsh.sh\""
                    print "        export CODE_SNIPPETS_OMZ_LOADED=1"
                    print "    fi"
                    print "fi"
                    inserted = 1
                }
                { print }
            ' "$zshrc" > "$tmp"
            chmod --reference="$zshrc" "$tmp"
            mv -T -- "$tmp" "$zshrc"
        else
            if [ -s "$zshrc" ]; then
                printf '\n' >> "$zshrc"
            fi
            cat >> "$zshrc" <<'EOF'
# Initialize the pinned Oh My Zsh tree before managed prompt config.
if [ -z "${CODE_SNIPPETS_OMZ_LOADED:-}" ]; then
    : "${ZSH:=$HOME/.oh-my-zsh}"
    export ZSH
    if [ -s "$ZSH/oh-my-zsh.sh" ]; then
        source "$ZSH/oh-my-zsh.sh"
        export CODE_SNIPPETS_OMZ_LOADED=1
    fi
fi
EOF
        fi
    fi

    if ! grep -Eq '^[[:space:]]*(source|\.)[[:space:]].*\.zshrc_stow' "$zshrc"; then
        if [ -s "$zshrc" ]; then
            printf '\n' >> "$zshrc"
        fi
        cat >> "$zshrc" <<'EOF'
# Load the repository-managed interactive zsh configuration.
if [ -r "$HOME/.zshrc_stow" ]; then
    source "$HOME/.zshrc_stow"
fi
EOF
    fi

    if ! [ -f "$zshenv" ] \
        || ! grep -Eq '^[[:space:]]*(source|\.)[[:space:]].*\.zshenv_stow' "$zshenv"; then
        if [ -s "$zshenv" ]; then
            printf '\n' >> "$zshenv"
        fi
        cat >> "$zshenv" <<'EOF'
# Load the repository-managed non-interactive zsh environment.
if [ -r "$HOME/.zshenv_stow" ]; then
    source "$HOME/.zshenv_stow"
fi
EOF
    fi

    as_root usermod -s "$(command -v zsh)" "$(id -un)"
}

config_env()     { stow_pkg env; }
config_bash()    { stow_pkg bash; }
config_inputrc() { stow_pkg inputrc; }

# tpm (Tmux Plugin Manager) is to tmux what vim-plug is to nvim: install_tmux
# installs the manager plus every declared plugin from verified archives, while
# config_tmux only stows the conf. dot-tmux.conf's final `run` line loads tpm at tmux
# startup, so without tpm that line fails with 127. install runs before config,
# so the clone also creates the real ~/.tmux directory that stow_pkg then links
# name-session.sh into. The manager itself is pinned to a reviewed commit.
install_tmux() {
    local tpm_dir="$HOME/.tmux/plugins/tpm"
    local navigator_dir="$HOME/.tmux/plugins/vim-tmux-navigator"
    local revision="e261deb1b47614eed3400089ce7197dc68acc4eb"
    local sha256="72d92c512270d4857e27519ac97b92a52cf149afe4d92f26860c710f60bbbe37"
    local url="https://codeload.github.com/tmux-plugins/tpm/tar.gz/${revision}"
    install_verified_tree tpm "$url" "$sha256" "$revision" "$tpm_dir" bin/install_plugins

    revision="e41c431a0c7b7388ae7ba341f01a0d217eb3a432"
    sha256="ea2ca9a016487ba062b4a02e183eceaf5ef9b09016e1af0a5ff627a3af7a721c"
    url="https://codeload.github.com/christoomey/vim-tmux-navigator/tar.gz/${revision}"
    install_verified_tree vim-tmux-navigator "$url" "$sha256" "$revision" \
        "$navigator_dir" vim-tmux-navigator.tmux
}

config_tmux() {
    stow_pkg tmux
    # install_tmux installs every declared plugin from a verified commit
    # archive. Do not invoke TPM's network installer here: config-only mode
    # must not clone mutable plugin heads, and the full install already has
    # everything this configuration declares.
}

install_nvim() {
    local version="0.11.7" platform sha256 release_url prefix="$HOME/proot/nvim"
    local revision="88e31471818e9a29a8a20a0ee61360cfd7bdc1cd"
    local plug_sha256="7e2b20cd909da9c456498684c98f03c63829170f01e34595dd8e1818a217d37c"
    local plug_url="https://raw.githubusercontent.com/junegunn/vim-plug/${revision}/plug.vim"
    local plug_dir="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/autoload"
    local tmp staged installed_version=""

    case "$(uname -m)" in
        x86_64|amd64)
            platform=x86_64
            sha256="38a7c6317f94503841096c00e8fde05ef04b9472fc9d7d62b6e033cecd6f7991"
            ;;
        aarch64|arm64)
            platform=arm64
            sha256="99bb3c53604e83ce18fc0b459e34cf1a5e212f4e5fbe2eb136b3c18092ae9905"
            ;;
        *)
            echo "error: unsupported Neovim architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
    release_url="https://github.com/neovim/neovim/releases/download/v${version}/nvim-linux-${platform}.tar.gz"

    if [ -x "$prefix/bin/nvim" ]; then
        installed_version=$("$prefix/bin/nvim" --version 2>/dev/null | sed -n '1p' || true)
    fi
    if [ "$installed_version" != "NVIM v${version}" ]; then
        tmp=$(mktemp -d)
        staged="$tmp/nvim"
        mkdir "$staged"
        download_verified "$release_url" "$sha256" "$tmp/nvim.tar.gz" \
            || { rm -rf "$tmp"; return 1; }
        tar xzf "$tmp/nvim.tar.gz" --strip-components=1 -C "$staged" \
            || { rm -rf "$tmp"; return 1; }
        [ "$("$staged/bin/nvim" --version | sed -n '1p')" = "NVIM v${version}" ] || {
            echo "error: downloaded Neovim reports an unexpected version" >&2
            rm -rf "$tmp"
            return 1
        }
        activate_staged_tree "$staged" "$prefix" || { rm -rf "$tmp"; return 1; }
        rm -rf "$tmp"
    fi
    export PATH="$prefix/bin:$PATH"

    mkdir -p "$plug_dir"
    tmp=$(mktemp "$plug_dir/.plug.vim.XXXXXX")
    download_verified "$plug_url" "$plug_sha256" "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp"
    mv -T -- "$tmp" "$plug_dir/plug.vim"
}

config_nvim() {
    stow_pkg nvim
    local plug_vim="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/autoload/plug.vim"
    if [ -f "$plug_vim" ] && command -v nvim >/dev/null 2>&1; then
        # plug.vim itself is installed from a verified commit in install_nvim;
        # keep that reviewed manager revision unchanged.
        # PlugUpdate also forces existing plugin checkouts to their declared
        # commits; PlugInstall would leave already-present mutable HEADs alone.
        nvim -c 'PlugUpdate --sync' -c qall
    else
        echo "    (skipping PlugUpdate: vim-plug or nvim not installed)" >&2
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
            local installer_revision="1b51a8ac5d22abf492d8fae0cc9964da55464ce4"
            local installer_sha256="9474ecd78b52aba6e923976b1e9773f5613027cc7e237b9956986cb536e02a36"
            local installer_url="https://raw.githubusercontent.com/opencollab/llvm-jenkins.debian.net/${installer_revision}/llvm.sh"
            local llvm_key_url="https://apt.llvm.org/llvm-snapshot.gpg.key"
            local llvm_key_sha256="8b2a587ffd672c4687e7581dad4b2f6c1bb2ad6b480cd9771ba2ff48e0b8c75d"
            local llvm_key_fingerprint="6084F3CF814B57C1CF12EFD515CF4D18AF4F7421"
            local tmpdir

            pkg_install gnupg lsb-release software-properties-common
            tmpdir=$(mktemp -d)
            download_verified "$llvm_key_url" "$llvm_key_sha256" "$tmpdir/llvm-snapshot.gpg.key" \
                || { rm -rf "$tmpdir"; return 1; }
            verify_openpgp_fingerprints "$tmpdir/llvm-snapshot.gpg.key" "$llvm_key_fingerprint" \
                || { rm -rf "$tmpdir"; return 1; }
            as_root install -m 0644 "$tmpdir/llvm-snapshot.gpg.key" \
                /etc/apt/trusted.gpg.d/apt.llvm.org.asc \
                || { rm -rf "$tmpdir"; return 1; }

            download_verified "$installer_url" "$installer_sha256" "$tmpdir/llvm.sh" \
                || { rm -rf "$tmpdir"; return 1; }
            if ! as_root bash "$tmpdir/llvm.sh" "$v"; then
                rm -rf "$tmpdir"
                return 1
            fi
            rm -rf "$tmpdir"
            as_root update-alternatives --install /usr/bin/clang   clang   "/usr/bin/clang-$v"   100
            as_root update-alternatives --install /usr/bin/clang++ clang++ "/usr/bin/clang++-$v" 100
            as_root update-alternatives --set clang   "/usr/bin/clang-$v"
            as_root update-alternatives --set clang++ "/usr/bin/clang++-$v"
            # llvm.sh installs lld-$v but only as versioned binaries; clang's
            # -fuse-ld=lld (set by our LLVM_ENABLE_LLD=ON build) searches PATH
            # for an unversioned ld.lld, so wire that up too or linking fails
            # with "invalid linker name in argument '-fuse-ld=lld'".
            as_root update-alternatives --install /usr/bin/ld.lld ld.lld "/usr/bin/ld.lld-$v" 100
            as_root update-alternatives --install /usr/bin/lld    lld    "/usr/bin/lld-$v"    100
            as_root update-alternatives --set ld.lld "/usr/bin/ld.lld-$v"
            as_root update-alternatives --set lld    "/usr/bin/lld-$v"
            ;;
    esac
}

# Rocq prover (formerly Coq), for the Software Foundations volumes. build_rocq.sh
# compiles Rocq 9.0.x + coq-simple-io into its own opam root at ~/proot/rocq and
# is idempotent (no-op if already built). The env vars (OPAMROOT, switch PATH,
# OCaml runtime paths) are managed by the `env` component via
# dotfiles/env/dot-env_stow.sh, so there is no separate config_rocq.
install_rocq() { "$SCRIPT_DIR/build_rocq.sh"; }

# Cross-worktree ccache config (base_dir / hash_dir / sloppiness). ccache itself
# is installed in install_base; this only stows ~/.config/ccache/ccache.conf.
config_ccache() { stow_pkg ccache; }

# Global gdbinit that maps the /llvm-project build sentinel back to whichever
# worktree a binary lives in (companion to LLVM_USE_RELATIVE_PATHS_IN_FILES).
config_gdb() { stow_pkg gdb; }

install_node() {
    local nvm_revision="62387b8f92aa012d48202747fd75c40850e5e261"
    local nvm_sha256="f215c2f08c30bcc7fc64b3eaec7136a3ac90994a91524f1f74517186025419d1"
    local nvm_url="https://codeload.github.com/nvm-sh/nvm/tar.gz/${nvm_revision}"
    local node_version="v24.18.0"
    local node_arch node_sha256 node_url node_prefix codex_target
    local claude_version="2.1.207"
    local claude_sha512="df40f794630ed223e65a7cfaac248729de9dea05ad43c095db32871eca441d91728c326c34eaf65e0e8a6ff5c43ec68516ee01188273ffb2fa15091c16ae5c34"
    local claude_native_package claude_native_sha512 claude_native_url
    local codex_version="0.144.1"
    local codex_sha512="5e2af5cea3dfa5e9e1768028b21379deea27cdb0578f5f023b2cd190595566948dc849795ed92e62ef6875d10b78f14decaff4b1751c48edf801de487825cf6f"
    local codex_native_alias codex_native_sha512 codex_native_url
    local tmp staged global_root claude_native_dir codex_native_dir

    export NVM_DIR="$HOME/.nvm"
    if [ ! -f "$NVM_DIR/.codex-pinned-revision" ] \
        || [ "$(cat "$NVM_DIR/.codex-pinned-revision")" != "$nvm_revision" ] \
        || [ ! -s "$NVM_DIR/nvm.sh" ]; then
        tmp=$(mktemp -d)
        mkdir "$tmp/staged"
        download_verified "$nvm_url" "$nvm_sha256" "$tmp/nvm.tar.gz" \
            || { rm -rf "$tmp"; return 1; }
        tar xzf "$tmp/nvm.tar.gz" --strip-components=1 -C "$tmp/staged" \
            || { rm -rf "$tmp"; return 1; }
        [ -s "$tmp/staged/nvm.sh" ] || {
            echo "error: pinned nvm archive lacks nvm.sh" >&2
            rm -rf "$tmp"
            return 1
        }
        mkdir -p "$NVM_DIR"
        # Keep installed Node versions and aliases while replacing nvm's source
        # files with the verified revision.
        cp -a "$tmp/staged/." "$NVM_DIR/"
        printf '%s\n' "$nvm_revision" > "$NVM_DIR/.codex-pinned-revision"
        rm -rf "$tmp"
    fi

    case "$(uname -m)" in
        x86_64|amd64)
            node_arch=x64
            node_sha256="783130984963db7ba9cbd01089eaf2c2efb055c7c1693c943174b967b3050cb8"
            claude_native_package="claude-code-linux-x64"
            claude_native_sha512="582e2ef9b46e47711763b7c5164b959dbf63079217e492ddbb34707ba65c22ed3cb53fcf0d4593f1b9e74b4eeac1cda3ce4512a9c2f79106de1d7e5abe71404b"
            codex_native_alias="codex-linux-x64"
            codex_native_sha512="1cd19523e06e96b39a0bfd08cc1bdde842fada3ecbae56c52a26eb870ea16638c28c0794633441da3078a83cd737535fa838ba5ebbe78a87f79306f069bdb896"
            codex_target="x86_64-unknown-linux-musl"
            ;;
        aarch64|arm64)
            node_arch=arm64
            node_sha256="6b4484c2190274175df9aa8f28e2d758a819cb1c1fe6ab481e2f95b463ab8508"
            claude_native_package="claude-code-linux-arm64"
            claude_native_sha512="26672f9fc4a0f3e15a3cb3b2f6de21ee2a7e2b58b9618ae2993d7e8992f5607053038e161c9f47fc5f035b740a9d5caa506a84cdaf538393cf563ce18b97f0ca"
            codex_native_alias="codex-linux-arm64"
            codex_native_sha512="e39d68d79f97b5a5c209bdf9b7f282cb23ea5c79d33f13f1b5da8460e9c4ddee2c1f901f9c8fee549c1f7633a4b0c1babd12f2e91f9f2ef48338c82e4452e643"
            codex_target="aarch64-unknown-linux-musl"
            ;;
        *)
            echo "error: unsupported Node.js architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
    node_url="https://nodejs.org/dist/${node_version}/node-${node_version}-linux-${node_arch}.tar.gz"
    claude_native_url="https://registry.npmjs.org/@anthropic-ai/${claude_native_package}/-/${claude_native_package}-${claude_version}.tgz"
    codex_native_url="https://registry.npmjs.org/@openai/codex/-/codex-${codex_version}-linux-${node_arch}.tgz"
    node_prefix="$NVM_DIR/versions/node/$node_version"

    if [ ! -x "$node_prefix/bin/node" ] \
        || [ "$("$node_prefix/bin/node" --version 2>/dev/null || true)" != "$node_version" ]; then
        tmp=$(mktemp -d)
        staged="$tmp/node"
        mkdir "$staged"
        download_verified "$node_url" "$node_sha256" "$tmp/node.tar.gz" \
            || { rm -rf "$tmp"; return 1; }
        tar xzf "$tmp/node.tar.gz" --strip-components=1 -C "$staged" \
            || { rm -rf "$tmp"; return 1; }
        [ "$("$staged/bin/node" --version)" = "$node_version" ] || {
            echo "error: downloaded Node.js reports an unexpected version" >&2
            rm -rf "$tmp"
            return 1
        }
        activate_staged_tree "$staged" "$node_prefix" || { rm -rf "$tmp"; return 1; }
        rm -rf "$tmp"
    fi

    mkdir -p "$NVM_DIR/alias"
    printf '%s\n' "$node_version" > "$NVM_DIR/alias/default"
    # shellcheck disable=SC1091
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    nvm use --silent "$node_version"

    # Bind both wrappers and their architecture-specific native binaries to
    # reviewed tarballs. npm runs offline with optional dependencies and scripts
    # disabled; the verified native trees are activated explicitly below.
    tmp=$(mktemp -d)
    download_verified_sha512 \
        "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${claude_version}.tgz" \
        "$claude_sha512" "$tmp/claude-code.tgz" \
        || { rm -rf "$tmp"; return 1; }
    download_verified_sha512 \
        "https://registry.npmjs.org/@openai/codex/-/codex-${codex_version}.tgz" \
        "$codex_sha512" "$tmp/codex.tgz" \
        || { rm -rf "$tmp"; return 1; }
    download_verified_sha512 "$claude_native_url" "$claude_native_sha512" \
        "$tmp/claude-native.tgz" || { rm -rf "$tmp"; return 1; }
    download_verified_sha512 "$codex_native_url" "$codex_native_sha512" \
        "$tmp/codex-native.tgz" || { rm -rf "$tmp"; return 1; }

    npm install -g --offline --ignore-scripts --omit=optional --no-audit --no-fund \
        "$tmp/claude-code.tgz" "$tmp/codex.tgz" \
        || { rm -rf "$tmp"; return 1; }

    global_root=$(npm root -g)
    mkdir "$tmp/claude-native" "$tmp/codex-native"
    tar xzf "$tmp/claude-native.tgz" --strip-components=1 -C "$tmp/claude-native" \
        || { rm -rf "$tmp"; return 1; }
    tar xzf "$tmp/codex-native.tgz" --strip-components=1 -C "$tmp/codex-native" \
        || { rm -rf "$tmp"; return 1; }
    [ -x "$tmp/claude-native/claude" ] || { rm -rf "$tmp"; return 1; }
    [ -x "$tmp/codex-native/vendor/$codex_target/bin/codex" ] \
        || { rm -rf "$tmp"; return 1; }

    claude_native_dir="$global_root/@anthropic-ai/$claude_native_package"
    codex_native_dir="$global_root/@openai/$codex_native_alias"
    activate_staged_tree "$tmp/claude-native" "$claude_native_dir" \
        || { rm -rf "$tmp"; return 1; }
    activate_staged_tree "$tmp/codex-native" "$codex_native_dir" \
        || { rm -rf "$tmp"; return 1; }

    # Reproduce Claude's postinstall locally without executing downloaded JS.
    install -m 0755 "$claude_native_dir/claude" \
        "$global_root/@anthropic-ai/claude-code/bin/claude.exe"
    claude --version >/dev/null
    codex --version >/dev/null
    rm -rf "$tmp"
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
            local key_url="https://cli.github.com/packages/githubcli-archive-keyring.gpg"
            local key_sha256="6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b"
            local tmpdir
            pkg_install gnupg
            tmpdir=$(mktemp -d)
            as_root mkdir -p -m 755 /etc/apt/keyrings /etc/apt/sources.list.d
            download_verified "$key_url" "$key_sha256" "$tmpdir/github-cli.gpg" \
                || { rm -rf "$tmpdir"; return 1; }
            verify_openpgp_fingerprints "$tmpdir/github-cli.gpg" \
                2C6106201985B60E6C7AC87323F3D4EA75716059 \
                7F38BBB59D064DBCB3D84D725612B36462313325 \
                || { rm -rf "$tmpdir"; return 1; }
            as_root install -m 0644 "$tmpdir/github-cli.gpg" "$keyring" \
                || { rm -rf "$tmpdir"; return 1; }
            rm -rf "$tmpdir"
            echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://cli.github.com/packages stable main" \
                | as_root tee "$sources" >/dev/null
            as_root apt-get update
            as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y gh
            ;;
    esac
}

install_uv() {
    local version="0.11.28" platform sha256 url tmp source_dir installed_version=""

    mkdir -p "$HOME/.local/bin"
    if [ -x "$HOME/.local/bin/uv" ]; then
        installed_version=$("$HOME/.local/bin/uv" --version 2>/dev/null || true)
    fi
    if [ -x "$HOME/.local/bin/uv" ] && [ -x "$HOME/.local/bin/uvx" ] \
        && [[ "$installed_version" == "uv $version"* ]]; then
        echo "uv $version already installed; nothing to do."
        return 0
    fi

    case "$(uname -m)" in
        x86_64|amd64)
            platform=x86_64-unknown-linux-gnu
            sha256="e490a6464492183c5d4534a5527fb4440f7f2bb2f228162ad7e4afe076dc0224"
            ;;
        aarch64|arm64)
            platform=aarch64-unknown-linux-gnu
            sha256="03e9fe0a81b0718d0bc84625de3885df6cc3f89a8b6af6121d6b9f6113fb6533"
            ;;
        *)
            echo "error: unsupported uv architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
    url="https://github.com/astral-sh/uv/releases/download/${version}/uv-${platform}.tar.gz"
    tmp=$(mktemp -d)
    download_verified "$url" "$sha256" "$tmp/uv.tar.gz" \
        || { rm -rf "$tmp"; return 1; }
    tar xzf "$tmp/uv.tar.gz" -C "$tmp" || { rm -rf "$tmp"; return 1; }
    source_dir="$tmp/uv-${platform}"
    install -m 0755 "$source_dir/uv" "$HOME/.local/bin/uv"
    install -m 0755 "$source_dir/uvx" "$HOME/.local/bin/uvx"
    rm -rf "$tmp"
    [[ "$("$HOME/.local/bin/uv" --version)" == "uv $version"* ]]
}

ensure_uv() {
    export PATH="$HOME/.local/bin:$PATH"
    install_uv
    export PATH="$HOME/.local/bin:$PATH"
}

install_verified_uv_tool() {
    local url="$1" sha256="$2" tmp wheel
    tmp=$(mktemp -d)
    wheel="$tmp/${url##*/}"
    download_verified "$url" "$sha256" "$wheel" \
        || { rm -rf "$tmp"; return 1; }
    uv tool install --force "$wheel" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
}

install_tar_binary() {
    local name="$1" url="$2" sha256="$3"
    local tmp
    tmp=$(mktemp -d)
    download_verified "$url" "$sha256" "$tmp/archive.tar.gz" \
        || { rm -rf "$tmp"; return 1; }
    tar -xzf "$tmp/archive.tar.gz" -C "$tmp" || { rm -rf "$tmp"; return 1; }
    [ -x "$tmp/$name" ] || {
        echo "error: verified archive does not contain $name" >&2
        rm -rf "$tmp"
        return 1
    }
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$tmp/$name" "$HOME/.local/bin/$name"
    rm -rf "$tmp"
}

install_precommit() {
    ensure_uv
    install_verified_uv_tool \
        'https://files.pythonhosted.org/packages/80/6e/4b28b62ecb6aae56769c34a8ff1d661473ec1e9519e2d5f8b2c150086b26/pre_commit-4.6.0-py2.py3-none-any.whl' \
        'e2cf246f7299edcabcf15f9b0571fdce06058527f0a06535068a86d38089f29b'
    install_verified_uv_tool \
        'https://files.pythonhosted.org/packages/4e/5e/4f5fe4b89fde1dc3ed0eb51bd4ce4c0bca406246673d370ea2ad0c58d747/detect_secrets-1.5.0-py3-none-any.whl' \
        'e24e7b9b5a35048c313e983f76c4bd09dad89f045ff059e354f9943bf45aa060'

    local os arch gitleaks_platform gitleaks_sha256 trufflehog_platform trufflehog_sha256
    os=$(uname -s)
    arch=$(uname -m)
    if [ "$os" != Linux ]; then
        echo "error: precommit binary install currently supports Linux only, got $os" >&2
        return 1
    fi
    case "$arch" in
        x86_64|amd64)
            gitleaks_platform=linux_x64
            gitleaks_sha256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
            trufflehog_platform=linux_amd64
            trufflehog_sha256="1b62ea3cbc672ed5fd36e0eebb00b1fb50bbb7ee35090f42437a5852a299e16b"
            ;;
        aarch64|arm64)
            gitleaks_platform=linux_arm64
            gitleaks_sha256="e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080"
            trufflehog_platform=linux_arm64
            trufflehog_sha256="e0d8722485bf592f9ef9a72009fb5184656cfab4864fed453bbbf694d5b9350b"
            ;;
        *)
            echo "error: unsupported architecture for precommit tools: $arch" >&2
            return 1
            ;;
    esac

    local gitleaks_version=8.30.1
    local trufflehog_version=3.95.6
    install_tar_binary \
        gitleaks \
        "https://github.com/gitleaks/gitleaks/releases/download/v${gitleaks_version}/gitleaks_${gitleaks_version}_${gitleaks_platform}.tar.gz" \
        "$gitleaks_sha256"
    install_tar_binary \
        trufflehog \
        "https://github.com/trufflesecurity/trufflehog/releases/download/v${trufflehog_version}/trufflehog_${trufflehog_version}_${trufflehog_platform}.tar.gz" \
        "$trufflehog_sha256"
}

config_precommit() {
    export PATH="$HOME/.local/bin:$PATH"
    if [ -f "$SCRIPT_DIR/.pre-commit-config.yaml" ] && command -v pre-commit >/dev/null 2>&1; then
        (cd "$SCRIPT_DIR" && pre-commit install)
    else
        echo "    (skipping pre-commit install: config or pre-commit not found)" >&2
    fi
}

install_hf() {
    ensure_uv
    install_verified_uv_tool \
        'https://files.pythonhosted.org/packages/f1/ce/13b2ba57838b8db1e6bd033c1b21ce0b9f6153b87d4e4939f77074e41eb0/huggingface_hub-1.23.0-py3-none-any.whl' \
        'b1d604788f5adc7f0eb246e03e0ec19011ca06e38400218c347dccc3dffa64a2'
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
                         Default: all default components (opt-in ones excluded).
  --list-components      Print available components and exit.
  -h, --help             Show this help.

--config-only and --install-only are mutually exclusive.
--components is independent: it narrows which components run, in either mode.

Default components:
  ${DEFAULT_COMPONENTS[*]}
Opt-in components (run only when named with --components):
  ${OPT_IN_COMPONENTS[*]}
EOF
}

list_components() {
    local c optin
    declare -A optin=()
    for c in "${OPT_IN_COMPONENTS[@]}"; do optin[$c]=1; done
    for c in "${ALL_COMPONENTS[@]}"; do
        local has_install=no has_config=no tag=""
        has_fn "install_$c" && has_install=yes
        has_fn  "config_$c" && has_config=yes
        [ -n "${optin[$c]:-}" ] && tag="  (opt-in)"
        printf '  %-10s  install=%-3s  config=%-3s%s\n' "$c" "$has_install" "$has_config" "$tag"
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
        # Opt-in components (e.g. rocq) are deliberately excluded here; request
        # them explicitly with --components.
        selected=("${DEFAULT_COMPONENTS[@]}")
    else
        selected=("${COMPONENTS[@]}")
    fi
    validate_components "${selected[@]}"

    local c
    for c in "${selected[@]}"; do run_component "$c"; done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
