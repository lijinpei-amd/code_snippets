#!/usr/bin/env bash
set -euo pipefail

# write_managed_block FILE MARKER_ID COMMENT_CHAR <<'HEREDOC'
#   content
# HEREDOC
#
# If FILE contains a block delimited by
#   COMMENT_CHAR BEGIN MARKER_ID  ...  COMMENT_CHAR END MARKER_ID
# replace that range (markers inclusive) with the new content.
# Otherwise append the block at the end.
write_managed_block() {
    local file="$1" marker="$2" comment="$3"
    local content
    content="$(cat)"  # read from stdin (heredoc)

    local begin="${comment} BEGIN ${marker}"
    local end="${comment} END ${marker}"
    local block
    block="$(printf '%s\n%s\n%s' "$begin" "$content" "$end")"

    mkdir -p "$(dirname "$file")"
    if [ ! -f "$file" ]; then
        printf '%s\n' "$block" > "$file"
    elif grep -qF "$begin" "$file"; then
        local tmp
        tmp="$(mktemp)"
        awk -v b="$begin" -v e="$end" -v blk="$block" '
            $0 == b { skip=1 }
            skip && $0 == e { print blk; skip=0; next }
            !skip { print }
        ' "$file" > "$tmp"
        mv "$tmp" "$file"
    else
        printf '\n%s\n' "$block" >> "$file"
    fi
}

curl -LsSf https://hf.co/cli/install.sh | bash
sudo apt-get install -y zsh git curl python3-neovim silversearcher-ag wget tmux

sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
sed -i "s/plugins=(git)/plugins=(git vi-mode)/" ~/.zshrc

curl -LsSf https://astral.sh/uv/install.sh | sh

write_managed_block ~/.tmux.conf "setup_dev_environment" "#" <<'BLOCK'
set-option -sa terminal-overrides ",xterm*:RGB"
set -g prefix "C-t"
unbind-key "C-b"
bind-key "C-t" send-prefix
# Forward terminal focus events into tmux panes so embedded TUIs (nvim, claude)
# can react to focus changes. See ~/.config/nvim/init.lua for the nvim-side
# handling that propagates these into :terminal buffers.
set -g focus-events on
BLOCK

write_managed_block ~/.env.sh "setup_dev_environment" "#" <<BLOCK
alias vim=nvim
export PATH="$HOME/proot/nvim/bin:\$PATH"
source $HOME/.local/bin/env
BLOCK

write_managed_block ~/.zshrc "setup_dev_environment" "#" <<'BLOCK'
unsetopt BEEP
source ~/.env.sh
PROMPT="%(!.%{%F{yellow}%}.)$USER @ %{$fg[white]%}%M %{$fg[blue]%}%d"
PROMPT+=$'\n'
PROMPT+="%(?:%{$fg_bold[green]%}%1{➜%} :%{$fg_bold[red]%}%1{➜%} ) %{$reset_color%}"
PROMPT+='$(git_prompt_info)'
ZSH_THEME_GIT_PROMPT_PREFIX="%{$fg_bold[blue]%}(%{$fg[red]%}"
BLOCK

write_managed_block ~/.bashrc "setup_dev_environment" "#" <<'BLOCK'
source ~/.env.sh
BLOCK

write_managed_block ~/.inputrc "setup_dev_environment" "#" <<'BLOCK'
set bell-style none
BLOCK

sh -c 'curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/autoload/plug.vim --create-dirs \
       https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'

mkdir -p ~/.config/nvim/
write_managed_block ~/.config/nvim/init.lua "setup_dev_environment" "--" <<'BLOCK'
if vim.g.neovide then
        vim.g.neovide_cursor_animation_length = 0
end
vim.opt.number = true
vim.opt.termguicolors = true
vim.cmd.syntax("on")
vim.opt.background = "dark"
vim.opt.hlsearch = true
vim.opt.expandtab = true
vim.opt.switchbuf = { "useopen", "usetab", "newtab" }
vim.fn['plug#begin']()
vim.fn['plug#']('lifepillar/vim-solarized8', { branch = 'neovim' })
vim.fn['plug#']('overcache/NeoSolarized')
vim.fn['plug#']('tomasr/molokai')
vim.fn['plug#']('dracula/vim')
vim.fn['plug#']('mhartington/oceanic-next')
vim.fn['plug#']('mileszs/ack.vim')
vim.fn['plug#']('mhinz/vim-grepper')
vim.fn['plug#']('vim-airline/vim-airline')
vim.fn['plug#']('vim-airline/vim-airline-themes')
vim.fn['plug#']('powerman/vim-plugin-ansiesc')
vim.fn['plug#end']()
vim.cmd.colorscheme("solarized8")

-- C/C++: 2-space indent with cindent
vim.api.nvim_create_autocmd("FileType", {
	pattern = { "c", "cpp" },
	callback = function()
		vim.opt_local.cindent = true
		vim.opt_local.shiftwidth = 2
		vim.opt_local.tabstop = 2
		vim.opt_local.softtabstop = 2
	end,
})

-- Python: 4-space indent
vim.api.nvim_create_autocmd("FileType", {
	pattern = "python",
	callback = function()
		vim.opt_local.shiftwidth = 4
		vim.opt_local.tabstop = 4
		vim.opt_local.softtabstop = 4
	end,
})

-- Lua: 4-space indent
vim.api.nvim_create_autocmd("FileType", {
	pattern = "lua",
	callback = function()
		vim.opt_local.shiftwidth = 4
		vim.opt_local.tabstop = 4
		vim.opt_local.softtabstop = 4
	end,
})

vim.lsp.config('clangd', {
	cmd = { 'clangd-22' },
	filetypes = { 'c', 'cpp', 'objc', 'objcpp', 'cuda' },
})
vim.lsp.enable('clangd')

-- Show LSP diagnostics
vim.diagnostic.config({
	virtual_text = true,
	signs = true,
	underline = true,
	update_in_insert = false,
	float = { border = "rounded", source = true },
})

-- Keymaps for navigating diagnostics
vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, { desc = "Previous diagnostic" })
vim.keymap.set('n', ']d', vim.diagnostic.goto_next, { desc = "Next diagnostic" })
vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, { desc = "Show diagnostic float" })
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = "Diagnostics to loclist" })

-- Forward focus events into :terminal buffers (e.g. Claude Code), combining
-- nvim's own FocusGained/FocusLost with the buffer/window the user is viewing.
-- Requires the outer terminal to emit focus reporting and, in tmux,
-- `set -g focus-events on`. Without those, nvim never sees focus transitions
-- and embedded programs will believe nvim is permanently focused.
do
	local nvim_focused = true
	local last_sent = {}
	local FOCUS_IN, FOCUS_OUT = "\27[I", "\27[O"

	local function sync(bufnr)
		if not vim.api.nvim_buf_is_valid(bufnr) then return end
		if vim.bo[bufnr].buftype ~= "terminal" then return end
		local chan = vim.bo[bufnr].channel
		if not chan or chan == 0 then return end

		local want = nvim_focused and vim.api.nvim_get_current_buf() == bufnr
		if last_sent[bufnr] == want then return end

		local ok = pcall(vim.api.nvim_chan_send, chan, want and FOCUS_IN or FOCUS_OUT)
		if ok then last_sent[bufnr] = want end
	end

	local function sync_all()
		for _, b in ipairs(vim.api.nvim_list_bufs()) do sync(b) end
	end

	local group = vim.api.nvim_create_augroup("claude_focus_forward", { clear = true })

	vim.api.nvim_create_autocmd("FocusGained", {
		group = group,
		callback = function() nvim_focused = true; sync_all() end,
	})
	vim.api.nvim_create_autocmd("FocusLost", {
		group = group,
		callback = function() nvim_focused = false; sync_all() end,
	})
	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
		group = group,
		callback = sync_all,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(args) last_sent[args.buf] = nil end,
	})
end

-- Emacs-style switch-to-buffer (C-x b).
local function emacs_default_buffer()
	local cur = vim.api.nvim_get_current_buf()
	local shown = {}
	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
			shown[vim.api.nvim_win_get_buf(win)] = true
		end
	end
	local infos = vim.fn.getbufinfo({ buflisted = 1 })
	table.sort(infos, function(a, b) return a.lastused > b.lastused end)
	for _, info in ipairs(infos) do
		if info.bufnr ~= cur and not shown[info.bufnr] then
			return info.bufnr
		end
	end
	return -1
end

local function find_buffer_by_name(name)
	for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
		local bn = vim.fn.bufname(info.bufnr)
		if bn == name or vim.fn.fnamemodify(bn, ":t") == name then
			return info.bufnr
		end
	end
	return -1
end

local function switch_to_buffer()
	local default_buf = emacs_default_buffer()
	local default_label
	if default_buf > 0 then
		local name = vim.fn.bufname(default_buf)
		default_label = (name ~= "" and vim.fn.fnamemodify(name, ":t")) or ("[No Name " .. default_buf .. "]")
	end
	local prompt = default_label
		and string.format("Switch to buffer (default %s): ", default_label)
		or "Switch to buffer: "
	local sentinel = "\0"
	local ok, input = pcall(vim.fn.input, {
		prompt = prompt,
		completion = "buffer",
		cancelreturn = sentinel,
	})
	if not ok or input == sentinel then return end
	if input == "" then
		if default_buf > 0 then vim.cmd("buffer " .. default_buf) end
		return
	end
	local target = find_buffer_by_name(input)
	if target > 0 then
		vim.cmd("buffer " .. target)
		return
	end
	local choice = vim.fn.confirm(
		string.format("[Confirm] Buffer '%s' does not exist. Create?", input),
		"&Yes\n&No", 1)
	if choice ~= 1 then return end
	vim.cmd("edit " .. vim.fn.fnameescape(input))
end
vim.keymap.set('n', '<leader>b', switch_to_buffer, { desc = "Emacs-style switch-to-buffer" })
BLOCK
nvim -c PlugUpgrade -c qall
nvim -c PlugInstall -c qall
git config --global user.name "Li Jinpei"
git config --global user.email "jinpli@amd.com"
sudo chsh -s "$(which zsh)" "$(id -un)"

# install llvm
wget -qO- https://apt.llvm.org/llvm.sh | sudo bash -s -- 21

wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install node
npm install -g @anthropic-ai/claude-code
npm install -g @openai/codex

mkdir -p ~/.codex
write_managed_block ~/.codex/config.toml "setup_dev_environment" "#" <<'BLOCK'
model_provider = "amd_llm"
[model_providers.amd_llm]
name = "amd_llm"
base_url = "https://llm-api.amd.com/OpenAI/"
env_http_headers = {
  "Ocp-Apim-Subscription-Key"="LLM_GATEWAY_KEY",
}
BLOCK

(type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
	&& sudo mkdir -p -m 755 /etc/apt/keyrings \
	&& out=$(mktemp) && wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg \
	&& cat "$out" | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
	&& sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& sudo mkdir -p -m 755 /etc/apt/sources.list.d \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
	&& sudo apt update \
	&& sudo apt install gh -y
