local resolver = require("atlas.core.keymaps")
local commits = require("atlas.pulls.diffv2.ui.commits")
local explorer = require("atlas.pulls.diffv2.ui.explorer")
local help = require("atlas.ui.popups.help")

local M = {}

---@class AtlasDiffV2KeymapActions
---@field close fun()
---@field toggle_explorer fun()
---@field toggle_commits fun()
---@field focus_explorer fun()
---@field navigate_file fun(direction: 1|-1, unreviewed_only?: boolean)
---@field find_file fun()

---@param items AtlasHelpKeyItem[]
---@param action AtlasKeymapActionId
---@param desc string
---@param callback fun()
local function add(items, action, desc, callback)
	local keys = resolver.resolve(action)
	if keys then
		items[#items + 1] = {
			key = keys,
			desc = desc,
			callback = callback,
			opts = { nowait = true, silent = true },
		}
	end
end

---@param actions AtlasDiffV2KeymapActions
---@return { name: string, items: AtlasHelpKeyItem[] }[]
local function shared_groups(actions)
	local explorer_items = {}
	add(explorer_items, "pulls.review.view.next_file", "Next file", function()
		actions.navigate_file(1)
	end)
	add(explorer_items, "pulls.review.view.prev_file", "Previous file", function()
		actions.navigate_file(-1)
	end)
	add(explorer_items, "pulls.review.view.next_unreviewed_file", "Next unreviewed file", function()
		actions.navigate_file(1, true)
	end)
	add(explorer_items, "pulls.review.view.prev_unreviewed_file", "Previous unreviewed file", function()
		actions.navigate_file(-1, true)
	end)
	add(explorer_items, "pulls.review.view.find_file", "Find changed file", actions.find_file)

	local view_items = {}
	add(view_items, "pulls.review.view.toggle_explorer", "Toggle explorer", actions.toggle_explorer)
	add(view_items, "pulls.review.view.toggle_commits", "Toggle commits", actions.toggle_commits)
	add(view_items, "pulls.review.view.focus_explorer", "Focus explorer", actions.focus_explorer)
	add(view_items, "ui.close", "Close review", function()
		if not help.is_open() then
			actions.close()
		end
	end)

	return {
		{ name = "Explorer", items = explorer_items },
		{ name = "View", items = view_items },
	}
end

---@param session AtlasDiffV2Session
---@param actions AtlasDiffV2KeymapActions
function M.setup(session, actions)
	local groups = shared_groups(actions)
	for _, panel in ipairs({ session.explorer, session.commits }) do
		for index, group in ipairs(groups) do
			help.register(group.name, group.items, { buffer = panel.buf, index = index })
		end

		local items = {}
		add(items, "ui.help", "Toggle help", function()
			help.toggle({ buffer = panel.buf })
		end)
		help.register("View", items, { buffer = panel.buf })
	end

	local explorer_items = {}
	add(explorer_items, "ui.select", "Select file / toggle folder", function()
		explorer.activate(session.explorer)
	end)

	add(explorer_items, "ui.show_details", "Show details", function()
		explorer.show_details(session.explorer)
	end)

	add(explorer_items, "pulls.review.explorer.toggle_view_mode", "Toggle explorer mode", function()
		explorer.toggle_view_mode(session.explorer)
	end)
	help.register("Explorer", explorer_items, { buffer = session.explorer.buf })

	local commits_items = {}
	add(commits_items, "ui.show_details", "Show details", function()
		commits.show_details(session.commits)
	end)
	help.register("View", commits_items, { buffer = session.commits.buf })

	session.renderer.setup_keymaps(session.view, groups)
end

return M
