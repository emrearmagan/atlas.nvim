local fzf = require("fzf-lua")
local fzf_actions = require("fzf-lua.actions")
local fzf_utils = require("fzf-lua.utils")

local M = {}
local notify = require("atlas.core.notify")

---@param handle { cancel: fun() }|nil
local function cancel(handle)
	if handle then
		handle.cancel()
	end
end

---@param request AtlasPickerRequest
function M.open(request)
	local active = true
	local finished = false
	local current_items = request.items
	local item_by_id = {}
	local fetch_handle
	local fetch_generation = 0
	local preview_handle
	local preview_generation = 0
	local selected = {}
	local selected_keys = {}

	local function select(item)
		local key = request.key(item)
		if selected[key] then
			selected[key] = nil
			for index, selected_key in ipairs(selected_keys) do
				if selected_key == key then
					table.remove(selected_keys, index)
					break
				end
			end
		else
			selected[key] = item
			selected_keys[#selected_keys + 1] = key
		end
	end

	for _, item in ipairs(request.selected) do
		select(item)
	end

	local function selected_items()
		local items = {}
		for _, key in ipairs(selected_keys) do
			items[#items + 1] = selected[key]
		end
		return items
	end

	local function set_items(items)
		current_items = items or {}
		for _, item in ipairs(current_items) do
			local key = request.key(item)
			if selected[key] then
				selected[key] = item
			end
		end
	end

	local function entry(item, id)
		local key = request.key(item)
		item_by_id[id] = item
		local marker = request.multi and (selected[key] and "✓ " or "  ") or ""
		local text, hl_group = request.format_item(item)
		if hl_group then
			text = fzf_utils.ansi_from_hl(hl_group, text)
		end
		return id .. "\t" .. marker .. tostring(text):gsub("[\r\n\t]", " ")
	end

	local function item_for(value)
		return item_by_id[value:match("^(%d+)\t")]
	end

	local function write_items(done)
		item_by_id = {}
		for index, item in ipairs(current_items) do
			done(entry(item, tostring(index)))
		end
		done()
	end

	local function finish_cancel()
		if finished then
			return
		end
		finished = true
		if request.on_cancel then
			request.on_cancel()
		end
	end

	local opts = {
		no_hide = true,
		prompt = "",
		winopts = {
			title = request.title,
			on_close = function()
				active = false
				cancel(fetch_handle)
				cancel(preview_handle)
			end,
		},
		fzf_opts = {
			["--delimiter"] = "\t",
			["--with-nth"] = "2..",
			["--no-multi"] = true,
		},
		actions = {
			default = function() end,
		},
	}
	if not request.preview_item then
		opts.previewer = false
	end
	if request.initial_index then
		opts.keymap = { fzf = { load = string.format("pos(%d)", request.initial_index) } }
	end

	if request.multi then
		local function toggle(entries)
			local item = entries[1] and item_for(entries[1])
			if not item then
				return
			end
			select(item)
		end
		opts.actions.tab = { fn = toggle, reload = true, field_index = "{}" }
		opts.actions["ctrl-space"] = { fn = toggle, reload = true, field_index = "{}" }
	end

	if request.preview_item then
		opts.previewer = {
			_ctor = function()
				local previewer = require("fzf-lua.previewer.builtin").base:extend()

				function previewer:populate_preview_buf(value)
					cancel(preview_handle)
					preview_generation = preview_generation + 1
					local generation = preview_generation
					local item = item_for(value)
					if not item then
						return
					end

					local buf = self:get_tmp_buffer()
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading..." })
					self:set_preview_buf(buf)
					preview_handle = request.preview_item(item, function(preview)
						vim.schedule(function()
							if not active or generation ~= preview_generation or not vim.api.nvim_buf_is_valid(buf) then
								return
							end
							vim.bo[buf].modifiable = true
							vim.api.nvim_buf_set_lines(buf, 0, -1, false, preview.lines)
							vim.bo[buf].modifiable = false
							vim.bo[buf].filetype = "markdown"
							self.win:update_preview_title(preview.title or request.title)
						end)
					end)
				end

				return previewer
			end,
		}
	end

	opts.fn_selected = function(values, picker_opts)
		local action, entries = fzf_actions.normalize_selected(values, picker_opts)
		local item = entries and entries[1] and item_for(entries[1])
		if action ~= "enter" or (not request.multi and not item) then
			vim.schedule(finish_cancel)
			return
		end

		finished = true
		local value = request.multi and selected_items() or item
		vim.schedule(function()
			request.on_done(value)
		end)
	end

	if request.fetch then
		opts.query_delay = request.debounce_ms
		local first = true
		fzf.fzf_live(function(args)
			local query = args[1] or ""
			if first and query == "" and request.fetch_on_open == false then
				first = false
				return write_items
			end
			first = false
			return function(done)
				cancel(fetch_handle)
				fetch_generation = fetch_generation + 1
				local generation = fetch_generation
				fetch_handle = request.fetch(query, function(items, err)
					if not active or generation ~= fetch_generation then
						return
					end
					if err then
						notify.error(err)
					end
					set_items(items)
					write_items(done)
				end)
			end
		end, opts)
	else
		fzf.fzf_exec(write_items, opts)
	end
end

return M
