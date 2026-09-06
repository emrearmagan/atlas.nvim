local Snacks = require("snacks")

local M = {}
local notify = require("atlas.core.notify")

---@param request AtlasPickerRequest
---@param item any
---@return snacks.picker.finder.Item
local function entry(request, item)
	local text, hl_group = request.format_item(item)
	return {
		text = text,
		key = request.key(item),
		_select_key = request.key(item),
		item = item,
		hl_group = hl_group,
	}
end

---@param handle { cancel: fun() }|nil
local function cancel(handle)
	if handle then
		handle.cancel()
	end
end

---@param request AtlasPickerRequest
---@return snacks.picker.finder, fun()
local function finder(request)
	if not request.fetch then
		local items = {}
		for _, item in ipairs(request.items) do
			items[#items + 1] = entry(request, item)
		end
		return function()
			return items
		end, function() end
	end

	local first = true
	local active = true
	local handle
	local timer
	local generation = 0
	return function(_, ctx)
		local query = ctx.filter.search
		if first and query == "" and request.fetch_on_open == false then
			first = false
			local items = {}
			for _, item in ipairs(request.items) do
				items[#items + 1] = entry(request, item)
			end
			return items
		end
		first = false

		if timer then
			timer:stop()
			timer:close()
			timer = nil
		end
		cancel(handle)
		generation = generation + 1
		local current = generation
		local result
		local fetch_err
		local loaded = false
		local function fetch()
			timer = nil
			handle = request.fetch(query, function(items, err)
				vim.schedule(function()
					if not active or current ~= generation or ctx.picker.closed then
						return
					end
					result = items or {}
					fetch_err = err
					loaded = true
					ctx.async:resume()
				end)
			end)
		end
		if (request.debounce_ms or 0) > 0 then
			timer = vim.defer_fn(fetch, request.debounce_ms)
		else
			fetch()
		end
		return function(add)
			if not loaded then
				ctx.async:suspend()
			end
			if not active or current ~= generation or ctx.picker.closed then
				return
			end
			if fetch_err then
				notify.error(fetch_err, { vim_notify = true })
			end
			for _, item in ipairs(result) do
				add(entry(request, item))
			end
		end
	end, function()
		active = false
		if timer then
			timer:stop()
			timer:close()
		end
		cancel(handle)
	end
end

---@param request AtlasPickerRequest
function M.open(request)
	local confirmed = false
	local preview_handle
	local preview_generation = 0
	local picker_finder, close_finder = finder(request)
	local selected = {}
	for _, item in ipairs(request.selected) do
		selected[request.key(item)] = true
	end

	local function selected_items(picker)
		local items = {}
		for _, item in ipairs(picker:selected()) do
			items[#items + 1] = item.item
		end
		return items
	end
	local opts = {
		title = request.title,
		prompt = "",
		live = request.fetch ~= nil,
		show_empty = true,
		finder = picker_finder,
		format = function(item)
			return { { item.text, item.hl_group } }
		end,
		actions = {
			confirm = function(picker, item)
				local value = request.multi and selected_items(picker) or (item and item.item)
				if value == nil then
					return
				end
				confirmed = true
				picker:close()
				vim.schedule(function()
					request.on_done(value)
				end)
			end,
		},
		on_show = function(picker)
			if request.initial_index then
				picker.list:view(request.initial_index)
			end
			if request.multi then
				local items = vim.tbl_filter(function(item)
					return selected[item.key] == true
				end, picker.finder.items)
				picker.list:set_selected(items)
			end
		end,
		on_close = function()
			close_finder()
			cancel(preview_handle)
			if not confirmed and request.on_cancel then
				request.on_cancel()
			end
		end,
	}
	if not request.preview_item then
		opts.layout = { preset = "select", preview = false }
	end

	if request.multi then
		opts.formatters = { selected = { show_always = true } }
	end

	if request.preview_item then
		opts.preview = function(ctx)
			cancel(preview_handle)
			preview_generation = preview_generation + 1
			local generation = preview_generation
			ctx.preview:reset()
			ctx.preview:set_lines({ "Loading..." })
			preview_handle = request.preview_item(ctx.item.item, function(preview)
				vim.schedule(function()
					if ctx.picker.closed or generation ~= preview_generation then
						return
					end
					ctx.preview:reset()
					ctx.preview:set_title(preview.title or request.title)
					ctx.picker:update_titles()
					ctx.preview:set_lines(preview.lines)
					ctx.preview:highlight({ ft = "markdown" })
				end)
			end)
		end
	end

	return Snacks.picker.pick(opts)
end

return M
