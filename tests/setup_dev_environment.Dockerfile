# syntax=docker/dockerfile:1
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV TERM=xterm-256color
ENV HOME=/root

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

WORKDIR /work/code_snippets
COPY . /work/code_snippets

RUN set -eux; \
    test -d .git

RUN bash ./setup_dev_environment.sh

RUN set -eux; \
    export PATH="$HOME/.local/bin:$HOME/proot/stow/bin:$PATH"; \
    if [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh"; fi; \
    git status --short >/dev/null; \
    "$HOME/proot/stow/bin/stow" --version | grep -q '2.4.1'; \
    command -v zsh; \
    command -v git; \
    command -v curl; \
    command -v ag; \
    command -v wget; \
    command -v tmux; \
    command -v jq; \
    command -v ccache; \
    command -v gdb; \
    command -v make; \
    command -v perl; \
    command -v clang; \
    command -v clang++; \
    command -v gh; \
    command -v uv; \
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
    test -L "$HOME/.claude/settings.json"; \
    test -f .git/hooks/pre-commit
