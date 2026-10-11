describe("ui.navigation board movement", function()
	local navigation, state, cursor, leftcol
	local original_api, original_defer, original_fn, saved
	local modules = { "atlas.ui.navigation", "atlas.ui.dashboard", "atlas.ui.state" }

	before_each(function()
		saved = {}
		for _, name in ipairs(modules) do
			saved[name] = package.loaded[name]
		end
		original_api, original_defer, original_fn = vim.api, vim.defer_fn, vim.fn
		cursor, leftcol = { 1, 0 }, 20
		state = { line_map = {} }
		package.loaded["atlas.ui.state"] = state
		package.loaded["atlas.ui.dashboard"] = {
			win = function()
				return 1
			end,
			buf = function()
				return 2
			end,
		}
		vim.api = vim.tbl_extend("force", original_api, {
			nvim_win_get_cursor = function()
				return cursor
			end,
			nvim_win_set_cursor = function(_, value)
				cursor = value
			end,
			nvim_win_call = function(_, callback)
				return callback()
			end,
			nvim_buf_clear_namespace = function() end,
			nvim_buf_set_extmark = function() end,
			nvim_set_option_value = function() end,
		})
		vim.fn = vim.tbl_extend("force", original_fn, {
			winrestview = function(view)
				leftcol = view.leftcol
			end,
		})
		vim.defer_fn = function()
			return { stop = function() end, close = function() end }
		end
		package.loaded["atlas.ui.navigation"] = nil
		navigation = require("atlas.ui.navigation")
	end)

	after_each(function()
		vim.api, vim.defer_fn, vim.fn = original_api, original_defer, original_fn
		for _, name in ipairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	it("continues vertical movement through wrapped groups while keeping workflow column jumps", function()
		local lines, map = require("atlas.issues.ui.layouts.board").jira({ width = 80 }, {
			{ key = "A", title = "Café", status = "Open" },
			{ key = "B", title = "Work", status = "Done" },
			{ key = "C", title = "Work", status = "Open" },
			{ key = "E", title = "Review", status = "Review" },
			{ key = "F", title = "Test", status = "Testing" },
			{ key = "H", title = "Review", status = "Review" },
			{ key = "I", title = "Ship", status = "Closed" },
		})
		state.line_map = map
		local function position(key)
			for line = 1, #lines do
				for _, cell in ipairs(map[line] and map[line].cells or {}) do
					if cell.key == key then
						return { line, cell.start_col }
					end
				end
			end
		end
		vim.api.nvim_buf_line_count = function()
			return #lines
		end

		cursor = position("B")
		navigation.focus_first_item({ all_columns = true })
		assert.same(position("A"), cursor)
		navigation.move_cursor("down")
		assert.same(position("C"), cursor)
		assert.equals(0, leftcol)
		navigation.move_cursor("down")
		assert.same(position("E"), cursor)
		navigation.move_cursor("up")
		assert.same(position("C"), cursor)

		cursor = position("B")
		navigation.move_cursor("down")
		assert.same(position("F"), cursor)
		navigation.move_cursor("down")
		assert.same(position("I"), cursor)
		navigation.move_cursor("up")
		assert.same(position("H"), cursor)
		navigation.focus_first_item()
		assert.same(position("E"), cursor)
		navigation.focus_last_item()
		assert.same(position("H"), cursor)

		cursor = position("B")
		navigation.move_column(-1)
		assert.same(position("A"), cursor)
		navigation.move_column(1)
		assert.same(position("B"), cursor)
		navigation.move_column(1)
		assert.same(position("E"), cursor)
		navigation.move_column(-1)
		assert.same(position("B"), cursor)
	end)
end)
