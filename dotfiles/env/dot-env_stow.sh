alias vim=nvim

# Prepend to PATH only if not already present, so this layer (sourced on every
# shell, including nested ones) doesn't accumulate duplicate entries.
path_prepend() {
    case ":$PATH:" in
        *":$1:"*) ;;
        *) PATH="$1:$PATH" ;;
    esac
}
path_prepend "$HOME/proot/nvim/bin"
path_prepend "$HOME/proot/stow/bin"
export PATH
source "$HOME/.local/bin/env"
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
