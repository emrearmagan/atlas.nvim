--- Note: Complety AI generated. But its a pretty simple picker that just works. Dont feel like it needs refactoring (yet..)
---
---@class AtlasMultiSelectOpts
---@field items table[] candidate items
---@field selected table[] current selection (returned in `on_done`)
---@field key fun(item: table): string stable identity used for toggling (e.g. login, name)
---@field format fun(item: table): string human label (without checkbox marker)
---@field prompt string|nil vim.ui.select prompt; defaults to "Toggle:"
---@field done_label string|nil sentinel label; defaults to "✓ Done"
---@field on_done fun(selected: table[])|nil called once when the user picks Done or cancels
---@field on_change fun(selected: table[])|nil called after every toggle (optional)

local M = {}

---@param list table[]
---@param k string
---@param key_fn fun(item: table): string
---@return boolean
local function contains(list, k, key_fn)
	for _, item in ipairs(list) do
		if key_fn(item) == k then
			return true
		end
	end
	return false
end

---@param list table[]
---@param k string
---@param key_fn fun(item: table): string
---@return table[]
local function without(list, k, key_fn)
	local kept = {}
	for _, item in ipairs(list) do
		if key_fn(item) ~= k then
			table.insert(kept, item)
		end
	end
	return kept
end

---@param opts AtlasMultiSelectOpts
function M.open(opts)
	if type(opts) ~= "table" then
		return
	end
	if type(opts.items) ~= "table" or type(opts.key) ~= "function" or type(opts.format) ~= "function" then
		return
	end

	local prompt = opts.prompt or "Toggle:"
	local done_label = opts.done_label or "✓ Done"
	local selected = type(opts.selected) == "table" and opts.selected or {}

	local function loop()
		local choices = { done_label }
		local map = {}
		for _, item in ipairs(opts.items) do
			local k = opts.key(item)
			local marker = contains(selected, k, opts.key) and "[x] " or "[ ] "
			local label = marker .. opts.format(item)
			table.insert(choices, label)
			map[label] = item
		end

		local prompt_with_count = string.format("%s (%d selected)", prompt, #selected)
		vim.ui.select(choices, { prompt = prompt_with_count }, function(choice)
			if choice == nil or choice == done_label then
				if opts.on_done then
					opts.on_done(selected)
				end
				return
			end

			local item = map[choice]
			if item == nil then
				loop()
				return
			end

			local k = opts.key(item)
			if contains(selected, k, opts.key) then
				selected = without(selected, k, opts.key)
			else
				table.insert(selected, item)
			end

			if opts.on_change then
				opts.on_change(selected)
			end

			loop()
		end)
	end

	loop()
end

return M
