local resolver = require("atlas.core.keymaps")
local actions = require("atlas.providers.github.ui.repository.pages.discussions.panel.actions")
local help = require("atlas.ui.popups.help")

local M = {}

---@param panel GitHubDiscussionPanel
---@param callbacks table<string, function>
function M.setup(panel, callbacks)
	local function redraw()
		callbacks.render(panel)
	end

	local items = {
		{
			key = resolver.resolve("ui.close"),
			desc = "Close discussion",
			callback = function()
				callbacks.close(panel)
			end,
			index = 90,
		},
		{
			key = resolver.resolve("ui.help"),
			desc = "Toggle help",
			callback = function()
				help.toggle({ buffer = panel.buf })
			end,
			index = 100,
		},
		{
			key = resolver.resolve("ui.toggle_panel"),
			desc = "Toggle discussion panel",
			callback = function()
				callbacks.close(panel)
			end,
			index = 12,
		},
		{
			key = resolver.resolve("ui.toggle_fold"),
			desc = "Expand / collapse replies",
			callback = function()
				callbacks.toggle_fold(panel)
			end,
			index = 10,
		},
		{
			key = resolver.resolve("ui.comments.add"),
			desc = "Add comment",
			callback = function()
				actions.add(panel, redraw)
			end,
			index = 20,
		},
		{
			key = resolver.resolve("ui.comments.reply"),
			desc = "Reply to comment",
			callback = function()
				actions.reply(panel, callbacks.current(panel), redraw)
			end,
			index = 21,
		},
		{
			key = resolver.resolve("ui.comments.edit"),
			desc = "Edit comment",
			callback = function()
				actions.edit(panel, callbacks.current(panel), redraw)
			end,
			index = 22,
		},
		{
			key = resolver.resolve("ui.comments.react"),
			desc = "Add reaction",
			callback = function()
				actions.react(panel, callbacks.current(panel), redraw)
			end,
			index = 23,
		},
		{
			key = resolver.resolve("ui.delete"),
			desc = "Delete comment",
			callback = function()
				actions.delete(panel, callbacks.current(panel), redraw)
			end,
			index = 24,
		},
		{
			key = { "gu" },
			desc = "Toggle upvote",
			callback = function()
				actions.upvote(panel, callbacks.current(panel), redraw)
			end,
			index = 25,
		},
		{
			key = { "ga" },
			desc = "Mark / unmark answer",
			callback = function()
				actions.answer(panel, callbacks.current(panel), redraw)
			end,
			index = 26,
		},
		{
			key = vim.list_extend(resolver.resolve("ui.refresh") or {}, resolver.resolve("ui.refresh_view") or {}),
			desc = "Refresh discussion",
			callback = function()
				callbacks.load(panel)
			end,
			index = 80,
		},
		{
			key = resolver.resolve("ui.open_in_browser"),
			desc = "Open discussion in browser",
			callback = function()
				callbacks.open_in_browser(panel)
			end,
			index = 4,
		},
		{
			key = resolver.resolve("ui.copy_url"),
			desc = "Copy discussion URL",
			callback = function()
				callbacks.copy_url(panel)
			end,
			index = 9,
		},
	}

	for _, item in ipairs(items) do
		item.opts = { silent = true, nowait = true }
	end

	help.register("General", items, { buffer = panel.buf, index = 1 })
end

return M
