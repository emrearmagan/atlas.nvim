local M = {}

local icons = require("atlas.ui.shared.icons")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")

---@param actions AtlasAction[]|nil
---@param id string
---@return AtlasAction|nil
function M.find(actions, id)
	for _, action in ipairs(actions or {}) do
		if action.id == id then
			return action
		end
	end
	return nil
end

---@param action AtlasAction|nil
---@param ctx table
---@return boolean
function M.is_available(action, ctx)
	return action ~= nil and (action.is_available == nil or action.is_available(ctx) == true)
end

---@param on_done fun(result: any, err: string|nil)
---@param err string
---@return false
local function reject(on_done, err)
	notify.warn(err)
	on_done(nil, err)
	return false
end

---@param action AtlasAction|nil
---@param ctx table
---@param on_done fun(result: any, err: string|nil)|nil
---@return boolean handled
function M.run(action, ctx, on_done)
	on_done = on_done or function() end
	if not action then
		return reject(on_done, "Unknown action")
	end
	if action.is_available then
		local available, reason = action.is_available(ctx)
		if not available then
			return reject(on_done, reason or ("Action is not available: " .. action.id))
		end
	end
	local confirm = type(action.confirm) == "function" and action.confirm(ctx) or action.confirm
	if not confirm then
		return action.run(ctx, on_done) ~= false
	end

	vim.ui.input({ prompt = confirm .. " [y/N]: " }, function(input)
		local answer = vim.trim(input or ""):lower()
		if answer == "y" or answer == "yes" then
			action.run(ctx, on_done)
		else
			on_done(nil, nil)
		end
	end)
	return true
end

---@param title string
---@param items { label: string, icon: string|nil }[]
---@param on_select fun(item: any)
function M.select(title, items, on_select)
	picker.select({
		title = title,
		items = items,
		format_item = function(item)
			return (item.icon or icons.get("custom", "actions")) .. "  " .. item.label
		end,
		on_select = function(item)
			if item then
				on_select(item)
			end
		end,
	})
end

return M
