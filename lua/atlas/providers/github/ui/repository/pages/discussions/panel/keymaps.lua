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

	local bindings = {
		{
			keymap = resolver.resolve("ui.close"),
			callback = function()
				callbacks.close(panel)
			end,
			index = 90,
		},
		{
			keymap = resolver.resolve("ui.help"),
			callback = function()
				help.toggle({ buffer = panel.buf })
			end,
			index = 100,
		},
		{
			keymap = resolver.resolve("ui.toggle_panel"),
			callback = function()
				callbacks.close(panel)
			end,
			index = 12,
		},
		{
			keymap = resolver.resolve("ui.toggle_fold"),
			callback = function()
				callbacks.toggle_fold(panel)
			end,
			index = 10,
		},
		{
			keymap = resolver.resolve("ui.comments.add"),
			callback = function()
				actions.add(panel, redraw)
			end,
			index = 20,
		},
		{
			keymap = resolver.resolve("ui.comments.reply"),
			callback = function()
				actions.reply(panel, callbacks.current(panel), redraw)
			end,
			index = 21,
		},
		{
			keymap = resolver.resolve("ui.comments.edit"),
			callback = function()
				actions.edit(panel, callbacks.current(panel), redraw)
			end,
			index = 22,
		},
		{
			keymap = resolver.resolve("ui.comments.react"),
			callback = function()
				actions.react(panel, callbacks.current(panel), redraw)
			end,
			index = 23,
		},
		{
			keymap = resolver.resolve("ui.delete"),
			callback = function()
				actions.delete(panel, callbacks.current(panel), redraw)
			end,
			index = 24,
		},
		{
			keymap = resolver.resolve("ui.comments.upvote"),
			callback = function()
				actions.upvote(panel, callbacks.current(panel), redraw)
			end,
			index = 25,
		},
		{
			-- TODO: add to config
			keymap = { key = { "ga" }, desc = "Mark / unmark answer", label = "answer" },
			callback = function()
				actions.answer(panel, callbacks.current(panel), redraw)
			end,
			index = 26,
		},
		{
			keymap = resolver.resolve({ "ui.refresh", "ui.refresh_view" }),
			callback = function()
				callbacks.load(panel)
			end,
			index = 80,
		},
		{
			keymap = resolver.resolve("ui.open_in_browser"),
			callback = function()
				callbacks.open_in_browser(panel)
			end,
			index = 4,
		},
		{
			keymap = resolver.resolve("ui.copy_url"),
			callback = function()
				callbacks.copy_url(panel)
			end,
			index = 9,
		},
	}

	local items = {}
	for _, binding in ipairs(bindings) do
		if binding.keymap then
			table.insert(items, {
				key = binding.keymap.key,
				desc = binding.keymap.desc,
				index = binding.index,
				callback = binding.callback,
				opts = { silent = true, nowait = true },
			})
		end
	end

	help.register("General", items, { buffer = panel.buf, index = 1 })
end

return M
