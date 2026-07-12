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
vim.fn['plug#']('lifepillar/vim-solarized8', { branch = 'neovim', commit = '1d05915cc9050ce1a8a6b94d8c2e48ead197c756' })
vim.fn['plug#']('overcache/NeoSolarized', { commit = 'b94b1a9ad51e2de015266f10fdc6e142f97bd617' })
vim.fn['plug#']('tomasr/molokai', { commit = 'c67bdfcdb31415aa0ade7f8c003261700a885476' })
vim.fn['plug#']('dracula/vim', { commit = '4f068752154e70ef8e03d6a70992033fff20a165' })
vim.fn['plug#']('mhartington/oceanic-next', { commit = '09833f72d5ba23de2e8bcae18f479f326f5f677a' })
vim.fn['plug#']('morhetz/gruvbox', { commit = '5d15b2765f59754d7ac263c88a0f6e3e58124951' })
vim.fn['plug#']('sainnhe/sonokai', { commit = 'b023c5280b16fe2366f5e779d8d2756b3e5ee9c3' })
vim.fn['plug#']('sainnhe/everforest', { commit = '85a86eb62409e3ec88713bff3d1b9d7374e112e4' })
vim.fn['plug#']('catppuccin/nvim', { commit = '05e8787020dcfdb937bf2ff23855ea2415b4e072' })
vim.fn['plug#']('cocopon/iceberg.vim', { commit = '23835d5ed696436f716cbfdb56a93a7850fe3b18' })
vim.fn['plug#']('rakr/vim-one', { commit = '187f5c85b682c1933f8780d4d419c55d26a82e24' })
vim.fn['plug#']('sonph/onehalf', { commit = '75eb2e97acd74660779fed8380989ee7891eec56' })
vim.fn['plug#']('lewis6991/moonlight.vim', { commit = '4f066e8742159c0ffed1550bd9d3dec854323f3e' })
vim.fn['plug#']('folke/tokyonight.nvim', { commit = 'cdc07ac78467a233fd62c493de29a17e0cf2b2b6' })
vim.fn['plug#']('savq/melange-nvim', { commit = 'ce42f6b629beeaa00591ba73a77d3eeac4cf28ce' })
vim.fn['plug#']('mileszs/ack.vim', { commit = '36e40f9ec91bdbf6f1adf408522a73a6925c3042' })
vim.fn['plug#']('mhinz/vim-grepper', { commit = 'acaaf32edaa11d82fb972d2af36b949ec3042928' })
vim.fn['plug#']('vim-airline/vim-airline', { commit = '9e0beefd6e28c92d876559f07d8595f454c08cb7' })
vim.fn['plug#']('vim-airline/vim-airline-themes', { commit = '77aab8c6cf7179ddb8a05741da7e358a86b2c3ab' })
vim.fn['plug#']('powerman/vim-plugin-ansiesc', {
  commit = '690f820d20b6e3a79ba20499874eb7333aa4ca5c',
})
vim.fn['plug#']('nvim-tree/nvim-web-devicons', { commit = 'dad71387de386a946b123079d0e53f23028f3abd' })
vim.fn['plug#']('preservim/nerdtree', { commit = '690d061b591525890f1471c6675bcb5bdc8cdff9' })
vim.fn['plug#']('tiagofumo/vim-nerdtree-syntax-highlight', { commit = '35e70334a2ff6e89b82a145d1ac889e82d1ddb4e' })
vim.fn['plug#']('sindrets/diffview.nvim', { commit = '4516612fe98ff56ae0415a259ff6361a89419b0a' })
vim.fn['plug#']('preservim/tagbar', { commit = '07cb8247487208124978daff8e13624667635457' })
vim.fn['plug#']('christoomey/vim-tmux-navigator', { commit = 'e41c431a0c7b7388ae7ba341f01a0d217eb3a432' })
vim.fn['plug#']('preservim/vimux', { commit = 'd6cb7f63a8bb428ffc27060b7f83c77fb115589c' })
vim.fn['plug#']('sakhnik/nvim-gdb', { commit = '67abac716b626ece57f3a7c72121542f0b3edfe9' })
vim.fn['plug#']('rust-lang/rust.vim', { commit = '889b9a7515db477f4cb6808bef1769e53493c578' })
vim.fn['plug#']('vim-autoformat/vim-autoformat', { commit = '38161c4e875cf198789f32e0f773039696a431f0' })
vim.fn['plug#']('nvim-lua/plenary.nvim', { commit = '74b06c6c75e4eeb3108ec01852001636d85a932b' })
vim.fn['plug#']('junegunn/fzf', { commit = '24832e97ef9640e5f859ede8dc163cf3c27145cb' })
vim.fn['plug#']('junegunn/fzf.vim', { commit = 'd2a59a992a2455f609c0fde2ebd84427ea8f919a' })
vim.fn['plug#end']()
-- A fresh setup loads this file once before PlugUpdate has cloned themes.
-- Keep that bootstrap load valid; subsequent starts apply the pinned theme.
pcall(vim.cmd.colorscheme, "NeoSolarized")

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

local function find_clang_format_py()
	local candidates = {}
	if vim.env.CLANG_FORMAT_PY and vim.env.CLANG_FORMAT_PY ~= "" then
		table.insert(candidates, vim.env.CLANG_FORMAT_PY)
	end
	for version = 40, 15, -1 do
		table.insert(candidates,
			string.format("/usr/lib/llvm-%d/share/clang/clang-format.py", version))
	end
	table.insert(candidates, "/usr/share/clang/clang-format.py")
	for _, path in ipairs(candidates) do
		if vim.fn.filereadable(path) == 1 then return path end
	end
	return nil
end

local clang_format_py = find_clang_format_py()
if clang_format_py and vim.fn.has("python3") == 1 then
	local helper = vim.fn.fnameescape(clang_format_py)
	vim.keymap.set('v', '<C-K>', ':py3f ' .. helper .. '<cr>',
		{ desc = "Format selection with clang-format.py" })
	vim.keymap.set('i', '<C-K>', '<c-o>:py3f ' .. helper .. '<cr>',
		{ desc = "Format with clang-format.py" })
end

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

-- Forward focus events into explicitly opted-in :terminal buffers, combining
-- nvim's own FocusGained/FocusLost with the buffer/window the user is viewing.
-- Requires the outer terminal to emit focus reporting and, in tmux,
-- `set -g focus-events on`. Without those, nvim never sees focus transitions
-- and embedded programs will believe nvim is permanently focused. Run
-- :TerminalFocusForward in a terminal buffer to opt in, or use ! to opt out.
do
	local nvim_focused = true
	local last_sent = {}
	local FOCUS_IN, FOCUS_OUT = "\27[I", "\27[O"

	local function sync(bufnr)
		if not vim.api.nvim_buf_is_valid(bufnr) then return end
		if vim.bo[bufnr].buftype ~= "terminal" then return end
		if vim.b[bufnr].terminal_focus_forward ~= true then return end
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
	vim.api.nvim_create_autocmd("TermOpen", {
		group = group,
		callback = function(args)
			vim.api.nvim_buf_create_user_command(args.buf, "TerminalFocusForward", function(opts)
				vim.b[args.buf].terminal_focus_forward = not opts.bang
				last_sent[args.buf] = nil
				if not opts.bang then sync(args.buf) end
			end, {
				bang = true,
				desc = "Forward terminal focus events for this buffer (! disables)",
			})
			sync(args.buf)
		end,
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
			if query == "" and default_buf > 0 then
				vim.cmd("buffer " .. default_buf)
			elseif #matches > 0 and selected > 0 then
				vim.cmd("buffer " .. matches[selected].bufnr)
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
vim.keymap.set('n', '<C-x>b', switch_to_buffer, { desc = "Switch to buffer" })
vim.keymap.set('n', '<leader>b', vim.cmd.Buffers, { desc = "fzf buffer picker" })
