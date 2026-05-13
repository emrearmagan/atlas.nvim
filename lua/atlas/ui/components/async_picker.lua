--- First time trying claude code and i must say: I am impressed. Worked out of the box and its toooo late for me to review this. Will review and fix when any issue occures :)
local M = {}

local spinner_component = require("atlas.ui.components.spinner")

---@class AsyncPickerItem
---@field id string
---@field label string
---@field value any
---@field secondary string|nil

---@class AsyncPickerFetchContext
---@field query string
---@field signal { cancelled: boolean }

---@alias AsyncPickerFetchFn fun(ctx: AsyncPickerFetchContext, done: fun(items: AsyncPickerItem[]|nil, err: string|nil))

---@class AsyncPickerOptions
---@field title string|nil
---@field prompt string|nil
---@field initial_query string|nil
---@field initial_items AsyncPickerItem[]|nil
---@field min_query_length integer|nil
---@field debounce_ms integer|nil
---@field max_results integer|nil
---@field cache_ttl_ms integer|nil
---@field identifier string|nil
---@field fetch_on_open boolean|nil          -- default true; fire fetch immediately with initial query
---@field spinner any
---@field fetch AsyncPickerFetchFn
---@field format_item fun(item: AsyncPickerItem): string|nil
---@field on_select fun(item: AsyncPickerItem)
---@field on_cancel fun()|nil

---@class AsyncPickerHandle
---@field close fun()
---@field is_open fun(): boolean

---@class AsyncPickerCacheEntry
---@field items AsyncPickerItem[]
---@field ts_ms number

---@class AsyncPickerState
---@field query string
---@field items AsyncPickerItem[]
---@field selected_item_idx integer
---@field loading boolean
---@field err string|nil
---@field request_id integer
---@field debounce_timer uv_timer_t|nil
---@field closed boolean
---@field spinner_instance SpinnerInstance|nil
---@field _selectable_map table<integer, boolean>|nil
---@field _line_count integer|nil
---@field _line_to_item_index table<integer, integer>|nil
---@field _item_index_to_line table<integer, integer>|nil
---@field signal { cancelled: boolean }|nil
---@field input_buf integer|nil
---@field input_win integer|nil
---@field results_buf integer|nil
---@field results_win integer|nil

local MAX_CACHE_ENTRIES = 200

--- Module-level cache store, keyed by identifier.
--- Each entry is { queries = {}, order = {} }
---@type table<string, { queries: table<string, AsyncPickerCacheEntry>, order: string[] }>
local cache_store = {}

---@param s string
---@return string
local function sanitize_line(s)
	return (s:gsub("\n", " "):gsub("\r", ""))
end

local ns = vim.api.nvim_create_namespace("atlas.async_picker")

---@param query string
---@return string
local function normalize_query(query)
	return vim.trim(query):lower()
end

---@return number
local function now_ms()
	return vim.loop.hrtime() / 1e6
end

---@param state AsyncPickerState
---@param opts AsyncPickerOptions
local function render_results(state, opts)
	if state.closed then
		return
	end

	local buf = state.results_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local lines = {}
	local highlights = {}
	local selectable_map = {}

	if state.loading then
		local spinner_text = state.spinner_instance and state.spinner_instance:text("Searching...") or "Searching..."
		table.insert(lines, "  " .. spinner_text)
		selectable_map[#lines] = false
	end

	if state.err then
		table.insert(lines, "  " .. sanitize_line(state.err))
		table.insert(highlights, { line = #lines - 1, hl = "AtlasLogError" })
		selectable_map[#lines] = false
	end

	if not state.loading and not state.err and #state.items == 0 then
		local msg = state.query == "" and "Type to search..." or "No results"
		table.insert(lines, "  " .. msg)
		table.insert(highlights, { line = #lines - 1, hl = "AtlasTextMuted" })
		selectable_map[#lines] = false
	end

	-- item_index_to_line maps item position (1-based) to line number
	local item_index_to_line = {}
	local line_to_item_index = {}
	local max_results = opts.max_results or 200
	local count = 0
	for item_idx, item in ipairs(state.items) do
		if count >= max_results then
			break
		end

		local label = sanitize_line(item.label or "")
		if opts.format_item then
			local ok, formatted = pcall(opts.format_item, item)
			if ok and type(formatted) == "string" then
				label = sanitize_line(formatted)
			end
		end

		local secondary = item.secondary and sanitize_line(item.secondary) or ""
		local display = "  " .. label
		if secondary ~= "" then
			display = display .. "  " .. secondary
		end

		table.insert(lines, display)
		selectable_map[#lines] = true
		item_index_to_line[item_idx] = #lines
		line_to_item_index[#lines] = item_idx
		count = count + 1

		if secondary ~= "" then
			local label_end = 2 + #label
			table.insert(highlights, {
				line = #lines - 1,
				start_col = label_end + 2,
				end_col = #display,
				hl = "AtlasTextMuted",
			})
		end
	end

	if #lines == 0 then
		table.insert(lines, "  Type to search...")
		table.insert(highlights, { line = 0, hl = "AtlasTextMuted" })
		selectable_map[1] = false
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, hl in ipairs(highlights) do
		local start_col = hl.start_col or 0
		local end_col = hl.end_col or #(lines[hl.line + 1] or "")
		vim.api.nvim_buf_set_extmark(buf, ns, hl.line, start_col, {
			end_col = end_col,
			hl_group = hl.hl,
		})
	end

	-- Resolve selected_item_idx to a line, clamping if needed
	local target_line = item_index_to_line[state.selected_item_idx]
	if not target_line then
		-- Current item no longer visible; find first selectable
		target_line = nil
		for i = 1, #lines do
			if selectable_map[i] then
				target_line = i
				state.selected_item_idx = line_to_item_index[i] or 1
				break
			end
		end
		target_line = target_line or 1
	end

	-- Store maps on state for navigation
	state._selectable_map = selectable_map
	state._line_count = #lines
	state._line_to_item_index = line_to_item_index
	state._item_index_to_line = item_index_to_line

	-- Update cursor
	if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
		pcall(vim.api.nvim_win_set_cursor, state.results_win, { target_line, 0 })
	end
end

---@param state AsyncPickerState
---@param direction integer -- -1 for up, +1 for down
local function move_selection(state, direction)
	if state.closed or not state._selectable_map then
		return
	end

	local total = state._line_count or 0
	if total == 0 then
		return
	end

	-- Find current line from item index
	local current_line = state._item_index_to_line and state._item_index_to_line[state.selected_item_idx]
	if not current_line then
		-- Fallback: find first selectable line
		for i = 1, total do
			if state._selectable_map[i] then
				current_line = i
				break
			end
		end
		if not current_line then
			return
		end
	end

	local idx = current_line
	for _ = 1, total do
		idx = idx + direction
		if idx < 1 then
			idx = total
		elseif idx > total then
			idx = 1
		end

		if state._selectable_map[idx] and state._line_to_item_index[idx] then
			state.selected_item_idx = state._line_to_item_index[idx]
			if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
				pcall(vim.api.nvim_win_set_cursor, state.results_win, { idx, 0 })
			end
			return
		end
	end
end

---@param state AsyncPickerState
---@return AsyncPickerItem|nil
local function get_selected_item(state)
	local item_idx = state.selected_item_idx
	if item_idx < 1 or item_idx > #state.items then
		return nil
	end
	return state.items[item_idx]
end

---@param identifier string
---@return { queries: table<string, AsyncPickerCacheEntry>, order: string[] }
local function get_cache_bucket(identifier)
	if not cache_store[identifier] then
		cache_store[identifier] = { queries = {}, order = {} }
	end
	return cache_store[identifier]
end

---@param identifier string
---@param cache_ttl_ms number
---@param query string
---@return AsyncPickerItem[]|nil
local function cache_get(identifier, cache_ttl_ms, query)
	local bucket = get_cache_bucket(identifier)
	local key = normalize_query(query)
	local entry = bucket.queries[key]
	if not entry then
		return nil
	end

	if now_ms() - entry.ts_ms > cache_ttl_ms then
		bucket.queries[key] = nil
		for i, k in ipairs(bucket.order) do
			if k == key then
				table.remove(bucket.order, i)
				break
			end
		end
		return nil
	end

	return entry.items
end

---@param identifier string
---@param query string
---@param items AsyncPickerItem[]
local function cache_set(identifier, query, items)
	local bucket = get_cache_bucket(identifier)
	local key = normalize_query(query)

	if not bucket.queries[key] then
		table.insert(bucket.order, key)
	end

	bucket.queries[key] = { items = items, ts_ms = now_ms() }

	-- Evict oldest if over limit
	while #bucket.order > MAX_CACHE_ENTRIES do
		local oldest = table.remove(bucket.order, 1)
		bucket.queries[oldest] = nil
	end
end

---@param state AsyncPickerState
local function cancel_debounce(state)
	if state.debounce_timer then
		if not state.debounce_timer:is_closing() then
			state.debounce_timer:stop()
			state.debounce_timer:close()
		end
		state.debounce_timer = nil
	end
end

---@param state AsyncPickerState
local function cancel_signal(state)
	if state.signal then
		state.signal.cancelled = true
	end
end

---@param state AsyncPickerState
local function stop_spinner(state)
	if state.spinner_instance then
		state.spinner_instance:stop()
		state.spinner_instance = nil
	end
end

---@param state AsyncPickerState
---@param opts AsyncPickerOptions
local function do_fetch(state, opts)
	if state.closed then
		return
	end

	local query = state.query
	local min_len = opts.min_query_length or 0
	if #vim.trim(query) < min_len then
		state.loading = false
		state.items = {}
		state.err = nil
		stop_spinner(state)
		render_results(state, opts)
		return
	end

	-- Check cache
	local ck = opts.identifier or "__default__"
	local cached = cache_get(ck, opts.cache_ttl_ms or 60000, query)
	if cached then
		state.items = cached
		state.loading = false
		state.err = nil
		stop_spinner(state)
		render_results(state, opts)
		return
	end

	-- Start loading
	state.loading = true
	state.err = nil
	state.request_id = state.request_id + 1
	local current_request_id = state.request_id

	-- Cancel previous signal
	cancel_signal(state)

	local signal = { cancelled = false }
	state.signal = signal

	-- Start spinner for animated loading row
	if not state.spinner_instance then
		state.spinner_instance = spinner_component.create({
			interval_ms = 90,
			on_tick = function()
				if state.closed or current_request_id ~= state.request_id then
					return
				end
				if state.loading then
					render_results(state, opts)
				end
			end,
		})
		state.spinner_instance:start()
	end

	render_results(state, opts)

	---@type AsyncPickerFetchContext
	local ctx = { query = query, signal = signal }

	opts.fetch(ctx, function(items, err)
		vim.schedule(function()
			-- Stale response protection
			if state.closed or current_request_id ~= state.request_id or signal.cancelled then
				return
			end

			state.loading = false
			stop_spinner(state)

			if err then
				state.err = err
				state.items = state.items or {}
			else
				local valid_items = {}
				for _, item in ipairs(items or {}) do
					if type(item) == "table" and type(item.id) == "string" and type(item.label) == "string" then
						table.insert(valid_items, item)
					end
				end
				state.items = valid_items
				state.err = nil
				cache_set(ck, query, valid_items)
			end

			render_results(state, opts)
		end)
	end)
end

---@param state AsyncPickerState
---@param opts AsyncPickerOptions
local function schedule_fetch(state, opts)
	cancel_debounce(state)

	local debounce_ms = opts.debounce_ms or 250

	state.debounce_timer = vim.loop.new_timer()
	if not state.debounce_timer then
		do_fetch(state, opts)
		return
	end

	state.debounce_timer:start(
		debounce_ms,
		0,
		vim.schedule_wrap(function()
			cancel_debounce(state)
			do_fetch(state, opts)
		end)
	)
end

---@param state AsyncPickerState
---@param opts AsyncPickerOptions
local function on_query_change(state, opts)
	if state.closed or not state.input_buf or not vim.api.nvim_buf_is_valid(state.input_buf) then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, 1, false)
	local query = lines[1] or ""
	if query == state.query then
		return
	end

	state.query = query
	cancel_signal(state)
	state.request_id = state.request_id + 1
	schedule_fetch(state, opts)
end

---@param state AsyncPickerState
---@param opts AsyncPickerOptions
local function close_picker(state, opts)
	if state.closed then
		return
	end
	state.closed = true

	cancel_debounce(state)
	cancel_signal(state)
	stop_spinner(state)

	vim.cmd("stopinsert")

	if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
		vim.api.nvim_win_close(state.input_win, true)
	end
	if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
		vim.api.nvim_win_close(state.results_win, true)
	end
	if state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) then
		vim.api.nvim_buf_delete(state.input_buf, { force = true })
	end
	if state.results_buf and vim.api.nvim_buf_is_valid(state.results_buf) then
		vim.api.nvim_buf_delete(state.results_buf, { force = true })
	end

	state.input_win = nil
	state.results_win = nil
	state.input_buf = nil
	state.results_buf = nil

	if opts.on_cancel then
		opts.on_cancel()
	end
end

---@param state AsyncPickerState
---@param opts AsyncPickerOptions
local function select_current(state, opts)
	local item = get_selected_item(state)
	if not item then
		return
	end

	state.closed = true
	cancel_debounce(state)
	cancel_signal(state)
	stop_spinner(state)

	vim.cmd("stopinsert")

	if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
		vim.api.nvim_win_close(state.input_win, true)
	end
	if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
		vim.api.nvim_win_close(state.results_win, true)
	end
	if state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) then
		vim.api.nvim_buf_delete(state.input_buf, { force = true })
	end
	if state.results_buf and vim.api.nvim_buf_is_valid(state.results_buf) then
		vim.api.nvim_buf_delete(state.results_buf, { force = true })
	end

	state.input_win = nil
	state.results_win = nil
	state.input_buf = nil
	state.results_buf = nil

	opts.on_select(item)
end

---@param opts AsyncPickerOptions
---@return AsyncPickerHandle
function M.open(opts)
	local title = opts.title or "Search"
	local prompt = opts.prompt or "Query"

	-- Dimensions
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines
	local width = math.min(math.max(60, math.floor(editor_width * 0.5)), editor_width - 4)
	local results_height = math.min(15, editor_height - 8)
	local total_height = results_height + 3 -- 1 input + 2 border
	local row = math.max(1, math.floor((editor_height - total_height) / 2))
	local col = math.floor((editor_width - width) / 2)

	-- Create input buffer
	local input_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = input_buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = input_buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = input_buf })

	-- Create results buffer
	local results_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = results_buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = results_buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = results_buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = results_buf })

	-- Open input window
	local input_title = title
	if prompt and prompt ~= "" then
		input_title = title .. " - " .. prompt
	end

	local input_win = vim.api.nvim_open_win(input_buf, true, {
		relative = "editor",
		width = width - 2,
		height = 1,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		zindex = 260,
		title = " " .. input_title .. " ",
		title_pos = "center",
	})

	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:NormalFloat,NormalNC:NormalFloat,FloatBorder:FloatBorder",
		{ win = input_win }
	)

	-- Open results window
	local results_win = vim.api.nvim_open_win(results_buf, false, {
		relative = "editor",
		width = width - 2,
		height = results_height,
		row = row + 3,
		col = col,
		style = "minimal",
		border = "rounded",
		zindex = 260,
	})

	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:NormalFloat,NormalNC:NormalFloat,FloatBorder:FloatBorder,CursorLine:CursorLine",
		{ win = results_win }
	)
	vim.api.nvim_set_option_value("cursorline", true, { win = results_win })

	-- Initialize state
	---@type AsyncPickerState
	local state = {
		query = opts.initial_query or "",
		items = opts.initial_items or {},
		selected_item_idx = 1,
		loading = false,
		err = nil,
		request_id = 0,
		debounce_timer = nil,
		closed = false,
		spinner_instance = nil,
		signal = nil,
		input_buf = input_buf,
		input_win = input_win,
		results_buf = results_buf,
		results_win = results_win,
		_selectable_map = {},
		_line_count = 0,
	}

	-- Set initial query text
	if state.query ~= "" then
		vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { state.query })
	end

	-- Initial render
	render_results(state, opts)

	-- Fetch on open (default true): fire immediate fetch with current query
	local fetch_on_open = opts.fetch_on_open ~= false
	if fetch_on_open then
		do_fetch(state, opts)
	elseif state.query ~= "" then
		schedule_fetch(state, opts)
	end

	-- Keymaps on input buffer (insert + normal modes)
	local function map(buf, modes, key, fn)
		vim.keymap.set(modes, key, fn, { buffer = buf, silent = true, nowait = true })
	end

	-- Close
	map(input_buf, { "n" }, "<Esc>", function()
		close_picker(state, opts)
	end)
	map(input_buf, { "n" }, "q", function()
		close_picker(state, opts)
	end)

	-- Navigation from input buf
	map(input_buf, { "i", "n" }, "<Down>", function()
		move_selection(state, 1)
	end)
	map(input_buf, { "i", "n" }, "<Up>", function()
		move_selection(state, -1)
	end)
	map(input_buf, { "n" }, "j", function()
		move_selection(state, 1)
	end)
	map(input_buf, { "n" }, "k", function()
		move_selection(state, -1)
	end)
	map(input_buf, { "i", "n" }, "<C-n>", function()
		move_selection(state, 1)
	end)
	map(input_buf, { "i", "n" }, "<C-p>", function()
		move_selection(state, -1)
	end)
	map(input_buf, { "i", "n" }, "<C-j>", function()
		move_selection(state, 1)
	end)
	map(input_buf, { "i", "n" }, "<C-k>", function()
		move_selection(state, -1)
	end)

	-- Select
	map(input_buf, { "i", "n" }, "<CR>", function()
		select_current(state, opts)
	end)

	-- Scroll
	map(input_buf, { "i", "n" }, "<C-d>", function()
		if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
			local half = math.floor((opts.max_results or 15) / 2)
			for _ = 1, half do
				move_selection(state, 1)
			end
		end
	end)
	map(input_buf, { "i", "n" }, "<C-u>", function()
		if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
			local half = math.floor((opts.max_results or 15) / 2)
			for _ = 1, half do
				move_selection(state, -1)
			end
		end
	end)

	-- Watch for text changes in input buffer
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = input_buf,
		callback = function()
			on_query_change(state, opts)
		end,
	})

	-- Auto-close when leaving the input window
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(input_win),
		once = true,
		callback = function()
			if not state.closed then
				close_picker(state, opts)
			end
		end,
	})

	-- Start in insert mode for immediate typing
	vim.cmd("startinsert!")

	---@type AsyncPickerHandle
	local handle = {
		close = function()
			close_picker(state, opts)
		end,
		is_open = function()
			return not state.closed
		end,
	}

	return handle
end

return M
