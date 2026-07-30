local M = {}

local explorer = require("atlas.pulls.diff.atlas.explorer")
local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")

---@param action AtlasKeymapActionId
---@param map_item AtlasHelpKeyItem
---@return AtlasHelpKeyItem|nil
local function item(action, map_item)
	local keys = resolver.resolve(action)
	if not keys then
		return nil
	end
	map_item.key = #keys == 1 and keys[1] or keys
	return map_item
end

---@param items AtlasHelpKeyItem[]
---@param value AtlasHelpKeyItem|nil
local function add(items, value)
	if value then
		table.insert(items, value)
	end
end

---@class AtlasDiffKeymapActions
---@field active fun(): boolean
---@field close fun()
---@field toggle_layout fun()
---@field toggle_compact fun()
---@field reload fun()
---@field navigate_hunk fun(direction: 1|-1)
---@field navigate_file fun(direction: 1|-1)
---@field toggle_file_reviewed fun()
---@field toggle_panel fun()
---@field select_file fun(index: integer)

---@param session AtlasNativeDiffSession
---@param actions AtlasDiffKeymapActions
function M.register(session, actions)
	local function run(callback)
		return function()
			if actions.active() and not help.is_open() then
				callback()
			end
		end
	end

	local navigation = {}
	add(
		navigation,
		item("pulls.review.previous_hunk", {
			desc = "Previous diff hunk",
			index = 1,
			callback = run(function()
				actions.navigate_hunk(-1)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		navigation,
		item("pulls.review.next_hunk", {
			desc = "Next diff hunk",
			index = 2,
			callback = run(function()
				actions.navigate_hunk(1)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		navigation,
		item("pulls.review.previous_file", {
			desc = "Previous file",
			index = 3,
			callback = run(function()
				actions.navigate_file(-1)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	add(
		navigation,
		item("pulls.review.next_file", {
			desc = "Next file",
			index = 4,
			callback = run(function()
				actions.navigate_file(1)
			end),
			opts = { silent = true, nowait = true },
		})
	)

	for _, buf in ipairs({ session.panel.buf, session.left.buf, session.right.buf, session.footer.buf }) do
		local general = {}
		add(
			general,
			item("ui.close", {
				desc = "Close diff",
				index = 1,
				callback = run(actions.close),
				opts = { silent = true, nowait = true },
			})
		)
		add(
			general,
			item("ui.help", {
				desc = "Toggle help",
				index = 2,
				callback = run(function()
					help.toggle({ buffer = buf })
				end),
				opts = { silent = true, nowait = true },
			})
		)
		add(
			general,
			item("ui.toggle_panel", {
				desc = "Toggle file explorer",
				index = 3,
				callback = run(actions.toggle_panel),
				opts = { silent = true, nowait = true },
			})
		)
		add(
			general,
			item("ui.refresh_view", {
				desc = "Reload diff",
				index = 4,
				callback = run(actions.reload),
				opts = { silent = true, nowait = true },
			})
		)
		add(
			general,
			item("pulls.review.toggle_compact", {
				desc = "Toggle full / compact",
				index = 5,
				callback = run(actions.toggle_compact),
				opts = { silent = true, nowait = true },
			})
		)
		add(
			general,
			item("pulls.review.toggle_layout", {
				desc = "Toggle side-by-side / inline",
				index = 6,
				callback = run(actions.toggle_layout),
				opts = { silent = true, nowait = true },
			})
		)
		help.register("General", general, { index = 90, buffer = buf })
		help.register("Navigation", navigation, { index = 120, buffer = buf })
	end

	local explorer_actions = {
		{
			key = { "<CR>", "l" },
			desc = "Open changed file",
			index = 1,
			callback = run(function()
				local index = explorer.open_at_cursor(session)
				if index then
					actions.select_file(index)
				end
			end),
			opts = { silent = true, nowait = true },
		},
	}
	add(
		explorer_actions,
		item("ui.show_details", {
			desc = "Show full path",
			index = 2,
			callback = run(function()
				explorer.show_path(session)
			end),
			opts = { silent = true, nowait = true },
		})
	)
	if session.explorer.grouped then
		add(
			explorer_actions,
			item("ui.toggle_fold", {
				desc = "Toggle folder",
				index = 3,
				callback = run(function()
					explorer.toggle_folder(session)
				end),
				opts = { silent = true, nowait = true },
			})
		)
		add(
			explorer_actions,
			item("ui.toggle_all_folds", {
				desc = "Toggle all folders",
				index = 4,
				callback = run(function()
					explorer.toggle_all_folders(session)
				end),
				opts = { silent = true, nowait = true },
			})
		)
	end
	add(
		explorer_actions,
		item("pulls.review.toggle_file_reviewed", {
			desc = "Toggle file reviewed",
			index = 5,
			callback = run(actions.toggle_file_reviewed),
			opts = { silent = true, nowait = true },
		})
	)
	help.register("Explorer", explorer_actions, { index = 80, buffer = session.panel.buf })
end

return M
