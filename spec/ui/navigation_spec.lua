describe("ui.navigation board selection", function()
	local navigation, state, cursor, scheduled
	local original_api, original_defer, saved
	local modules = { "atlas.ui.navigation", "atlas.ui.dashboard", "atlas.ui.state" }

	before_each(function()
		saved = {}
		for _, name in ipairs(modules) do
			saved[name] = package.loaded[name]
		end
		original_api, original_defer = vim.api, vim.defer_fn
		cursor, scheduled = { 1, 42 }, 0
		state = {
			line_map = {
				{
					kind = "board_row",
					cells = {
						{ kind = "issue", key = "AT-1", column = 1, start_col = 1, end_col = 39 },
						{ kind = "issue", key = "AT-2", column = 2, start_col = 42, end_col = 80 },
					},
				},
			},
		}
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
			nvim_buf_line_count = function()
				return #state.line_map
			end,
			nvim_buf_clear_namespace = function() end,
			nvim_buf_set_extmark = function() end,
			nvim_set_option_value = function() end,
		})
		vim.defer_fn = function()
			scheduled = scheduled + 1
			return { stop = function() end, close = function() end }
		end
		package.loaded["atlas.ui.navigation"] = nil
		navigation = require("atlas.ui.navigation")
	end)

	after_each(function()
		vim.api, vim.defer_fn = original_api, original_defer
		for _, name in ipairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	it("restores the same card after Unicode byte shifts and status moves without scheduling selection", function()
		local previous = navigation.current_item()
		-- A Unicode title in the preceding column moves this card's byte offset.
		state.line_map[1].cells[2] = vim.tbl_extend("force", previous, { start_col = 43, end_col = 81 })
		assert.equals("AT-1", navigation.current_item().key)
		navigation.restore_board_selection(previous)
		assert.equals("AT-2", navigation.current_item().key)
		assert.same({ 1, 43 }, cursor)

		previous = navigation.current_item()
		state.line_map[1].cells = {
			{ kind = "issue", key = "AT-2", column = 1, start_col = 1, end_col = 39 },
			{ kind = "issue", key = "AT-1", column = 2, start_col = 43, end_col = 81 },
		}
		navigation.restore_board_selection(previous)
		assert.equals("AT-2", navigation.current_item().key)
		assert.same({ 1, 1 }, cursor)
		assert.equals(0, scheduled)
	end)

	it("keeps local navigation in an empty column but lets paging reset across columns", function()
		state.line_map[1].cells[2] = { kind = "issue_column", column = 2, start_col = 42, end_col = 80 }
		navigation.focus_first_item()
		assert.equals("issue_column", navigation.current_item().kind)
		assert.same({ 1, 42 }, cursor)
		navigation.focus_first_item({ all_columns = true })
		assert.equals("AT-1", navigation.current_item().key)
		assert.same({ 1, 1 }, cursor)
	end)
end)
