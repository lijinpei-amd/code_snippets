# syntax=docker/dockerfile:1
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV TERM=xterm-256color
ENV HOME=/root

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

WORKDIR /work/code_snippets
COPY setup_dev_environment.sh build_stow.sh .pre-commit-config.yaml .secrets.baseline ./
COPY dotfiles ./dotfiles

RUN set -eux; \
    test ! -e .git; \
    if command -v apt-get >/dev/null 2>&1; then \
        apt-get update; \
        apt-get install -y --no-install-recommends ca-certificates git; \
    elif command -v pacman >/dev/null 2>&1; then \
        pacman -Sy --needed --noconfirm ca-certificates git; \
    else \
        echo 'unsupported base image: git cannot be installed' >&2; \
        exit 1; \
    fi; \
    git init --quiet; \
    printf '%s\n' '# pre-existing zsh configuration' 'export SETUP_TEST_ZSHRC_PRESERVED=1' > "$HOME/.zshrc"; \
    printf '%s\n' '# pre-existing zsh environment' 'export SETUP_TEST_ZSHENV_PRESERVED=1' > "$HOME/.zshenv"

RUN bash ./setup_dev_environment.sh

RUN set -eux; \
    export PATH="$HOME/.local/bin:$HOME/proot/stow/bin:$HOME/proot/nvim/bin:$PATH"; \
    if [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh"; fi; \
    git status --short >/dev/null; \
    test "$(git rev-list --all --count)" -eq 0; \
    "$HOME/proot/stow/bin/stow" --version | grep -q '2.4.1'; \
    command -v zsh; \
    command -v git; \
    command -v curl; \
    command -v ag; \
    command -v wget; \
    command -v tmux; \
    command -v jq; \
    command -v cmake; \
    command -v ninja; \
    command -v nvim; \
    test "$(nvim --version | sed -n '1p')" = 'NVIM v0.11.7'; \
    command -v fzf; \
    command -v ccache; \
    command -v gdb; \
    command -v make; \
    command -v perl; \
    command -v clang; \
    command -v clang++; \
    command -v gh; \
    command -v uv; \
    command -v uvx; \
    command -v pre-commit; \
    command -v detect-secrets; \
    command -v gitleaks; \
    command -v trufflehog; \
    command -v node; \
    command -v npm; \
    command -v claude; \
    command -v codex; \
    { command -v hf || command -v huggingface-cli; }; \
    if command -v python3 >/dev/null 2>&1; then \
        python3 -c 'import pynvim'; \
    else \
        python -c 'import pynvim'; \
    fi; \
    test -d "$HOME/.oh-my-zsh"; \
    grep -qx 'export SETUP_TEST_ZSHRC_PRESERVED=1' "$HOME/.zshrc"; \
    grep -qx 'export SETUP_TEST_ZSHENV_PRESERVED=1' "$HOME/.zshenv"; \
    grep -Eq '^[[:space:]]*(source|\.)[[:space:]].*\.zshrc_stow' "$HOME/.zshrc"; \
    grep -Eq '^[[:space:]]*(source|\.)[[:space:]].*oh-my-zsh\.sh' "$HOME/.zshrc"; \
    grep -Eq '^[[:space:]]*(source|\.)[[:space:]].*\.zshenv_stow' "$HOME/.zshenv"; \
    env -i HOME="$HOME" TERM="$TERM" PATH=/usr/bin:/bin zsh -ic \
        'typeset -f git_prompt_info >/dev/null'; \
    env -i HOME="$HOME" TERM="$TERM" PATH=/usr/bin:/bin zsh -c ' \
        command -v uv >/dev/null && \
        command -v node >/dev/null && \
        command -v nvim >/dev/null && \
        case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) exit 1 ;; esac && \
        case ":$PATH:" in *":$HOME/proot/stow/bin:"*) ;; *) exit 1 ;; esac && \
        case ":$PATH:" in *":$HOME/proot/nvim/bin:"*) ;; *) exit 1 ;; esac'; \
    nvim --headless -u "$HOME/.config/nvim/init.lua" \
        -c 'lua assert(vim.v.errmsg == "", vim.v.errmsg)' -c qall; \
    test -d "$HOME/.tmux/plugins/tpm"; \
    test -f "$HOME/.local/share/nvim/site/autoload/plug.vim"; \
    test -L "$HOME/.zshenv_stow"; \
    test -L "$HOME/.zshrc_stow"; \
    test -L "$HOME/.bashrc_stow"; \
    test -L "$HOME/.tmux.conf"; \
    test -L "$HOME/.config/nvim/init.lua"; \
    test -L "$HOME/.gitignore"; \
    test -L "$HOME/.config/ccache/ccache.conf"; \
    test -L "$HOME/.config/gdb/gdbinit"; \
    test -L "$HOME/.codex/config.toml"; \
    test -f .git/hooks/pre-commit
