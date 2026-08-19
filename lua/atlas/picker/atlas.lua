local M = {}

local icons = require("atlas.ui.shared.icons")
local keymaps = require("atlas.core.keymaps")
local spinner = require("atlas.ui.components.spinner")
local statusline = require("atlas.ui.statusline")
local virtual_lines = require("atlas.ui.components.virtual_lines")

local namespace = vim.api.nvim_create_namespace("atlas.picker")

---@param handle { cancel: fun() }|nil
local function cancel(handle)
	if handle then
		handle.cancel()
	end
end

---@param fetch fun(query: string, done: fun(items: any[]|nil, err: string|nil)): { cancel: fun() }|nil
---@param delay integer
local function debounce(fetch, delay)
	if delay == 0 then
		return fetch
	end
	return function(query, done)
		local request
		local timer
		timer = vim.defer_fn(function()
			timer = nil
			request = fetch(query, done)
		end, delay)
		return {
			cancel = function()
				if timer then
					timer:stop()
					timer:close()
					timer = nil
				end
				cancel(request)
			end,
		}
	end
end

---@param win integer
---@param source_win integer
local function configure_window(win, source_win)
	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder,CursorLine:CursorLine,SignColumn:NormalFloat",
		{ win = win }
	)
	statusline.inherit(win, source_win)
end

---@param request AtlasPickerRequest
function M.open(request)
	local fetch_items = request.fetch and debounce(request.fetch, request.debounce_ms or 0) or nil
	local source_win = vim.api.nvim_get_current_win()
	local has_preview = request.preview_item ~= nil

	local function layout(item_count)
		local total_width = math.min(has_preview and 100 or 70, vim.o.columns - 4)
		local max_items = math.max(1, math.min(has_preview and 18 or 10, vim.o.lines - 8))
		local item_height = has_preview and max_items or math.max(1, math.min(item_count, max_items))
		local main_width = has_preview and math.floor(total_width * 0.42) or total_width
		local preview_width = has_preview and total_width - main_width - 1 or 0
		local height = item_height + 2
		local outer_width = has_preview and main_width + preview_width + 4 or main_width + 2
		return {
			main_width = main_width,
			preview_width = preview_width,
			height = height,
			item_height = item_height,
			row = math.max(1, math.floor((vim.o.lines - height - 2) / 2)),
			col = math.max(1, math.floor((vim.o.columns - outer_width) / 2)),
		}
	end

	local initial_layout = layout(#request.items)
	local main_buf = vim.api.nvim_create_buf(false, true)
	local preview_buf = has_preview and vim.api.nvim_create_buf(false, true) or nil
	vim.bo[main_buf].filetype = "atlas-picker"
	vim.b[main_buf].completion = false
	for _, buf in ipairs({ main_buf, preview_buf }) do
		if buf then
			vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
		end
	end
	local main_win = vim.api.nvim_open_win(main_buf, true, {
		relative = "editor",
		row = initial_layout.row,
		col = initial_layout.col,
		width = initial_layout.main_width,
		height = initial_layout.height,
		style = "minimal",
		border = "rounded",
		title = " " .. request.title .. " ",
		title_pos = "center",
	})
	local preview_win = preview_buf
			and vim.api.nvim_open_win(preview_buf, false, {
				relative = "editor",
				row = initial_layout.row,
				col = initial_layout.col + initial_layout.main_width + 2,
				width = initial_layout.preview_width,
				height = initial_layout.height,
				style = "minimal",
				border = "rounded",
				title = " Preview ",
				title_pos = "center",
			})
		or nil

	configure_window(main_win, source_win)
	vim.api.nvim_set_option_value("wrap", false, { win = main_win })
	vim.api.nvim_set_option_value("signcolumn", "yes:1", { win = main_win })
	if preview_win then
		configure_window(preview_win, main_win)
		vim.api.nvim_set_option_value("wrap", true, { win = preview_win })
	end

	local all_items = request.items
	local state = {
		closed = false,
		query = "",
		items = all_items,
		index = math.min(math.max(1, request.initial_index or 1), math.max(1, #all_items)),
		selected = {},
		loading = false,
		err = nil,
		fetch_generation = 0,
		preview_generation = 0,
		fetch = nil,
		preview = nil,
		spinner = nil,
	}
	for _, item in ipairs(request.selected) do
		state.selected[request.key(item)] = item
	end

	local function resize(next_layout)
		vim.api.nvim_win_set_config(main_win, {
			relative = "editor",
			row = next_layout.row,
			col = next_layout.col,
			width = next_layout.main_width,
			height = next_layout.height,
		})
		if preview_win then
			vim.api.nvim_win_set_config(preview_win, {
				relative = "editor",
				row = next_layout.row,
				col = next_layout.col + next_layout.main_width + 2,
				width = next_layout.preview_width,
				height = next_layout.height,
			})
		end
	end

	local function close(cancelled)
		if state.closed then
			return
		end
		state.closed = true
		cancel(state.fetch)
		cancel(state.preview)
		if state.spinner then
			state.spinner:stop()
		end
		vim.cmd("stopinsert")
		for _, win in ipairs({ main_win, preview_win }) do
			if win and vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end
		if cancelled and request.on_cancel then
			request.on_cancel()
		end
	end

	local function current_item()
		if state.loading or state.err then
			return nil
		end
		return state.items[state.index]
	end

	local function render_preview()
		if not preview_buf or not request.preview_item then
			return
		end
		cancel(state.preview)
		state.preview_generation = state.preview_generation + 1
		local generation = state.preview_generation
		local item = current_item()
		vim.api.nvim_set_option_value("modifiable", true, { buf = preview_buf })
		vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, item and { "Loading..." } or {})
		vim.api.nvim_set_option_value("modifiable", false, { buf = preview_buf })
		if not item then
			return
		end
		state.preview = request.preview_item(item, function(value)
			vim.schedule(function()
				if state.closed or generation ~= state.preview_generation then
					return
				end
				vim.api.nvim_set_option_value("modifiable", true, { buf = preview_buf })
				vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, value.lines)
				vim.api.nvim_set_option_value("modifiable", false, { buf = preview_buf })
				vim.api.nvim_set_option_value("filetype", "markdown", { buf = preview_buf })
				if preview_win and vim.api.nvim_win_is_valid(preview_win) then
					vim.api.nvim_win_set_config(preview_win, { title = " " .. (value.title or request.title) .. " " })
				end
			end)
		end)
	end

	local function render(update_preview)
		local rows, highlights = {}, {}
		local has_items = not state.loading and not state.err and #state.items > 0
		state.index = has_items and math.min(math.max(1, state.index), #state.items) or 1
		local next_layout = layout(has_items and #state.items or 1)

		if state.loading then
			local text = state.spinner and state.spinner:text("Searching...") or "Searching..."
			rows[1] = "  " .. text
		elseif state.err then
			rows[1] = "  " .. state.err:gsub("[\r\n]+", " ")
			table.insert(highlights, {
				line = 1,
				start_col = 0,
				end_col = #rows[1],
				hl_group = "AtlasLogError",
			})
		elseif #state.items == 0 then
			local message = request.fetch and state.query == "" and "Type to search..." or "No results"
			rows[1] = "  " .. message
			table.insert(highlights, {
				line = 1,
				start_col = 0,
				end_col = #rows[1],
				hl_group = "AtlasTextMuted",
			})
		else
			local first = math.max(1, state.index - next_layout.item_height + 1)
			first = math.min(first, math.max(1, #state.items - next_layout.item_height + 1))
			for index = first, math.min(#state.items, first + next_layout.item_height - 1) do
				local item = state.items[index]
				local marker, marker_hl = "", nil
				if request.multi then
					if state.selected[request.key(item)] then
						marker, marker_hl = icons.general("success")
					else
						marker, marker_hl = "○", "AtlasTextMuted"
					end
					marker = marker .. " "
				end
				local text, hl = request.format_item(item)
				table.insert(rows, " " .. marker .. tostring(text or ""))
				local row = #rows
				if marker_hl then
					table.insert(highlights, {
						line = row,
						start_col = 1,
						end_col = 1 + #marker,
						hl_group = marker_hl,
					})
				end
				if hl then
					table.insert(highlights, {
						line = row,
						start_col = 1 + #marker,
						end_col = #rows[row],
						hl_group = hl,
					})
				end
				if index == state.index then
					table.insert(highlights, {
						line = row,
						start_col = 0,
						end_col = #rows[row],
						line_hl_group = "CursorLine",
					})
				end
			end
		end

		resize(next_layout)
		local separator = string.rep("─", next_layout.main_width)
		table.insert(rows, 1, separator)
		table.insert(highlights, {
			line = 0,
			start_col = 0,
			end_col = #separator,
			hl_group = "FloatBorder",
		})
		vim.api.nvim_buf_clear_namespace(main_buf, namespace, 0, -1)
		vim.api.nvim_buf_set_extmark(main_buf, namespace, 0, 0, {
			virt_lines = virtual_lines.render(rows, highlights, { width = next_layout.main_width }),
		})
		vim.api.nvim_buf_set_extmark(main_buf, namespace, 0, 0, {
			sign_text = "›",
			sign_hl_group = "AtlasTextNote",
		})
		if not state.loading and not state.err then
			vim.api.nvim_buf_set_extmark(main_buf, namespace, 0, 0, {
				virt_text = { { string.format("%d/%d", #state.items, #all_items), "AtlasTextMuted" } },
				virt_text_pos = "right_align",
			})
		end
		if update_preview ~= false then
			render_preview()
		end
	end

	local function filter()
		local query = state.query:lower()
		state.items = {}
		for _, item in ipairs(all_items) do
			local text = request.format_item(item)
			if query == "" or tostring(text):lower():find(query, 1, true) then
				table.insert(state.items, item)
			end
		end
		state.index = 1
		render()
	end

	local function fetch()
		cancel(state.fetch)
		state.loading = true
		state.err = nil
		state.fetch_generation = state.fetch_generation + 1
		local generation = state.fetch_generation
		if not state.spinner then
			state.spinner = spinner.create({
				on_tick = function()
					if not state.closed and state.loading then
						render(false)
					end
				end,
			})
			state.spinner:start()
		end
		render()
		state.fetch = fetch_items(state.query, function(items, err)
			vim.schedule(function()
				if state.closed or generation ~= state.fetch_generation then
					return
				end
				state.loading = false
				if state.spinner then
					state.spinner:stop()
				end
				state.spinner = nil
				state.err = err
				all_items = items or {}
				state.items = all_items
				state.index = 1
				render()
			end)
		end)
	end

	local function query_changed()
		local query = vim.api.nvim_buf_get_lines(main_buf, 0, 1, false)[1] or ""
		if query == state.query then
			return
		end
		state.query = query
		if not request.fetch then
			filter()
			return
		end
		fetch()
	end

	local function move(step)
		if state.loading or state.err or #state.items == 0 then
			return
		end
		state.index = ((state.index - 1 + step) % #state.items) + 1
		render()
	end

	local function selected_values()
		local values = {}
		for _, item in ipairs(all_items) do
			local selected = state.selected[request.key(item)]
			if selected then
				table.insert(values, selected)
			end
		end
		return values
	end

	local function toggle()
		local item = current_item()
		if not item then
			return
		end
		local key = request.key(item)
		if state.selected[key] then
			state.selected[key] = nil
		else
			state.selected[key] = item
		end
		render(false)
	end

	local function confirm()
		local value = request.multi and selected_values() or current_item()
		if not value then
			return
		end
		close(false)
		request.on_done(value)
	end

	local map_opts = { buffer = main_buf, silent = true, nowait = true }
	local function map_configured(action, callback, mode)
		for _, key in ipairs(keymaps.resolve(action) or {}) do
			vim.keymap.set(mode or "n", key, callback, map_opts)
		end
	end

	map_configured("picker.next_item", function()
		move(1)
	end, { "i", "n" })
	map_configured("picker.previous_item", function()
		move(-1)
	end, { "i", "n" })
	map_configured("picker.select", confirm, { "i", "n" })
	if request.multi then
		map_configured("picker.toggle", toggle, { "i", "n" })
	end
	map_configured("picker.close", function()
		close(true)
	end)

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = main_buf, callback = query_changed })
	vim.api.nvim_create_autocmd("VimResized", {
		buffer = main_buf,
		callback = function()
			if not state.closed then
				render(false)
			end
		end,
	})
	for _, win in ipairs({ main_win, preview_win }) do
		if win then
			vim.api.nvim_create_autocmd("WinClosed", {
				pattern = tostring(win),
				once = true,
				callback = function()
					close(true)
				end,
			})
		end
	end

	if request.fetch and request.fetch_on_open ~= false then
		fetch()
	else
		render()
	end
	vim.cmd("startinsert")
end

return M
