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
    elif grep -qF -- "$begin" "$file"; then
        local tmp
        tmp="$(mktemp)"
        # Pass block via ENVIRON: awk -v interprets backslash escapes (\n, \t, \\),
        # which corrupts code containing those sequences.
        WMB_BLOCK="$block" awk -v b="$begin" -v e="$end" '
            $0 == b { skip=1 }
            skip && $0 == e { print ENVIRON["WMB_BLOCK"]; skip=0; next }
            !skip { print }
        ' "$file" > "$tmp"
        mv "$tmp" "$file"
    else
        printf '\n%s\n' "$block" >> "$file"
    fi
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
    pkg_install zsh git curl python3-neovim silversearcher-ag wget tmux jq ccache
}

install_zsh() {
    if [ -d "${ZSH:-$HOME/.oh-my-zsh}" ]; then
        echo "oh-my-zsh already installed, skipping"
        return 0
    fi
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
}

config_zsh() {
    if [ -f ~/.zshrc ]; then
        sed -i "s/plugins=(git)/plugins=(git vi-mode)/" ~/.zshrc
    fi
    write_managed_block ~/.zshrc "setup_dev_environment" "#" <<'BLOCK'
unsetopt BEEP
source $HOME/.env.sh
PROMPT="%(!.%{%F{yellow}%}.)$USER @ %{$fg[white]%}%M %{$fg[blue]%}%d"
PROMPT+=$'\n'
PROMPT+="%(?:%{$fg_bold[green]%}%1{➜%} :%{$fg_bold[red]%}%1{➜%} ) %{$reset_color%}"
PROMPT+='$(git_prompt_info)'
ZSH_THEME_GIT_PROMPT_PREFIX="%{$fg_bold[blue]%}(%{$fg[red]%}"
BLOCK
    sudo usermod -s "$(which zsh)" "$(id -un)"
}

config_env() {
    write_managed_block ~/.env.sh "setup_dev_environment" "#" <<BLOCK
alias vim=nvim
export PATH="$HOME/proot/nvim/bin:\$PATH"
source $HOME/.local/bin/env
export NVM_DIR="\$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
BLOCK
}

config_bash() {
    write_managed_block ~/.bashrc "setup_dev_environment" "#" <<'BLOCK'
source $HOME/.env.sh
BLOCK
}

config_inputrc() {
    write_managed_block ~/.inputrc "setup_dev_environment" "#" <<'BLOCK'
set bell-style none
BLOCK
}

config_tmux() {
    write_managed_block ~/.tmux.conf "setup_dev_environment" "#" <<'BLOCK'
set -g default-terminal "screen-256color"
set-option -sa terminal-overrides ",xterm*:Tc"
set -g prefix "C-t"
unbind-key "C-b"
bind-key "C-t" send-prefix
# Forward terminal focus events into tmux panes so embedded TUIs (nvim, claude)
# can react to focus changes. See ~/.config/nvim/init.lua for the nvim-side
# handling that propagates these into :terminal buffers.
set -g focus-events on
set-window-option -g mode-keys vi
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'christoomey/vim-tmux-navigator'
# Must be the last line: bootstraps tpm and the @plugin entries above.
run '~/.tmux/plugins/tpm/tpm'
BLOCK
}

install_nvim() {
    sh -c 'curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/autoload/plug.vim --create-dirs \
       https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
}

config_nvim() {
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
vim.opt.virtualedit = { "all", "onemore" }

vim.api.nvim_create_user_command("Ninja", function(opts)
	local saved = vim.o.makeprg
	vim.o.makeprg = "ninja"
	local ok, err = pcall(vim.cmd, "make " .. opts.args)
	vim.o.makeprg = saved
	if not ok then error(err) end
end, { nargs = "*" })

vim.fn['plug#begin']()
vim.fn['plug#']('lifepillar/vim-solarized8', { branch = 'neovim' })
vim.fn['plug#']('overcache/NeoSolarized')
vim.fn['plug#']('tomasr/molokai')
vim.fn['plug#']('dracula/vim')
vim.fn['plug#']('mhartington/oceanic-next')
vim.fn['plug#']('morhetz/gruvbox')
vim.fn['plug#']('sainnhe/sonokai')
vim.fn['plug#']('sainnhe/everforest')
vim.fn['plug#']('catppuccin/nvim')
vim.fn['plug#']('cocopon/iceberg.vim')
vim.fn['plug#']('rakr/vim-one')
vim.fn['plug#']('sonph/onehalf')
vim.fn['plug#']('lewis6991/moonlight.vim')
vim.fn['plug#']('folke/tokyonight.nvim')
vim.fn['plug#']('savq/melange-nvim')
vim.fn['plug#']('mileszs/ack.vim')
vim.fn['plug#']('mhinz/vim-grepper')
vim.fn['plug#']('vim-airline/vim-airline')
vim.fn['plug#']('vim-airline/vim-airline-themes')
vim.fn['plug#']('powerman/vim-plugin-ansiesc')
vim.fn['plug#']('nvim-tree/nvim-web-devicons')
vim.fn['plug#']('preservim/nerdtree')
vim.fn['plug#']('tiagofumo/vim-nerdtree-syntax-highlight')
vim.fn['plug#']('sindrets/diffview.nvim')
vim.fn['plug#']('preservim/tagbar')
vim.fn['plug#']('christoomey/vim-tmux-navigator')
vim.fn['plug#']('preservim/vimux')
vim.fn['plug#']('sakhnik/nvim-gdb', { ['do'] = ':!./install.sh' })
vim.fn['plug#']('rust-lang/rust.vim')
vim.fn['plug#']('vim-autoformat/vim-autoformat')
vim.fn['plug#']('nvim-lua/plenary.nvim')
vim.fn['plug#']('junegunn/fzf', { ['do'] = './install --bin' })
vim.fn['plug#']('junegunn/fzf.vim')
vim.fn['plug#end']()
vim.cmd.colorscheme("NeoSolarized")

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

local clang_format_py = '/usr/share/clang/clang-format.py'
vim.keymap.set('v', '<C-K>', ':py3f ' .. clang_format_py .. '<cr>')
vim.keymap.set('i', '<C-K>', '<c-o>:py3f ' .. clang_format_py .. '<cr>')

-- Pick the highest-numbered clangd-N on PATH, falling back to plain `clangd`.
-- Works on Arch's unversioned binary and on Ubuntu/Debian where apt.llvm.org
-- installs versioned suffixes.
local function pick_clangd()
	for v = 40, 15, -1 do
		local cand = 'clangd-' .. v
		if vim.fn.executable(cand) == 1 then return cand end
	end
	if vim.fn.executable('clangd') == 1 then return 'clangd' end
	return nil
end

local clangd_cmd = pick_clangd()
if clangd_cmd then
	vim.lsp.config('clangd', {
		cmd = { clangd_cmd },
		filetypes = { 'c', 'cpp', 'objc', 'objcpp', 'cuda' },
	})
	vim.lsp.enable('clangd')
end

-- Show LSP diagnostics
vim.diagnostic.config({
	virtual_text = true,
	signs = true,
	underline = true,
	update_in_insert = false,
	float = { border = "rounded", source = true, max_width = 80, max_height = 20 },
})

-- Keymaps for navigating diagnostics
vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, { desc = "Previous diagnostic" })
vim.keymap.set('n', ']d', vim.diagnostic.goto_next, { desc = "Next diagnostic" })
vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, { desc = "Show diagnostic float" })
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = "Diagnostics to loclist" })

vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)

    if client:supports_method('textDocument/inlayHint') then
      vim.lsp.inlay_hint.enable(true, { bufnr = args.buf })
    end

    if client:supports_method('textDocument/completion') then
      vim.lsp.completion.enable(true, client.id, args.buf)
    end

    local lsp_keymaps = {
      { 'gd', vim.lsp.buf.definition,      "Goto definition" },
      { 'gr', vim.lsp.buf.references,      "References" },
      { 'gi', vim.lsp.buf.implementation,  "Goto implementation" },
      { 'gO', vim.lsp.buf.document_symbol, "Document symbols" },
    }
    for _, m in ipairs(lsp_keymaps) do
      vim.keymap.set('n', m[1], m[2], { buffer = args.buf, desc = m[3] })
    end
  end
})

-- <C-\>n as a shorthand for the built-in <C-\><C-n> (exit terminal mode)
vim.keymap.set('t', [[<C-\>n]], [[<C-\><C-n>]], { desc = "Exit terminal mode" })

-- Window/tab navigation from normal, insert, and terminal modes.
-- <C-\><suffix> lands in normal mode at the destination;
-- <C-\>i<suffix> additionally enters insert/terminal mode at the destination.
local nav_targets = {
  { 'h',  [[<C-w>h]],            "window left" },
  { 'j',  [[<C-w>j]],            "window down" },
  { 'k',  [[<C-w>k]],            "window up" },
  { 'l',  [[<C-w>l]],            "window right" },
  { 'w',  [[<C-w>w]],            "next window" },
  { 'p',  [[<C-w>p]],            "previous window" },
}
local nav_modes = {
  { 'n', '' },              -- normal: already in normal mode
  { 'i', [[<C-\><C-n>]] },  -- insert: leave insert first
  { 't', [[<C-\><C-n>]] },  -- terminal: leave terminal mode first
}
for _, mode in ipairs(nav_modes) do
  local m, escape = mode[1], mode[2]
  for _, t in ipairs(nav_targets) do
    local suffix, action, label = t[1], t[2], t[3]
    vim.keymap.set(m, [[<C-\>]] .. suffix,  escape .. action,
      { desc = "Goto " .. label })
    vim.keymap.set(m, [[<C-\>i]] .. suffix, escape .. action .. [[<Cmd>startinsert<CR>]],
      { desc = "Goto " .. label .. " + insert" })
  end
end

-- <C-\>{count}gt/gT in any mode: map digits and g individually so Vim's native count+gt machinery picks up after the prefix is translated away.
for _, mode in ipairs(nav_modes) do
  local m, escape = mode[1], mode[2]
  vim.keymap.set(m, [[<C-\>g]], escape .. 'g',
    { desc = "Tab navigate (gt/gT)" })
  for d = 1, 9 do
    vim.keymap.set(m, [[<C-\>]] .. d, escape .. d,
      { desc = "Start tab-nav count " .. d })
  end
end

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

	local candidates = {}
	for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
		local full = info.name or ""
		local short = (full ~= "" and vim.fn.fnamemodify(full, ":t"))
			or ("[No Name " .. info.bufnr .. "]")
		local has_full = full ~= "" and full ~= short
		table.insert(candidates, {
			bufnr = info.bufnr,
			short = short,
			full = full,
			short_lower = short:lower(),
			full_lower = has_full and full:lower() or nil,
			label = has_full and (short .. "  " .. full) or short,
			lastused = info.lastused or 0,
		})
	end
	table.sort(candidates, function(a, b) return a.lastused > b.lastused end)

	local function fuzzy_score(text, t_match, q)
		local tlen, qlen = #t_match, #q
		if qlen > tlen then return nil end
		local score, last, consec, first = 0, 0, 0, nil
		local ti = 1
		for qi = 1, qlen do
			local qc = q:sub(qi, qi)
			local pos
			while ti <= tlen do
				if t_match:sub(ti, ti) == qc then pos = ti; ti = ti + 1; break end
				ti = ti + 1
			end
			if not pos then return nil end
			if not first then first = pos end
			if pos == 1 then
				score = score + 12
			else
				local pc = text:sub(pos - 1, pos - 1)
				if pc == "/" or pc == "_" or pc == "-" or pc == "." or pc == " " then
					score = score + 10
				elseif pc:match("%l") and text:sub(pos, pos):match("%u") then
					score = score + 8
				end
			end
			if pos == last + 1 then
				consec = consec + 1
				score = score + 5 + consec
			else
				consec = 0
				if last > 0 then score = score - (pos - last - 1) end
			end
			last = pos
		end
		return score - tlen * 0.05 - (first - 1) * 0.5
	end

	local function filter(q)
		if q == "" then return candidates end
		local cs = q:match("%u") ~= nil
		local qm = cs and q or q:lower()
		local scored = {}
		for _, c in ipairs(candidates) do
			local s_short = fuzzy_score(c.short, cs and c.short or c.short_lower, qm)
			local s_full
			if c.full_lower then
				s_full = fuzzy_score(c.full, cs and c.full or c.full_lower, qm)
			end
			local best = s_short
			if s_full and (not best or s_full > best) then best = s_full end
			if best then table.insert(scored, { c = c, score = best }) end
		end
		table.sort(scored, function(a, b)
			if a.score ~= b.score then return a.score > b.score end
			return a.c.lastused > b.c.lastused
		end)
		local out = {}
		for _, e in ipairs(scored) do table.insert(out, e.c) end
		return out
	end

	local buf = vim.api.nvim_create_buf(false, true)
	local width = math.min(vim.o.columns - 4, math.max(50, math.floor(vim.o.columns * 0.6)))
	local height = math.min(12, math.max(5, #candidates + 1))
	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		row = math.max(1, math.floor((vim.o.lines - height) / 2)),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
	})
	local ns = vim.api.nvim_create_namespace("switch_to_buffer")

	local query = ""
	local selected = 1
	local view_start = 1
	local matches = {}

	local function render()
		matches = filter(query)
		if #matches == 0 then
			selected = 0
		else
			if selected < 1 then selected = 1 end
			if selected > #matches then selected = #matches end
		end
		local list_h = height - 1
		if selected > 0 then
			if selected < view_start then view_start = selected end
			if selected >= view_start + list_h then view_start = selected - list_h + 1 end
		else
			view_start = 1
		end

		local lines = { prompt .. query }
		local last = math.min(#matches, view_start + list_h - 1)
		for i = view_start, last do
			table.insert(lines, "  " .. matches[i].label)
		end
		if #matches == 0 and query ~= "" then
			table.insert(lines, "  (no match — <CR> creates '" .. query .. "')")
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		vim.api.nvim_buf_add_highlight(buf, ns, "Question", 0, 0, #prompt)
		if selected > 0 then
			local lnum = (selected - view_start) + 1
			vim.api.nvim_buf_add_highlight(buf, ns, "PmenuSel", lnum, 0, -1)
		end
	end

	local function cleanup()
		if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
		if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
	end

	render()
	vim.cmd("redraw")

	while true do
		local ok, raw = pcall(vim.fn.getcharstr)
		if not ok then cleanup() return end
		local key = vim.fn.keytrans(raw)
		local dirty = false
		if key == "<Esc>" or key == "<C-c>" or key == "<C-g>" then
			cleanup()
			return
		elseif key == "<CR>" or key == "<NL>" or key == "<kEnter>" then
			cleanup()
			if #matches > 0 and selected > 0 then
				vim.cmd("buffer " .. matches[selected].bufnr)
			elseif query == "" and default_buf > 0 then
				vim.cmd("buffer " .. default_buf)
			elseif query ~= "" then
				local choice = vim.fn.confirm(
					string.format("[Confirm] Buffer '%s' does not exist. Create?", query),
					"&Yes\n&No", 1)
				if choice == 1 then vim.cmd("edit " .. vim.fn.fnameescape(query)) end
			end
			return
		elseif key == "<Down>" or key == "<C-n>" or key == "<Tab>" then
			selected = selected + 1
			dirty = true
		elseif key == "<Up>" or key == "<C-p>" or key == "<S-Tab>" then
			selected = selected - 1
			dirty = true
		elseif key == "<BS>" or key == "<C-h>" then
			if #query > 0 then
				query = query:sub(1, -2)
				selected = 1
				dirty = true
			end
		elseif key == "<C-u>" then
			if #query > 0 then
				query = ""
				selected = 1
				dirty = true
			end
		elseif key == "<C-w>" then
			local trimmed = (query:gsub("%S+%s*$", ""))
			if trimmed ~= query then
				query = trimmed
				selected = 1
				dirty = true
			end
		elseif #raw >= 1 and not raw:match("^%c") then
			query = query .. raw
			selected = 1
			dirty = true
		end
		if dirty then
			render()
			vim.cmd("redraw")
		end
	end
end
vim.keymap.set('n', '<leader>b', vim.cmd.Buffers, { desc = "fzf buffer picker" })
BLOCK
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
    write_managed_block ~/.gitignore "setup_dev_environment" "#" <<'BLOCK'
.ccls-cache/
.claude/
.codex
BLOCK
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

config_codex() {
    mkdir -p ~/.codex
    write_managed_block ~/.codex/config.toml "setup_dev_environment" "#" <<'BLOCK'
model_provider = "amd_llm"
personality = "pragmatic"
[model_providers.amd_llm]
name = "amd_llm"
base_url = "https://llm-api.amd.com/OpenAI/"
env_http_headers = {
  "Ocp-Apim-Subscription-Key"="LLM_GATEWAY_KEY",
}
BLOCK
}

config_claude() {
    json_patch ~/.claude.json '.hasCompletedOnboarding = true'
    local headers="Ocp-Apim-Subscription-Key: ${LLM_GATEWAY_KEY}
user: ${USER}"
    json_patch ~/.claude/settings.json --arg headers "$headers" '. * {
      "env": {
        "ANTHROPIC_BASE_URL": "https://llm-api.amd.com/Anthropic",
        "ANTHROPIC_API_KEY": "dummy",
        "ANTHROPIC_CUSTOM_HEADERS": $headers,
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "ANTHROPIC_MODEL": "opus",
        "CLAUDE_CODE_EFFORT_LEVEL": "max"
      },
      "theme": "auto",
      "skipDangerousModePermissionPrompt": true
    }'
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
