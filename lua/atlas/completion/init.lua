local M = {}
local requests = require("atlas.core.requests")
---@type table<integer, AtlasCompletionState>
local attached = {}
local loading_ns = vim.api.nvim_create_namespace("atlas.completion.loading")

---@class AtlasCompletionContext
---@field provider AtlasProviderId
---@field repository string|nil
---@field project string|nil
---@field pr PullRequestRef|nil
---@field issue IssueRef|nil

---@class AtlasCompletionItem
---@field label string
---@field insert_text string
---@field filter_text string|nil
---@field detail string|nil

---@class AtlasCompletionSource
---@field triggers string[]
---@field format_mention? fun(user: AtlasUser|PullsAuthor): string|nil
---@field match? fun(before: string, triggers: string[], context: AtlasCompletionContext): integer|nil, string|nil
---@field complete fun(context: AtlasCompletionContext, query: string, done: fun(items: AtlasCompletionItem[]|nil, err: string|nil)): { cancel: fun() }|nil

---@class AtlasCompletionState
---@field buf integer
---@field context AtlasCompletionContext
---@field sources AtlasCompletionSource[]
---@field enabled (fun(): boolean)|nil
---@field requests AtlasRequestScope
---@field last_input { row: integer, col: integer, tick: integer, before: string }|nil
---@field updating_menu boolean
---@field saved_completeopt string|nil
---@field loading_win integer|nil

---@param before string
---@param triggers string[]
---@return integer|nil, string|nil
local function match_trigger(before, triggers)
	for _, trigger in ipairs(triggers) do
		local start = before:match(".*()" .. vim.pesc(trigger) .. "[%w_.%-\128-\255]*$")
		if start and (start == 1 or before:sub(start - 1, start - 1):match("[%s(%[{]")) then
			return start - 1, before:sub(start + #trigger)
		end
	end
end

---@param state AtlasCompletionState
local function close_loading(state)
	if state.loading_win and vim.api.nvim_win_is_valid(state.loading_win) then
		vim.api.nvim_win_close(state.loading_win, true)
	end
	state.loading_win = nil
end

---@param state AtlasCompletionState
local function reset_requests(state)
	state.requests.cancel()
	state.requests = requests.new()
	close_loading(state)
end

---@param state AtlasCompletionState
---@return { row: integer, col: integer, tick: integer, before: string }|nil
local function get_input(state)
	if vim.api.nvim_get_current_buf() ~= state.buf or vim.fn.mode() ~= "i" or state.enabled and not state.enabled() then
		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	return {
		row = cursor[1],
		col = cursor[2],
		tick = vim.api.nvim_buf_get_changedtick(state.buf),
		before = vim.api.nvim_get_current_line():sub(1, cursor[2]),
	}
end

---@return boolean
local function has_selection()
	return vim.fn.pumvisible() == 1 and vim.fn.complete_info({ "selected" }).selected >= 0
end

---@param state AtlasCompletionState
local function restore_menu(state)
	if state.saved_completeopt then
		vim.api.nvim_set_option_value("completeopt", state.saved_completeopt, { scope = "local" })
		state.saved_completeopt = nil
	end
end

---@param state AtlasCompletionState
---@param start integer
---@param items table[]
local function show_menu(state, start, items)
	state.saved_completeopt = state.saved_completeopt
		or vim.api.nvim_get_option_value("completeopt", { scope = "local" })
	vim.api.nvim_set_option_value("completeopt", "menu,menuone,noselect,noinsert", { scope = "local" })
	state.updating_menu = true
	vim.fn.complete(start + 1, items)
	state.updating_menu = false

	if #items == 0 then
		restore_menu(state)
	end
end

---@param state AtlasCompletionState
---@param row integer
---@param col integer
local function show_loading(state, row, col)
	local text = " Loading... "
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_extmark(buf, loading_ns, 0, 0, {
		virt_text = { { text, "Pmenu" } },
		virt_text_pos = "overlay",
	})
	vim.bo[buf].modifiable = false

	local above = vim.fn.winline() == vim.api.nvim_win_get_height(0)
	state.loading_win = vim.api.nvim_open_win(buf, false, {
		relative = "win",
		win = vim.api.nvim_get_current_win(),
		bufpos = { row - 1, col },
		anchor = above and "SW" or "NW",
		row = above and 0 or 1,
		col = 0,
		width = #text,
		height = 1,
		style = "minimal",
		border = "none",
		focusable = false,
		noautocmd = true,
		zindex = 100,
	})
	vim.wo[state.loading_win].winhighlight = "Normal:Pmenu,NormalNC:Pmenu"
end

---@param matches { source: AtlasCompletionSource, start: integer, query: string }[]
---@param results table<string, AtlasCompletionItem[]>
---@return table[]
local function menu_items(matches, results)
	local items = {}
	for index, match in ipairs(matches) do
		local query = vim.fn.tolower(match.query)
		for _, item in ipairs(results[tostring(index)] or {}) do
			if vim.fn.tolower(item.filter_text or item.label):find(query, 1, true) then
				items[#items + 1] = {
					word = item.insert_text,
					abbr = item.label,
					menu = item.detail or "",
					equal = 1,
				}
				if #items == 20 then
					return items
				end
			end
		end
	end
	return items
end

---@param state AtlasCompletionState
---@param matches { source: AtlasCompletionSource, start: integer, query: string }[]
---@param input { row: integer, col: integer, tick: integer, before: string }
---@param pending AtlasRequestScope
local function fetch(state, matches, input, pending)
	if state.requests ~= pending or not vim.deep_equal(get_input(state), input) then
		return
	end

	if state.saved_completeopt then
		show_menu(state, input.col, {})
	end

	local starts = {}
	for index, match in ipairs(matches) do
		starts[tostring(index)] = function(done)
			return match.source.complete(state.context, match.query, done)
		end
	end

	local finished = false
	pending.all(starts, function(results)
		finished = true
		vim.schedule(function()
			if state.requests ~= pending then
				return
			end
			close_loading(state)
			if has_selection() or not vim.deep_equal(get_input(state), input) then
				return
			end

			show_menu(state, matches[1].start, menu_items(matches, results))
		end)
	end)
	if not finished then
		show_loading(state, input.row, matches[1].start)
	end
end

---@param state AtlasCompletionState
---@param manual boolean|nil
local function complete(state, manual)
	if has_selection() then
		reset_requests(state)
		return
	end

	local input = get_input(state)
	local previous = state.last_input
	if not manual and input and previous and input.row == previous.row and input.before == previous.before then
		state.last_input = input
		return
	end

	reset_requests(state)
	state.last_input = input
	if not input then
		return
	end

	local matches = {}
	for _, source in ipairs(state.sources) do
		local match = source.match or match_trigger
		local start, query = match(input.before, source.triggers, state.context)
		if start and (#matches == 0 or start == matches[1].start) then
			matches[#matches + 1] = { source = source, start = start, query = query or "" }
		end
	end

	if #matches == 0 then
		if state.saved_completeopt then
			show_menu(state, input.col, {})
		end
		return
	end

	local pending = state.requests
	vim.defer_fn(function()
		fetch(state, matches, input, pending)
	end, manual and 0 or 120)
end

---@param state AtlasCompletionState
---@param event string
local function on_event(state, event)
	if event == "TextChangedI" or event == "TextChangedP" then
		complete(state)
		return
	end

	if event == "CursorMovedI" then
		local previous = state.last_input
		if not previous then
			return
		end

		local input = get_input(state)
		if input and input.tick ~= previous.tick then
			return
		end

		if not vim.deep_equal(input, previous) then
			reset_requests(state)
			state.last_input = input
		end
		return
	end

	if event == "CompleteDone" and state.updating_menu then
		return
	end

	reset_requests(state)
	restore_menu(state)
	state.last_input = event == "CompleteDone" and get_input(state) or nil
	if event == "BufWipeout" then
		attached[state.buf] = nil
	end
end

---@param provider IssuesProvider|PullsProvider
---@param user AtlasUser|PullsAuthor|nil
---@return string|nil
function M.format_mention(provider, user)
	if not user then
		return nil
	end

	local sources = provider.capabilities.completion
	local users = sources and sources.users
	if users and users.format_mention then
		return users.format_mention(user)
	end

	if user.username and user.username ~= "" then
		return "@" .. user.username
	end
end

---@param buf integer
---@param opts { context: AtlasCompletionContext, sources?: string[], enabled?: fun(): boolean }
function M.attach(buf, opts)
	if attached[buf] then
		reset_requests(attached[buf])
		restore_menu(attached[buf])
		vim.keymap.del("i", "<C-x><C-u>", { buffer = buf })
	end

	local provider = require("atlas.providers")[opts.context.provider]
	local available = provider and provider.capabilities and provider.capabilities.completion or {}
	local names = opts.sources or vim.tbl_keys(available)
	if not opts.sources then
		table.sort(names)
	end
	local sources = {}
	for _, name in ipairs(names) do
		local source = available[name]
		if source then
			sources[#sources + 1] = source
		end
	end

	local group = vim.api.nvim_create_augroup("AtlasCompletion" .. buf, { clear = true })
	if #sources == 0 then
		attached[buf] = nil
		return
	end
	---@type AtlasCompletionState
	local state = {
		buf = buf,
		context = opts.context,
		sources = sources,
		enabled = opts.enabled,
		requests = requests.new(),
		updating_menu = false,
	}
	attached[buf] = state

	vim.keymap.set("i", "<C-x><C-u>", function()
		complete(state, true)
	end, { buffer = buf, desc = "Complete Atlas references" })
	vim.api.nvim_create_autocmd({
		"TextChangedI",
		"TextChangedP",
		"CursorMovedI",
		"CompleteDone",
		"InsertLeave",
		"WinLeave",
		"BufLeave",
		"BufWipeout",
	}, {
		group = group,
		buffer = buf,
		callback = function(event)
			on_event(state, event.event)
		end,
	})
end

return M
