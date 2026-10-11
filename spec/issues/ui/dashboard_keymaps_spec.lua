local config = require("atlas.config")

describe("issues.ui.dashboard.keymaps", function()
	local saved, mappings, state, groups, selected, calls, controller, original_keymaps, original_v, original_cmd
	local modules = {
		"atlas.issues.ui.dashboard.keymaps",
		"atlas.issues.ui.dashboard.controller",
		"atlas.issues.state",
		"atlas.issues.actions",
		"atlas.ui.popups.help",
		"atlas.ui.navigation",
	}

	local function mapping(group, description)
		for _, entry in ipairs(groups[group]) do
			if entry.desc == description then
				return entry
			end
		end
		error("Missing mapping: " .. description)
	end

	before_each(function()
		saved, groups, calls = {}, {}, {}
		for _, name in ipairs(modules) do
			saved[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		original_keymaps, original_v, original_cmd = config.options.keymaps, vim.v, vim.cmd
		config.options.keymaps = vim.deepcopy(original_keymaps)
		vim.v = { count1 = 3 }
		vim.cmd = function(command)
			calls.command = command
		end
		controller = { apply_action_result = function() end }
		package.loaded["atlas.issues.ui.dashboard.controller"] = controller
		package.loaded["atlas.ui.popups.help"] = {
			register = function(group, items)
				groups[group] = items
			end,
			remove = function() end,
		}
		package.loaded["atlas.ui.navigation"] = {
			current_item = function()
				return { kind = "issue", _issue = selected, column = 2 }
			end,
			move_column = function(step)
				calls.column = step
			end,
		}
		package.loaded["atlas.issues.actions"] = {
			is_available = function(action)
				return action == "search" or action == "edit_search"
			end,
			run = function(action, context, on_done)
				calls.action, calls.context, calls.on_done = action, context, on_done
			end,
		}
		state = require("atlas.issues.state")
		state.provider = { id = "jira", capabilities = { actions = { items = { { id = "transition" } } } } }
		state.current_user = { name = "Reviewer" }
		state.view = { name = "Board", layout = "board" }
		state.views = { state.view }
		state.bookmarks = { tab = { name = "Saved", key = "S" }, items = {} }
		selected = { key = "AT-1", title = "Selected card" }
		mappings = require("atlas.issues.ui.dashboard.keymaps")
	end)

	after_each(function()
		config.options.keymaps, vim.v, vim.cmd = original_keymaps, original_v, original_cmd
		for _, name in ipairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	it("retains filters and custom callbacks with board selection context", function()
		config.options.keymaps.issues.custom = {
			{
				key = "gx",
				desc = "Custom action",
				callback = function(context, on_done)
					calls.context, calls.on_done = context, on_done
				end,
			},
		}
		mappings.register(1, state.views)
		mapping("Custom", "Custom action").callback()
		assert.equals(selected, calls.context.issue)
		assert.equals(state.provider, calls.context.provider)
		assert.equals(state.current_user, calls.context.current_user)
		assert.equals(controller.apply_action_result, calls.on_done)
		mapping("Filters", "Search issues").callback()
		assert.equals("search", calls.action)
		assert.is_nil(calls.context.issue)
		mapping("Filters", "Edit current search").callback()
		assert.equals("edit_search", calls.action)
		mapping("General", "Transition issue").callback()
		assert.equals("transition", calls.action)
		assert.equals(selected, calls.context.issue)
	end)

	it("moves board columns with counts and retains ordinary horizontal movement in list views", function()
		mappings.register(1, state.views)
		local previous = mapping("General", "Previous status column (board)")
		local next_column = mapping("General", "Next status column (board)")
		previous.callback()
		assert.equals(-3, calls.column)
		next_column.callback()
		assert.equals(3, calls.column)
		state.view.layout = "plain"
		previous.callback()
		assert.equals("normal! 3h", calls.command)
		next_column.callback()
		assert.equals("normal! 3l", calls.command)
	end)

	it("leaves native horizontal keys unbound for non-Jira board views and bookmarks", function()
		local board_view = state.view
		for _, provider in ipairs({ "github", "gitlab" }) do
			state.provider.id = provider
			for _, bookmarked in ipairs({ false, true }) do
				state.view = bookmarked and state.bookmarks.tab or board_view
				state.bookmarks.selection = bookmarked and { kind = "bookmark", view = board_view } or nil
				mappings.register(1, state.views)
				for _, entries in pairs(groups) do
					for _, entry in ipairs(entries) do
						assert.is_not.equal("h", entry.key)
						assert.is_not.equal("l", entry.key)
						assert.is_nil(entry.desc:find("status column", 1, true))
					end
				end
			end
		end
	end)
end)
